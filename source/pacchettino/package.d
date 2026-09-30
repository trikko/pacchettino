/**
 * A job queue made of plain directories: one program sends jobs, another one
 * (or many, in other processes or threads) processes them.
 *
 * A job is either some bytes (`sendData`) or a file (`sendFile`). It is written
 * to disk before `send*` returns, so nothing is lost if a program stops or
 * crashes, and a job left half done by a process that died is detected and
 * moved to `interrupted/`. Each job is given to one consumer only, even with
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
 *   $(LI `Pacchettino.KeepPolicy` — which processed jobs stay on disk.)
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
import std.algorithm : startsWith, sort;
import std.range 		: walkLength;
import std.logger 	: warning;
import std.process  : thisProcessID;
import std.datetime : Clock, Duration, SysTime, msecs;
import core.sync.mutex : Mutex;
version(Posix)
{
	import core.sys.posix.signal : kill;
	import core.stdc.errno : errno, EPERM, EXDEV;

	// Error of rename() when source and destination are on different filesystems
	private enum crossDeviceError = EXDEV;

	// kill(pid, 0) returns 0 if the process exists; EPERM means it exists but is not ours
	private bool isProcessAlive(int pid) { return kill(pid, 0) == 0 || errno == EPERM; }

	private void moveFile(string from, string to) { std.file.rename(from, to); }
}
else version(Windows)
{
	import core.sys.windows.windows;

	private enum crossDeviceError = ERROR_NOT_SAME_DEVICE;
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
	// try again a few times before giving up.
	private void moveFile(string from, string to)
	{
		import core.thread : Thread;

		foreach (attempt; 0 .. 6)
		{
			try { std.file.rename(from, to); return; }
			catch (FileException e)
			{
				bool busy = e.errno == ERROR_ACCESS_DENIED || e.errno == ERROR_SHARING_VIOLATION || e.errno == ERROR_LOCK_VIOLATION;
				if (!busy || attempt == 5) throw e;
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

shared static this() { activeJobsMutex = new Mutex(); }

// Max length of a file name (NAME_MAX). The longest names used are:
// "fle-<uuid>-<name>.<pid>" in processing/ and "<due ms>-fle-<uuid>-<name>" in scheduled/.
private enum maxNameLength = 255;
private enum jobNameOverhead = "fle-".length + 36 + "-".length;
private enum pidSuffixLength = ".".length + int.max.stringof.length;
private enum dueLength = 13; // Unix time in ms, zero padded (enough until year 2286)
private enum duePrefixLength = dueLength + "-".length;
private enum maxFileNameLength = maxNameLength - jobNameOverhead - (duePrefixLength > pidSuffixLength ? duePrefixLength : pidSuffixLength);

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

		this.baseDir = baseDir;
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
		auto tmp = buildNormalizedPath(baseDir, "tmp", id);
		auto path = enqueuePath("raw-" ~ id, delay);

		try
		{
			std.file.write(tmp, s);
			moveFile(tmp, path);
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
		auto tmp = buildNormalizedPath(baseDir, "tmp", id);
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

		try moveFile(tmp, path);
		catch (Exception e)
		{
			if (tmp.exists) try { std.file.remove(tmp); } catch (Exception) {}
			throw e;
		}

		return id;
	}

	// Where to put a job: queued/ or, if delayed, scheduled/ with the due time as prefix
	private string enqueuePath(string jobName, Duration delay) const
	{
		import std.format : format;

		if (delay <= Duration.zero) return buildNormalizedPath(baseDir, "queued", jobName);
		return buildNormalizedPath(baseDir, "scheduled", format("%0*d-%s", dueLength, nowMsecs + delay.total!"msecs", jobName));
	}

	// Moves the scheduled jobs whose delay expired to the queue
	private void promoteScheduled() const
	{
		auto entries = dirEntries(buildNormalizedPath(baseDir, "scheduled"), "*-{fle,raw}-*", SpanMode.shallow).array;
		entries.sort!((a, b) => a.baseName < b.baseName);

		long now = nowMsecs;

		foreach (entry; entries)
		{
			string name = entry.baseName;
			if (name.length <= duePrefixLength) continue;

			long due;
			try due = name[0..dueLength].to!long;
			catch (Exception e) continue;

			// Sorted by due time: nothing else is ready
			if (due > now) break;

			try moveFile(entry.name, buildNormalizedPath(baseDir, "queued", name[duePrefixLength..$]));
			catch (Exception e) {} // Promoted by someone else in the meanwhile
		}
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

		foreach (f; dirEntries(buildNormalizedPath(baseDir, directory), scheduled ? "*-{fle,raw}-*" : "{fle,raw}-*", SpanMode.shallow))
			if (f.baseName.length > skip && f.baseName[skip..$].startsWith(key))
				return f.name;

		return null;
	}

	private bool isInDirectory(string id, string directory) const => findJob(id, directory) !is null;

	private size_t countIn(string directory) const
	{
		return dirEntries(buildNormalizedPath(baseDir, directory), "{fle,raw}-*", SpanMode.shallow).walkLength;
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
		return dirEntries(buildNormalizedPath(baseDir, "scheduled"), "*-{fle,raw}-*", SpanMode.shallow).walkLength;
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

			try { moveFile(path, buildNormalizedPath(baseDir, "queued", path.baseName)); return true; }
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

			foreach (entry; dirEntries(buildNormalizedPath(baseDir, dir), "{fle,raw}-*", SpanMode.shallow).array)
			{
				try { moveFile(entry.name, buildNormalizedPath(baseDir, "queued", entry.baseName)); moved++; }
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

			foreach (entry; dirEntries(buildNormalizedPath(baseDir, dir), "{fle,raw}-*", SpanMode.shallow).array)
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
	bool receiveOne(bool randomize = true) const { return receiveImpl(randomize, 1) > 0; }

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
		auto processingDirs = dirEntries(buildNormalizedPath(baseDir, "processing"), SpanMode.shallow).array;
		int myPid = thisProcessID;

		foreach (dir; processingDirs)
		{
			if (!dir.isDir) continue;

			string dirName = dir.baseName;
			auto lastDot = dirName.lastIndexOf('.');

			// If it has no extension or invalid format, ignore it (or we could clean up, but better be cautious)
			if (lastDot == -1 || lastDot == dirName.length - 1) continue;

			string pidStr = dirName[lastDot + 1 .. $];

			try
			{
				int pid = pidStr.to!int;

				// Check if the process exists.
				bool isAlive = isProcessAlive(pid);

				// Our own PID: the job is alive only if this process is actually working on it.
				// Otherwise it was left by a previous process with the same PID (e.g. PID 1 in containers).
				if (pid == myPid)
				{
					activeJobsMutex.lock();
					scope(exit) activeJobsMutex.unlock();
					isAlive = (dirName in activeJobs) !is null;
				}

				if (!isAlive)
				{
					// The process is dead. Recover the file and move it to interrupted.
					// Inside dir there is the renamed file (original name) or "raw"

					// The original job ID is the part before the PID (e.g., fle-uuid-name)
					string originalIdFull = dirName[0 .. lastDot];

					if (keepPolicy & KeepPolicy.INTERRUPTED)
					{
						// Look for the file inside
						auto entries = dirEntries(dir, SpanMode.shallow);
						foreach(entry; entries)
						{
							// Move to interrupted using the original name (without PID)
							try
							{
								moveFile(entry.name, buildNormalizedPath(baseDir, "interrupted", originalIdFull));
							}
							catch (Exception e) {}
						}
					}

					// Remove the processing directory
					try { rmdirRecurse(dir); } catch (Exception e) {}
				}
			}
			catch (Exception e)
			{
				// If PID parsing fails or other error, ignore for now
				continue;
			}
		}
	}

	private size_t receiveImpl(bool randomize = true, size_t maxFiles = 0) const
	{
		// Before processing new files, check for orphan files and expired delays
		recoverStalledJobs();
		promoteScheduled();

		auto files = dirEntries(buildNormalizedPath(baseDir, "queued"), "{fle,raw}-*", SpanMode.shallow).array;

		// UUIDv7 ids are time ordered: sorting by id gives FIFO order
		if (randomize) files = randomShuffle(files).array;
		else files.sort!((a, b) => a.baseName[4..$] < b.baseName[4..$]);

		size_t processed = 0;
		int myPid = thisProcessID;

		foreach (file; files)
		{
			if (maxFiles > 0 && processed >= maxFiles)
				break;

			Result result = Result.FAILED;
			string id = file.baseName;
			bool isFile = id.startsWith("fle-");
			string name = "raw";

			if (isFile)
			{
				auto parts = id.split("-");

				// Malformed name, not a valid job
				if (parts.length < 7) continue;

				name = parts[6..$].join("-");
			}

			// Unique directory name with PID: id.PID
			string processingDirName = id ~ "." ~ myPid.to!string;
			string processingDirPath = buildNormalizedPath(baseDir, "processing", processingDirName);
			string path = buildNormalizedPath(processingDirPath, name);

			// Already processed by someone else
			if (!file.exists)
				continue;

			// Lock between threads of this process
			{
				activeJobsMutex.lock();
				scope(exit) activeJobsMutex.unlock();
				if (processingDirName in activeJobs) continue;
				activeJobs[processingDirName] = true;
			}

			scope(exit)
			{
				activeJobsMutex.lock();
				activeJobs.remove(processingDirName);
				activeJobsMutex.unlock();
			}

			// A lock on the directory is needed
			try { mkdir(processingDirPath); }
			catch (Exception e) { continue; }

			try { moveFile(file, path); }
			catch (Exception e) { try { rmdirRecurse(processingDirPath); } catch (Exception) {} continue; }

			processed++;

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

			try {
				if (result == Result.FAILED && (keepPolicy & KeepPolicy.FAILED)) moveFile(path, buildNormalizedPath(baseDir, "failed", id));
				else if (result == Result.SUCCESS && (keepPolicy & KeepPolicy.SUCCESS)) moveFile(path, buildNormalizedPath(baseDir, "success", id));
				else if (result == Result.RETRY) moveFile(path, enqueuePath(id, retryDelay));
			}
			catch (Exception e) { warning("Pacchettino rename error: ", e.msg); }

			try { rmdirRecurse(processingDirPath); }
			catch (Exception e) { warning("Pacchettino cleanup error: ", e.msg); }
		}

		return processed;
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
	 * How long to wait before processing again a job whose callback returned Result.RETRY.
	 * Zero (default) queues it again immediately.
	 */
	Duration retryDelay = Duration.zero;

	private string baseDir;
	private KeepPolicy keepPolicy;
}
