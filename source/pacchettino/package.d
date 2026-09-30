/**
 * A job queue made of plain directories: one program sends jobs, another one
 * (or many, in other processes or threads) processes them.
 *
 * A job is either some bytes (`sendData`) or a file (`sendFile`). It is in the
 * filesystem before `send*` returns, so nothing is lost if a program stops or
 * crashes (set `Pacchettino.durable` to survive power cuts too), and a job left
 * half done by a process that died is detected and moved to `interrupted/`. Each job is given to one consumer only, even with
 * many consumers on the same directory. No server, no database, no dependencies.
 *
 * Example:
 * ---
 * // Producer
 * auto queue = new Pacchettino("/var/spool/myapp");
 * queue.sendFile("video.mp4");
 * queue.sendData("resize photo 42", 10.minutes);   // not before 10 minutes
 *
 * // Consumer, in another program
 * auto queue = new Pacchettino("/var/spool/myapp");
 * queue.onFileReceived = (id, name, path) {
 *     upload(path);
 *     return Pacchettino.Result.SUCCESS;   // or FAILED, or RETRY
 * };
 *
 * while (true) queue.receiveOne(5.seconds);
 * ---
 *
 * Where to start:
 * $(UL
 *   $(LI `Pacchettino.sendData` and `Pacchettino.sendFile` — adding jobs, now or with a delay;)
 *   $(LI `Pacchettino.onDataReceived`, `Pacchettino.onFileReceived` and `Pacchettino.receiveOne` — processing them;)
 *   $(LI `Pacchettino.status`, `Pacchettino.requeue` and `Pacchettino.cleanup` — following and managing them;)
 *   $(LI `Pacchettino.KeepPolicy` — which processed jobs stay on disk;)
 *   $(LI `Pacchettino.durable` and `Pacchettino.crashDetection` — for power cuts, and for consumers in containers.)
 * )
 *
 * Works on Linux, macOS, BSD and Windows.
 *
 * See_Also:
 *   $(LINK2 https://github.com/trikko/pacchettino, the README) for a guided tour,
 *   $(LINK2 https://trikko.github.io/pacchettino/llms-full.txt, llms-full.txt) for
 *   the whole API in one file.
 */
module pacchettino;

import pacchettino.uuid;

import std.random 	: randomShuffle;
import std.string 	: representation, split, join, lastIndexOf;
import std.conv 		: to;
import std.array 		: array;
import std.algorithm : startsWith, endsWith, sort;
import std.range 		: walkLength;
import std.logger 	: warning;
import std.process  : thisProcessID;
import std.datetime : Clock, Duration, SysTime, msecs;
import core.sync.mutex : Mutex;
import core.time : MonoTime;
import std.algorithm : map, filter, reverse;
version(Posix)
{
	import core.sys.posix.signal : kill;
	import core.stdc.errno : errno, EPERM, EXDEV;

	// Error of rename() when source and destination are on different filesystems
	private enum crossDeviceError = EXDEV;

	// kill(pid, 0) returns 0 if the process exists; EPERM means it exists but is not ours
	private bool isProcessAlive(int pid) { return kill(pid, 0) == 0 || errno == EPERM; }

	private void moveFile(string from, string to, bool durable = false, bool retryBusy = true) { std.file.rename(from, to); }

	import core.sys.posix.fcntl : open, O_RDONLY, O_RDWR, O_CREAT, O_EXCL;

	// Missing in druntime on some platforms
	static if (__traits(compiles, { import core.sys.posix.fcntl : O_CLOEXEC; }))
		import core.sys.posix.fcntl : O_CLOEXEC;
	else version(Apple) private enum O_CLOEXEC = 0x1000000;
	else version(FreeBSD) private enum O_CLOEXEC = 0x100000;
	else version(NetBSD) private enum O_CLOEXEC = 0x400000;
	else version(OpenBSD) private enum O_CLOEXEC = 0x10000;
	else static assert(false, "O_CLOEXEC is not known on this platform");
	import core.sys.posix.unistd : close, unlink, fsync;
	import core.stdc.errno : ENOENT;
	import std.exception : ErrnoException;
	import std.string : toStringz;

	// Not in druntime for every platform; the constants are the same on Linux, macOS and BSD
	pragma(mangle, "flock") private extern(C) int flockFile(int fd, int operation) nothrow @nogc;
	private enum LOCK_EX = 2, LOCK_NB = 4;

	private alias OwnerHandle = int;

	// Creates owners/<token> locked: written in tmp/ and moved, so nobody can see it unlocked
	private OwnerHandle registerOwner(string baseDir, string token)
	{
		string tmp = buildNormalizedPath(baseDir, "tmp", "owner-" ~ token);
		int fd = open(tmp.toStringz, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 420); // 0644
		if (fd < 0) throw new ErrnoException("Cannot create " ~ tmp);

		if (flockFile(fd, LOCK_EX | LOCK_NB) != 0 )
		{
			close(fd);
			throw new ErrnoException("Cannot lock " ~ tmp);
		}

		std.file.rename(tmp, buildNormalizedPath(baseDir, "owners", token));
		return fd;
	}

	// Removes the owner file at exit (the lock is still held: nobody can take it in the meanwhile)
	private void unregisterOwner(string baseDir, string token, OwnerHandle fd)
	{
		unlink(buildNormalizedPath(baseDir, "owners", token).toStringz);
		close(fd);
	}

	// A process after fork() shares the lock of its parent: it only drops its copy
	private void forgetOwner(OwnerHandle fd) { close(fd); }

	// The owner is alive while it holds the lock. A dead owner's file is removed.
	private bool isOwnerAlive(string baseDir, string token)
	{
		string path = buildNormalizedPath(baseDir, "owners", token);
		int fd = open(path.toStringz, O_RDONLY | O_CLOEXEC);

		// Missing: dead. Any other error: better to assume it is alive than to steal its jobs.
		if (fd < 0) return errno != ENOENT;
		scope(exit) close(fd);

		if (flockFile(fd, LOCK_EX | LOCK_NB) != 0) return true;

		unlink(path.toStringz);
		return false;
	}

	private void syncPath(string path)
	{
		int fd = open(path.toStringz, O_RDONLY | O_CLOEXEC);
		if (fd < 0) throw new ErrnoException("Cannot open " ~ path);
		scope(exit) close(fd);

		// On macOS fsync does not flush the disk cache
		version(Apple)
		{
			import core.sys.darwin.fcntl : F_FULLFSYNC;
			import core.sys.posix.fcntl : fcntl;
			if (fcntl(fd, F_FULLFSYNC) == 0) return;
		}

		if (fsync(fd) != 0) throw new ErrnoException("Cannot sync " ~ path);
	}

	private void syncFile(string path) { syncPath(path); }
	private void syncDir(string path) { syncPath(path); }
}
else version(Windows)
{
	import core.sys.windows.windows;

	private enum crossDeviceError = ERROR_NOT_SAME_DEVICE;

	// Missing in druntime
	private struct RenameInfo { BOOL replaceIfExists; HANDLE rootDirectory; DWORD fileNameLength; wchar[1] fileName; }
	private extern(Windows) BOOL SetFileInformationByHandle(HANDLE, FILE_INFO_BY_HANDLE_CLASS, LPVOID, DWORD) nothrow @nogc;
	private enum DWORD PROCESS_QUERY_LIMITED_INFORMATION = 0x1000; // Missing in druntime

	private bool isProcessAlive(int pid)
	{
		HANDLE h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, FALSE, cast(DWORD) pid);

		// Access denied: it exists, but belongs to someone else
		if (h is null) return GetLastError() == ERROR_ACCESS_DENIED;
		scope(exit) CloseHandle(h);

		// Signaled when the process has exited
		return WaitForSingleObject(h, 0) == WAIT_TIMEOUT;
	}

	// Antivirus and indexers keep new files open for a moment, and Windows cannot rename an open file:
	// try again a few times before giving up (unless retryBusy is false: taking a job another consumer
	// is taking right now is pointless).
	private void moveFile(string from, string to, bool durable = false, bool retryBusy = true)
	{
		import core.thread : Thread;
		import std.utf : toUTF16z;

		// A move on Windows goes through a handle, and the handle follows the file: if two processes opened
		// the same job at once, the second one would move it away from the first. So the file is opened
		// without sharing (nobody else can open it until it has moved) and moved with that same handle.
		void move()
		{
			import std.utf : toUTF16;

			DWORD access = DELETE | SYNCHRONIZE | (durable ? GENERIC_WRITE : 0);
			HANDLE h = CreateFileW(from.toUTF16z, access, 0, null, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_BACKUP_SEMANTICS, null);
			if (h == INVALID_HANDLE_VALUE) throw new FileException(from, GetLastError());
			scope(exit) CloseHandle(h);

			wstring target = to.toUTF16;
			auto buffer = new ubyte[RenameInfo.sizeof + target.length * wchar.sizeof];
			auto info = cast(RenameInfo*) buffer.ptr;
			info.replaceIfExists = TRUE;
			info.fileNameLength = cast(DWORD)(target.length * wchar.sizeof);
			(cast(wchar*) &info.fileName)[0 .. target.length] = target[];

			if (!SetFileInformationByHandle(h, FILE_INFO_BY_HANDLE_CLASS.FileRenameInfo, info, cast(DWORD) buffer.length))
				throw new FileException(from, GetLastError());

			// With durable, the move is written to the disk before returning
			if (durable && !FlushFileBuffers(h)) throw new FileException(to, GetLastError());
		}

		foreach (attempt; 0 .. 6)
		{
			try { move(); return; }
			catch (FileException e)
			{
				bool busy = e.errno == ERROR_ACCESS_DENIED || e.errno == ERROR_SHARING_VIOLATION || e.errno == ERROR_LOCK_VIOLATION;
				if (!busy || !retryBusy || attempt == 5) throw e;
				Thread.sleep((10 << attempt).msecs);
			}
		}
	}

	// Paths longer than MAX_PATH need the \\?\ prefix, which requires an absolute path with backslashes
	private string longPath(string path)
	{
		string p = buildNormalizedPath(absolutePath(path));
		if (p.startsWith(`\\?\`)) return p;
		if (p.startsWith(`\\`)) return `\\?\UNC\` ~ p[2..$];
		return `\\?\` ~ p;
	}

	private alias OwnerHandle = HANDLE;

	// owners/<token> opened without sharing reads: nobody else can open it while the owner is alive,
	// and it is deleted when the owner exits or dies
	private OwnerHandle registerOwner(string baseDir, string token)
	{
		import std.utf : toUTF16z;

		string path = buildNormalizedPath(baseDir, "owners", token);
		// Shared for deleting only, so that the queue directory can still be removed
		HANDLE h = CreateFileW(path.toUTF16z, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_DELETE, null, CREATE_NEW,
			FILE_ATTRIBUTE_NORMAL | FILE_FLAG_DELETE_ON_CLOSE, null);

		if (h == INVALID_HANDLE_VALUE) throw new FileException(path, GetLastError());
		return h;
	}

	private void unregisterOwner(string baseDir, string token, OwnerHandle h) { CloseHandle(h); }
	private void forgetOwner(OwnerHandle h) {}

	private bool isOwnerAlive(string baseDir, string token)
	{
		import std.utf : toUTF16z;

		string path = buildNormalizedPath(baseDir, "owners", token);
		HANDLE h = CreateFileW(path.toUTF16z, GENERIC_READ, 0, null, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, null);

		if (h == INVALID_HANDLE_VALUE)
		{
			auto error = GetLastError();

			// Missing: dead. In use, or any other error: better to assume it is alive than to steal its jobs.
			return error != ERROR_FILE_NOT_FOUND && error != ERROR_PATH_NOT_FOUND;
		}

		// Opened: nobody holds it
		CloseHandle(h);
		try std.file.remove(path); catch (Exception e) {}
		return false;
	}

	private void syncFile(string path)
	{
		import std.utf : toUTF16z;

		HANDLE h = CreateFileW(path.toUTF16z, GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
			null, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, null);

		if (h == INVALID_HANDLE_VALUE) throw new FileException(path, GetLastError());
		scope(exit) CloseHandle(h);

		if (!FlushFileBuffers(h)) throw new FileException(path, GetLastError());
	}

	// Directories are made durable by MOVEFILE_WRITE_THROUGH in moveFile
	private void syncDir(string path) {}

	// The same path without the prefix when it is not needed: not every program accepts it
	private string shortPath(string path)
	{
		if (path.startsWith(`\\?\UNC\`) && path.length - 6 < MAX_PATH) return `\\` ~ path[8..$];
		if (path.startsWith(`\\?\`) && !path.startsWith(`\\?\UNC\`) && path.length - 4 < MAX_PATH) return path[4..$];
		return path;
	}
}
else static assert(false, "pacchettino supports POSIX systems and Windows only");

import std.file, std.path;

// Processing directories currently in use by this process (shared across threads and instances).
// Used to tell apart our own active jobs from stale ones left by a previous process with the same PID.
private __gshared bool[string] activeJobs;
private __gshared Mutex activeJobsMutex;

// Jobs listed by receiveOne and not taken yet, by queue and order; last maintenance of each queue
private __gshared string[][string] listed_;
private __gshared MonoTime[string] lastMaintenance;
private __gshared Mutex listedMutex;

shared static this() { activeJobsMutex = new Mutex(); listedMutex = new Mutex(); }

// With CrashDetection.LOCK_FILE every consumer process holds a lock on <baseDir>/owners/<token> while
// it is alive: its jobs are in processing/<job>.<token>. A job whose owner lock can be taken belongs to
// a dead process. Unlike PIDs, this works also between containers with their own PID namespace.
private struct Owner { string token; int pid; OwnerHandle handle; }
private __gshared Owner[string] owners; // by baseDir, guarded by activeJobsMutex

shared static ~this()
{
	foreach (baseDir, owner; owners)
		if (owner.pid == thisProcessID)
			try unregisterOwner(baseDir, owner.token, owner.handle); catch (Exception e) {}
}

// Tokens are 10 characters [0-9a-z] starting with a letter, so they are never mistaken for the PIDs
// used as suffix by older versions (which in turn ignore them)
private enum tokenLength = 10;

private string newToken()
{
	enum letters = "abcdefghijklmnopqrstuvwxyz";
	enum chars = "0123456789abcdefghijklmnopqrstuvwxyz";

	ubyte[16] random = UUIDv4!ubyte();
	char[tokenLength] token;
	token[0] = letters[random[0] % letters.length];
	foreach (i; 1 .. tokenLength) token[i] = chars[random[i] % chars.length];
	return token.idup;
}

private bool isToken(string s)
{
	import std.ascii : isLowercaseLetter = isLower, isDigit;
	import std.algorithm : all;
	return s.length == tokenLength && s[0].isLowercaseLetter && s.all!(c => c.isLowercaseLetter || c.isDigit);
}

private bool isLegacyPid(string s)
{
	import std.ascii : isDigit;
	import std.algorithm : all;
	return s.length > 0 && s.all!(c => c.isDigit);
}

// The token of this process for baseDir, registered on first use
private string ownerToken(string baseDir)
{
	activeJobsMutex.lock();
	scope(exit) activeJobsMutex.unlock();

	int pid = thisProcessID;

	if (auto owner = baseDir in owners)
	{
		if (owner.pid == pid) return owner.token;

		// We are a child created by fork(): the lock belongs to the parent
		forgetOwner(owner.handle);
		owners.remove(baseDir);
	}

	mkdirRecurse(buildNormalizedPath(baseDir, "owners"));

	string token = newToken();
	owners[baseDir] = Owner(token, pid, registerOwner(baseDir, token));
	return token;
}

// The token of this process for baseDir, or null if it never processed jobs there
private string currentToken(string baseDir)
{
	activeJobsMutex.lock();
	scope(exit) activeJobsMutex.unlock();

	if (auto owner = baseDir in owners)
		if (owner.pid == thisProcessID) return owner.token;

	return null;
}

// Max length of a file name (NAME_MAX). The longest names used are:
// "fle-<uuid>-<name>.<token>" in processing/ and "<due ms>-fle-<uuid>-<name>" in scheduled/.
private enum maxNameLength = 255;
private enum jobNameOverhead = "fle-".length + 36 + "-".length;
private enum ownerSuffixLength = ".".length + 10; // tokenLength, or a PID of older versions
private enum dueLength = 13; // Unix time in ms, zero padded (enough until year 2286)
private enum duePrefixLength = dueLength + "-".length;
private enum maxFileNameLength = maxNameLength - jobNameOverhead - (duePrefixLength > ownerSuffixLength ? duePrefixLength : ownerSuffixLength);

// Current unix time in ms
private long nowMsecs()
{
	import std.datetime : unixTimeToStdTime;
	return (Clock.currStdTime - unixTimeToStdTime(0)) / 10_000;
}

/**
 * A simple file-based queue system designed to be safe for concurrent use across multiple threads and processes.
 */
class Pacchettino
{
	/**
	 * Result of a job processing.
	 */
	enum Result
	{
		SUCCESS, /// Job completed successfully
		FAILED,  /// Job failed
		RETRY    /// Job should be retried
	}

	/**
	 * How consumers tell a crashed consumer from one still working on its job.
	 */
	enum CrashDetection
	{
		/// By process ID (default). For consumers on the same machine, sharing the same PID namespace.
		PID,

		/**
		 * By a lock file each consumer process holds in `owners/` while alive: the operating system
		 * releases it when the process dies. Use it when consumers run in different containers
		 * (each with its own PIDs) on the same directory; set it on all of them.
		 * Slightly slower: one more file open for each job being processed by others.
		 */
		LOCK_FILE
	}

	/**
	 * Status of a job.
	 */
	enum Status
	{
		UNKNOWN,     /// Job not found (never sent, or not kept by the keep policy)
		QUEUED,      /// Job is waiting to be processed
		PROCESSING,  /// Job is being processed
		SUCCESS,     /// Job completed successfully
		FAILED,      /// Job failed
		INTERRUPTED, /// Job was interrupted by a crashed process
		SCHEDULED    /// Job is waiting for its delay to expire before being queued
	}

	/**
	 * Policy for keeping processed files.
	 * Options can be combined using bitwise OR (e.g. SUCCESS | FAILED).
	 */
	enum KeepPolicy
	{
		NONE = 0,             /// Keep no files
		SUCCESS = 1 << 0,     /// Keep successful files
		FAILED = 1 << 1,      /// Keep failed files
		INTERRUPTED = 1 << 2, /// Keep interrupted files
		ALL = SUCCESS | FAILED | INTERRUPTED /// Keep all files
	}

	/**
	 * Constructs a new Pacchettino instance.
	 *
	 * Params:
	 *   baseDir = The base directory for the queue.
	 *   keepPolicy = The policy for keeping processed files.
	 */
	this(string baseDir, KeepPolicy keepPolicy = KeepPolicy.ALL) {
		// The paths of the jobs can exceed MAX_PATH
		version(Windows) baseDir = longPath(baseDir);
		else baseDir = buildNormalizedPath(baseDir);

		this.baseDir = baseDir;
		this.root = baseDir.endsWith(dirSeparator) ? baseDir : baseDir ~ dirSeparator;
		this.onFileReceived = (id, name, path) => Result.FAILED;
		this.onDataReceived = (id, data) => Result.FAILED;
		this.keepPolicy = keepPolicy;

		if (!exists(baseDir)) mkdirRecurse(baseDir);
		else if (!isDir(baseDir)) throw new Exception("Base directory is not a directory");

		mkdirRecurse(buildNormalizedPath(baseDir, "failed"));
		mkdirRecurse(buildNormalizedPath(baseDir, "success"));
		mkdirRecurse(buildNormalizedPath(baseDir, "queued"));
		mkdirRecurse(buildNormalizedPath(baseDir, "tmp"));
		mkdirRecurse(buildNormalizedPath(baseDir, "processing"));
		mkdirRecurse(buildNormalizedPath(baseDir, "interrupted"));
		mkdirRecurse(buildNormalizedPath(baseDir, "scheduled"));
	}

	/**
	 * Sends a string to the queue.
	 *
	 * Params:
	 *   s = The string to send.
	 *   delay = How long to wait before the job can be processed.
	 *
	 * Returns:
	 *   The ID of the queued job.
	 */
	string sendData(string s, Duration delay = Duration.zero) const { return sendData(s.representation, delay); }

	/**
	 * Sends raw bytes to the queue.
	 *
	 * Params:
	 *   s = The bytes to send.
	 *   delay = How long to wait before the job can be processed.
	 *
	 * Returns:
	 *   The ID of the queued job.
	 */
	string sendData(const ubyte[] s, Duration delay = Duration.zero) const
	{
		auto id = UUIDv7!string();
		auto tmp = pathIn("tmp", id);
		auto path = enqueuePath("raw-" ~ id, delay);

		try
		{
			std.file.write(tmp, s);
			if (durable) syncFile(tmp);
			commitMove(tmp, path);
		}
		catch (Exception e)
		{
			if (tmp.exists) try { std.file.remove(tmp); } catch (Exception) {}
			throw e;
		}

		return id;
	}

	/**
	 * Sends a file to the queue.
	 *
	 * Params:
	 *   filePath = The path to the file to send.
	 *   copyFile = Whether to copy the file (true) or move it (false).
	 *   delay = How long to wait before the job can be processed.
	 *
	 * Returns:
	 *   The ID of the queued job.
	 *
	 * Throws:
	 *   Exception if the file does not exist or its name is too long to be queued.
	 */
	string sendFile(const string filePath, bool copyFile = true, Duration delay = Duration.zero) const
	{
		// The path given can exceed MAX_PATH too
		version(Windows) string source = longPath(filePath);
		else string source = filePath;

		if (!exists(source))
			throw new Exception("File not found: " ~ filePath);

		if (filePath.baseName.length > maxFileNameLength)
			throw new Exception("File name too long (max " ~ maxFileNameLength.to!string ~ " bytes): " ~ filePath.baseName);

		auto id = UUIDv7!string();
		auto tmp = pathIn("tmp", id);
		auto path = enqueuePath("fle-" ~ id ~ "-" ~ filePath.baseName, delay);

		if (copyFile)
			std.file.copy(source, tmp);
		else
		{
			try moveFile(source, tmp);
			catch (FileException e)
			{
				// Different filesystems: fall back to copy + remove
				if (e.errno != crossDeviceError) throw e;
				std.file.copy(source, tmp);
				std.file.remove(source);
			}
		}

		try
		{
			if (durable) syncFile(tmp);
			commitMove(tmp, path);
		}
		catch (Exception e)
		{
			if (tmp.exists) try { std.file.remove(tmp); } catch (Exception) {}
			throw e;
		}

		return id;
	}

	// Moves a job to another directory; with durable, the move is on the disk when it returns
	private void commitMove(string from, string to) const
	{
		moveFile(from, to, durable);
		if (durable) syncDir(to.dirName);
	}

	// Where to put a job: queued/ or, if delayed, scheduled/ with the due time as prefix
	private string enqueuePath(string jobName, Duration delay) const
	{
		import std.format : format;

		if (delay <= Duration.zero) return pathIn("queued", jobName);
		return pathIn("scheduled", format("%0*d-%s", dueLength, nowMsecs + delay.total!"msecs", jobName));
	}

	// Moves the scheduled jobs whose delay expired to the queue
	private size_t promoteScheduled() const
	{
		auto entries = dirEntries(pathIn("scheduled"), "*-{fle,raw}-*", SpanMode.shallow).array;
		entries.sort!((a, b) => a.baseName < b.baseName);

		long now = nowMsecs;
		size_t promoted = 0;

		foreach (entry; entries)
		{
			string name = entry.baseName;
			if (name.length <= duePrefixLength) continue;

			long due;
			try due = name[0..dueLength].to!long;
			catch (Exception e) continue;

			// Sorted by due time: nothing else is ready
			if (due > now) break;

			try { commitMove(entry.name, pathIn("queued", name[duePrefixLength..$])); promoted++; }
			catch (Exception e) {} // Promoted by someone else in the meanwhile
		}

		return promoted;
	}


	// Accepts both the id returned by send* and the one passed to callbacks ("raw-<id>" or "fle-<id>-<name>")
	private static string jobKey(string id)
	{
		if (id.length > 4 && (id.startsWith("fle-") || id.startsWith("raw-"))) return id[4..$];
		return id;
	}

	// Returns the path of the job in the directory, or null if not found
	private string findJob(string id, string directory) const
	{
		string key = jobKey(id);
		if (key.length == 0) return null;

		// Scheduled jobs have the due time as prefix
		bool scheduled = directory == "scheduled";
		size_t skip = (scheduled ? duePrefixLength : 0) + 4;

		foreach (f; dirEntries(pathIn(directory), scheduled ? "*-{fle,raw}-*" : "{fle,raw}-*", SpanMode.shallow))
			if (f.baseName.length > skip && f.baseName[skip..$].startsWith(key))
				return f.name;

		return null;
	}

	private bool isInDirectory(string id, string directory) const => findJob(id, directory) !is null;

	private size_t countIn(string directory) const
	{
		return dirEntries(pathIn(directory), "{fle,raw}-*", SpanMode.shallow).walkLength;
	}

	/**
	 * Checks if a job is currently being processed.
	 *
	 * Params:
	 *   id = The job ID.
	 *
	 * Returns:
	 *   True if the job is processing, false otherwise.
	 */
	bool isProcessing(string id) const => isInDirectory(id, "processing");

	/**
	 * Checks if a job is scheduled (sent with a delay not yet expired).
	 *
	 * Params:
	 *   id = The job ID.
	 *
	 * Returns:
	 *   True if the job is scheduled, false otherwise.
	 */
	bool isScheduled(string id) const => isInDirectory(id, "scheduled");

	/**
	 * Checks if a job is queued.
	 *
	 * Params:
	 *   id = The job ID.
	 *
	 * Returns:
	 *   True if the job is queued, false otherwise.
	 */
	bool isQueued(string id) const => isInDirectory(id, "queued");

	/**
	 * Checks if a job was interrupted.
	 *
	 * Params:
	 *   id = The job ID.
	 *
	 * Returns:
	 *   True if the job was interrupted, false otherwise.
	 *
	 * Throws:
	 *   Exception if the keep policy does not keep interrupted jobs.
	 */
	bool isInterrupted(string id) const {
		if (!(keepPolicy & KeepPolicy.INTERRUPTED)) throw new Exception("isInterrupted is not supported when INTERRUPTED policy is not set");
		return isInDirectory(id, "interrupted");
	}

	/**
	 * Checks if a job failed.
	 *
	 * Params:
	 *   id = The job ID.
	 *
	 * Returns:
	 *   True if the job failed, false otherwise.
	 *
	 * Throws:
	 *   Exception if the keep policy does not keep failed jobs.
	 */
	bool isFailed(string id) const {
		if (!(keepPolicy & KeepPolicy.FAILED)) throw new Exception("isFailed is not supported when FAILED policy is not set");
		return isInDirectory(id, "failed");
	}

	/**
	 * Checks if a job succeeded.
	 *
	 * Params:
	 *   id = The job ID.
	 *
	 * Returns:
	 *   True if the job succeeded, false otherwise.
	 *
	 * Throws:
	 *   Exception if the keep policy does not keep successful jobs.
	 */
	bool isSuccess(string id) const {
		if (!(keepPolicy & KeepPolicy.SUCCESS)) throw new Exception("isSuccess is not supported when SUCCESS policy is not set");
		return isInDirectory(id, "success");
	}

	/**
	 * Counts the number of jobs currently queued.
	 *
	 * Returns:
	 *   The number of queued jobs.
	 */
	size_t countQueued() const
	{
		return countIn("queued");
	}

	/**
	 * Counts the number of jobs currently being processed.
	 *
	 * Returns:
	 *   The number of processing jobs.
	 */
	size_t countProcessing() const
	{
		return countIn("processing");
	}

	/**
	 * Counts the number of jobs that completed successfully.
	 *
	 * Throws:
	 *   Exception if the keep policy does not keep successful jobs.
	 *
	 * Returns:
	 *   The number of successful jobs.
	 */
	size_t countSuccessful() const
	{
		if (!(keepPolicy & KeepPolicy.SUCCESS))
			throw new Exception("countSuccessful is not supported when SUCCESS policy is not set");
		return countIn("success");
	}

	/**
	 * Counts the number of jobs that failed.
	 *
	 * Throws:
	 *   Exception if the keep policy does not keep failed jobs.
	 *
	 * Returns:
	 *   The number of failed jobs.
	 */
	size_t countFailed() const
	{
		if (!(keepPolicy & KeepPolicy.FAILED))
			throw new Exception("countFailed is not supported when FAILED policy is not set");
		return countIn("failed");
	}

	/**
	 * Counts the number of jobs that were interrupted.
	 *
	 * Throws:
	 *   Exception if the keep policy does not keep interrupted jobs.
	 *
	 * Returns:
	 *   The number of interrupted jobs.
	 */
	size_t countInterrupted() const
	{
		if (!(keepPolicy & KeepPolicy.INTERRUPTED))
			throw new Exception("countInterrupted is not supported when INTERRUPTED policy is not set");
		return countIn("interrupted");
	}

	/**
	 * Counts the number of jobs scheduled (sent with a delay not yet expired).
	 *
	 * Returns:
	 *   The number of scheduled jobs.
	 */
	size_t countScheduled() const
	{
		return dirEntries(pathIn("scheduled"), "*-{fle,raw}-*", SpanMode.shallow).walkLength;
	}

	/**
	 * Counts the total number of jobs in all states (based on current keep policy).
	 *
	 * Returns:
	 *   The total number of jobs across all applicable directories.
	 */
	size_t countAll() const
	{
		size_t total = countScheduled() + countQueued() + countProcessing();

		if (keepPolicy & KeepPolicy.SUCCESS) total += countSuccessful();
		if (keepPolicy & KeepPolicy.FAILED) total += countFailed();
		if (keepPolicy & KeepPolicy.INTERRUPTED) total += countInterrupted();

		return total;
	}

	/**
	 * Returns the status of a job. Unlike the is* methods, it never throws.
	 *
	 * Params:
	 *   id = The job ID.
	 *
	 * Returns:
	 *   The job status, or Status.UNKNOWN if the job is not found.
	 */
	Status status(string id) const
	{
		// Checked following the job lifecycle, so a job moving forward in the meanwhile is not missed
		if (isInDirectory(id, "scheduled")) return Status.SCHEDULED;
		if (isInDirectory(id, "queued")) return Status.QUEUED;
		if (isInDirectory(id, "processing")) return Status.PROCESSING;
		if (isInDirectory(id, "success")) return Status.SUCCESS;
		if (isInDirectory(id, "failed")) return Status.FAILED;
		if (isInDirectory(id, "interrupted")) return Status.INTERRUPTED;
		return Status.UNKNOWN;
	}

	/**
	 * Returns the time a job was sent, extracted from its ID.
	 *
	 * Params:
	 *   id = The job ID.
	 *
	 * Throws:
	 *   Exception if the ID is not valid.
	 */
	static SysTime sentAt(string id)
	{
		import std.datetime : UTC, unixTimeToStdTime;
		import std.string : replace;

		string hex = jobKey(id);
		if (hex.length < 36 || hex[14] != '7') throw new Exception("Invalid job id: " ~ id);

		long msecs = hex[0..13].replace("-", "").to!long(16);
		return SysTime(unixTimeToStdTime(msecs / 1000) + (msecs % 1000) * 10_000, UTC());
	}

	/**
	 * Moves a failed, interrupted or successful job back to the queue.
	 *
	 * Params:
	 *   id = The job ID.
	 *
	 * Returns:
	 *   True if the job was found and queued again, false otherwise.
	 */
	bool requeue(string id) const
	{
		foreach (dir; ["failed", "interrupted", "success"])
		{
			string path = findJob(id, dir);
			if (path is null) continue;

			try { commitMove(path, pathIn("queued", path.baseName)); return true; }
			catch (Exception e) {} // Moved by someone else in the meanwhile
		}

		return false;
	}

	/**
	 * Moves all jobs in the given directories back to the queue.
	 *
	 * Params:
	 *   which = Which directories to requeue from (e.g. KeepPolicy.FAILED | KeepPolicy.INTERRUPTED).
	 *
	 * Returns:
	 *   The number of queued jobs.
	 */
	size_t requeueAll(KeepPolicy which = KeepPolicy.FAILED | KeepPolicy.INTERRUPTED) const
	{
		size_t moved = 0;

		foreach (flag, dir; [KeepPolicy.SUCCESS : "success", KeepPolicy.FAILED : "failed", KeepPolicy.INTERRUPTED : "interrupted"])
		{
			if (!(which & flag)) continue;

			foreach (entry; dirEntries(pathIn(dir), "{fle,raw}-*", SpanMode.shallow).array)
			{
				try { commitMove(entry.name, pathIn("queued", entry.baseName)); moved++; }
				catch (Exception e) {} // Moved by someone else in the meanwhile
			}
		}

		return moved;
	}

	/**
	 * Removes processed jobs kept in the success, failed and/or interrupted directories.
	 *
	 * Params:
	 *   which = Which directories to clean (e.g. KeepPolicy.SUCCESS | KeepPolicy.FAILED).
	 *   olderThan = Only remove jobs whose last modification time is older than this. Zero removes all.
	 *
	 * Returns:
	 *   The number of removed jobs.
	 */
	size_t cleanup(KeepPolicy which = KeepPolicy.ALL, Duration olderThan = Duration.zero) const
	{
		size_t removed = 0;
		SysTime limit = Clock.currTime - olderThan;

		foreach (flag, dir; [KeepPolicy.SUCCESS : "success", KeepPolicy.FAILED : "failed", KeepPolicy.INTERRUPTED : "interrupted"])
		{
			if (!(which & flag)) continue;

			foreach (entry; dirEntries(pathIn(dir), "{fle,raw}-*", SpanMode.shallow).array)
			{
				try
				{
					if (olderThan != Duration.zero && entry.timeLastModified > limit) continue;
					if (entry.isDir) rmdirRecurse(entry.name);
					else std.file.remove(entry.name);
					removed++;
				}
				catch (Exception e) {} // Already removed by someone else
			}
		}

		return removed;
	}

	/**
	 * Processes all available jobs in the queue.
	 *
	 * Params:
	 *   randomize = Whether to process jobs in random order. If false, jobs are processed in the order they were sent.
	 *
	 * Returns:
	 *   The number of processed jobs.
	 */
	size_t receive(bool randomize = true) const { return receiveImpl(randomize, 0); }

	/**
	 * Processes a single job from the queue.
	 *
	 * Params:
	 *   randomize = Whether to select a job randomly. If false, the oldest job is selected.
	 *
	 * Returns:
	 *   True if a job was processed, false if the queue was empty.
	 */
	bool receiveOne(bool randomize = true) const { return receiveNext(randomize); }

	/**
	 * Waits for a job and processes it.
	 *
	 * Params:
	 *   timeout = How long to wait for a job.
	 *   randomize = Whether to select a job randomly. If false, the oldest job is selected.
	 *   pollInterval = How often to check the queue while waiting.
	 *
	 * Returns:
	 *   True if a job was processed, false if the timeout expired.
	 */
	bool receiveOne(Duration timeout, bool randomize = true, Duration pollInterval = 100.msecs) const
	{
		import core.thread : Thread;
		import std.algorithm : min;
		import core.time : MonoTime;

		auto deadline = MonoTime.currTime + timeout;

		while (true)
		{
			if (receiveOne(randomize)) return true;

			auto left = deadline - MonoTime.currTime;
			if (left <= Duration.zero) return false;

			Thread.sleep(min(pollInterval, left));
		}
	}

	/**
	 * Checks for stalled jobs in the processing folder belonging to no longer existing processes.
	 * If the associated process (PID in the name) does not exist, the job is marked as interrupted.
	 */
	private void recoverStalledJobs() const
	{
		auto processingDirs = dirEntries(pathIn("processing"), SpanMode.shallow).array;
		int myPid = thisProcessID;
		string myToken = currentToken(baseDir);
		bool lockFiles = myToken !is null;

		foreach (dir; processingDirs)
		{
			// Removed in the meanwhile by the consumer that was processing it
			bool isDirectory;
			try isDirectory = dir.isDir;
			catch (FileException e) continue;

			if (!isDirectory) continue;

			string dirName = dir.baseName;
			auto lastDot = dirName.lastIndexOf('.');

			// Not a job being processed
			if (lastDot == -1 || lastDot == dirName.length - 1) continue;

			string owner = dirName[lastDot + 1 .. $];
			bool isAlive;

			try
			{
				// Our own job: alive only if this process is actually working on it
				if (owner == myToken || (isLegacyPid(owner) && owner.to!int == myPid))
				{
					activeJobsMutex.lock();
					scope(exit) activeJobsMutex.unlock();
					isAlive = (dirName in activeJobs) !is null;
				}
				else if (isToken(owner)) { isAlive = isOwnerAlive(baseDir, owner); lockFiles = true; }
				else if (isLegacyPid(owner)) isAlive = isProcessAlive(owner.to!int); // Left by an older version
				else continue;
			}
			catch (Exception e) continue;

			if (isAlive) continue;

			// The owner is dead: move the job (the file inside, with its original name or "raw") to interrupted
			string jobName = dirName[0 .. lastDot];

			if (keepPolicy & KeepPolicy.INTERRUPTED)
			{
				try
				{
					foreach (entry; dirEntries(dir, SpanMode.shallow))
						try moveFile(entry.name, pathIn("interrupted", jobName), durable);
						catch (Exception e) {}

					if (durable) syncDir(pathIn("interrupted"));
				}
				catch (Exception e) {}
			}

			try { rmdirRecurse(dir); } catch (Exception e) {}
		}

		// Lock files of owners that died without jobs left
		if (lockFiles) try
		{
			foreach (entry; dirEntries(pathIn("owners"), SpanMode.shallow).array)
				if (entry.baseName != myToken && isToken(entry.baseName))
					try isOwnerAlive(baseDir, entry.baseName); catch (Exception e) {}
		}
		catch (Exception e) {}
	}


	// receive(): every job queued now
	private size_t receiveImpl(bool randomize = true, size_t maxFiles = 0) const
	{
		string owner = jobOwner();

		// Before processing new files, check for orphan files and expired delays
		maintenance();

		size_t processed = 0;

		foreach (id; listQueued(randomize))
		{
			if (maxFiles > 0 && processed >= maxFiles) break;
			if (processJob(id, owner)) processed++;
		}

		return processed;
	}

	// receiveOne(): the jobs listed are kept, shared by the threads of this process, and taken one at
	// a time: the directory is listed again only when they are over. Listing it for every job would make
	// each receiveOne as slow as the queue is long.
	private bool receiveNext(bool randomize) const
	{
		string owner = jobOwner();
		string key = baseDir ~ (randomize ? "\0random" : "\0fifo");

		// Orphans and expired delays: at most every 100 ms. Jobs promoted to the queue are older than
		// the ones listed: list again.
		if (maintenanceDue() && maintenance()) dropListed();

		bool listed = false;

		while (true)
		{
			string id;

			synchronized (listedMutex)
			{
				auto jobs = key in listed_;

				if (jobs is null || (*jobs).length == 0)
				{
					if (listed) return false;

					// Reversed: the next job is at the end
					auto fresh = listQueued(randomize);
					fresh.reverse();
					listed_[key] = fresh;
					listed = true;

					jobs = key in listed_;
					if ((*jobs).length == 0) return false;
				}

				id = (*jobs)[$ - 1];
				*jobs = (*jobs)[0 .. $ - 1];
			}

			if (processJob(id, owner)) return true;
		}
	}

	// How our jobs are marked. The token is registered before looking for orphans, so that our own
	// jobs are never taken for someone else's.
	private string jobOwner() const
	{
		return crashDetection == CrashDetection.LOCK_FILE ? ownerToken(baseDir) : thisProcessID.to!string;
	}

	// Names of the queued jobs, in the order they should be processed
	private string[] listQueued(bool randomize) const
	{
		auto ids = jobNames(pathIn("queued"));

		// UUIDv7 ids are time ordered: sorting by id gives FIFO order
		if (randomize) ids.randomShuffle();
		else ids.sort!((a, b) => a[4..$] < b[4..$]);

		return ids;
	}

	// Names of the jobs in a directory (fle-* and raw-*)
	private static string[] jobNames(string dir)
	{
		bool isJob(const(char)[] name) { return name.length > 4 && (name[0..4] == "fle-" || name[0..4] == "raw-"); }

		// Only the names are needed: much faster than dirEntries, which builds a path for each entry
		version(Posix)
		{
			import core.sys.posix.dirent : opendir, readdir, closedir;
			import core.stdc.string : strlen;
			import std.string : toStringz;
			import std.exception : ErrnoException;

			auto d = opendir(dir.toStringz);
			if (d is null) throw new ErrnoException("Cannot list " ~ dir);
			scope(exit) closedir(d);

			string[] names;

			while (auto entry = readdir(d))
			{
				auto name = entry.d_name.ptr[0 .. strlen(entry.d_name.ptr)];
				if (isJob(name)) names ~= name.idup;
			}

			return names;
		}
		else return dirEntries(dir, SpanMode.shallow).map!(f => f.baseName).filter!(n => isJob(n)).array;
	}

	// Jobs listed by receiveOne are forgotten: listed again at the next call (e.g. after a promotion)
	private void dropListed() const
	{
		synchronized (listedMutex)
		{
			listed_.remove(baseDir ~ "\0random");
			listed_.remove(baseDir ~ "\0fifo");
		}
	}

	private bool maintenanceDue() const
	{
		import core.time : MonoTime;

		synchronized (listedMutex)
		{
			auto last = baseDir in lastMaintenance;
			return last is null || MonoTime.currTime - *last >= 100.msecs;
		}
	}

	// Recovers the orphans and promotes the expired delays. True if some jobs were queued.
	private bool maintenance() const
	{
		import core.time : MonoTime;

		synchronized (listedMutex) lastMaintenance[baseDir] = MonoTime.currTime;

		recoverStalledJobs();
		return promoteScheduled() > 0;
	}

	// Takes the job, gives it to the callback, and moves it according to the result.
	// False if the job was not taken: already taken by someone else, or not a valid job.
	private bool processJob(string id, string owner) const
	{
		Result result = Result.FAILED;
		bool isFile = id.startsWith("fle-");
		string name = "raw";

		// fle-<uuid>-<name>
		if (isFile)
		{
			if (id.length <= jobNameOverhead || id[jobNameOverhead - 1] != '-') return false;
			name = id[jobNameOverhead .. $];
		}

		// Unique directory name with the owner: id.pid or id.token
		string processingDirName = id ~ "." ~ owner;
		string processingDirPath = pathIn("processing", processingDirName);
		string path = processingDirPath ~ dirSeparator ~ name;

		// Already taken by someone else: one stat, cheaper than trying to take it
		string queued = pathIn("queued", id);
		if (!queued.exists) return false;

		// Lock between threads of this process
		synchronized (activeJobsMutex)
		{
			if (processingDirName in activeJobs) return false;
			activeJobs[processingDirName] = true;
		}

		scope(exit) synchronized (activeJobsMutex) activeJobs.remove(processingDirName);

		// A lock on the directory is needed
		try { mkdir(processingDirPath); }
		catch (Exception e) { return false; }

		// The lock between processes: only one can move the job out of the queue
		try { moveFile(queued, path, false, false); }
		catch (Exception e) { try { rmdir(processingDirPath); } catch (Exception) {} return false; }

		if (isFile)
		{
			version(Windows) string userPath = shortPath(path);
			else string userPath = path;

			try {	result = onFileReceived(id, name, userPath); }
			catch (Exception e) { result = Result.FAILED; }

			if (!path.exists && keepPolicy != KeepPolicy.NONE)
			{
				warning("File ", path, " was moved or deleted by the user callback. It should be kept in the processing directory.");
			}
		}
		else
		{
			try {
				auto data = cast(ubyte[])std.file.read(path);
				result = onDataReceived(id, data);
			}
			catch (Exception e) { result = Result.FAILED; }
		}

		bool moved = false;

		try {
			if (result == Result.FAILED && (keepPolicy & KeepPolicy.FAILED)) { commitMove(path, pathIn("failed", id)); moved = true; }
			else if (result == Result.SUCCESS && (keepPolicy & KeepPolicy.SUCCESS)) { commitMove(path, pathIn("success", id)); moved = true; }
			else if (result == Result.RETRY) { commitMove(path, enqueuePath(id, retryDelay)); moved = true; }
		}
		catch (Exception e) { warning("Pacchettino rename error: ", e.msg); }

		try
		{
			// Not kept
			if (!moved) try std.file.remove(path); catch (Exception e) {}

			try rmdir(processingDirPath);
			catch (Exception e) rmdirRecurse(processingDirPath); // Something else was left inside

			// A job not kept must not come back after a power cut
			if (durable && !moved) syncDir(pathIn("processing"));
		}
		catch (Exception e) { warning("Pacchettino cleanup error: ", e.msg); }

		return true;
	}


	/**
	 * Callback triggered when a file is received.
	 *
	 * It is called with the job ID (`"fle-<uuid>-<name>"`: `status`, `requeue`, `sentAt` and the
	 * `is*` methods accept it), the original name of the file and its path on disk. The file
	 * can be read, but should not be moved or deleted: it is moved to `success/`, `failed/` or
	 * back to the queue according to the returned `Result`, and deleted if not kept.
	 * An exception thrown by the callback counts as `Result.FAILED`.
	 *
	 * The default callback returns `Result.FAILED`.
	 */
	Result delegate(string id, string name, string path) onFileReceived;

	/**
	 * Callback triggered when data is received.
	 *
	 * It is called with the job ID (`"raw-<uuid>"`: `status`, `requeue`, `sentAt` and the `is*`
	 * methods accept it) and the bytes sent with `sendData`. An exception thrown by the
	 * callback counts as `Result.FAILED`.
	 *
	 * The default callback returns `Result.FAILED`.
	 */
	Result delegate(string id, ubyte[] data) onDataReceived;

	/**
	 * How this consumer marks the jobs it is processing. See `CrashDetection`.
	 * Jobs marked in either way by other consumers are always recognized.
	 */
	CrashDetection crashDetection = CrashDetection.PID;

	/**
	 * Write to the disk before returning.
	 *
	 * By default the jobs are in the filesystem when `sendData` and `sendFile` return, so they
	 * survive a crash or a kill of the program, and a normal reboot. But the operating system writes
	 * them to the disk a few seconds later: after a power cut, or a crash of the whole system, the
	 * last jobs can be lost, or be found empty.
	 *
	 * With `durable = true` every job, and every change of state, is flushed to the disk (fsync)
	 * before returning. It costs much more: a few thousand jobs per second on a SSD instead of tens of
	 * thousands, much less on SD cards and hard disks. Set it on producers and consumers alike.
	 */
	bool durable = false;

	/**
	 * How long to wait before processing again a job whose callback returned Result.RETRY.
	 * Zero (default) queues it again immediately.
	 */
	Duration retryDelay = Duration.zero;

	private string baseDir;
	private string root; // baseDir with a trailing separator

	// baseDir is normalized once, in the constructor: the other paths are joined without normalizing
	// them again, which is much faster (the names of the jobs never contain separators)
	private string pathIn(string dir) const { return root ~ dir; }
	private string pathIn(string dir, string name) const { return root ~ dir ~ dirSeparator ~ name; }
	private KeepPolicy keepPolicy;
}
