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
import core.sys.posix.signal : kill;
import core.stdc.errno : errno, EPERM, EXDEV;

import std.file, std.path;

// Processing directories currently in use by this process (shared across threads and instances).
// Used to tell apart our own active jobs from stale ones left by a previous process with the same PID.
private __gshared bool[string] activeJobs;
private __gshared Mutex activeJobsMutex;

shared static this() { activeJobsMutex = new Mutex(); }

// Max length of a file name. The processing dir name is "fle-<uuid>-<name>.<pid>".
private enum maxNameLength = 255;
private enum maxFileNameLength = maxNameLength - "fle-".length - 36 - "-".length - ".".length - int.max.stringof.length;

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
		INTERRUPTED  /// Job was interrupted by a crashed process
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
	}

	/**
	 * Sends a string to the queue.
	 *
	 * Params:
	 *   s = The string to send.
	 *
	 * Returns:
	 *   The ID of the queued job.
	 */
	string sendData(string s) const { return sendData(s.representation); }

	/**
	 * Sends raw bytes to the queue.
	 *
	 * Params:
	 *   s = The bytes to send.
	 *
	 * Returns:
	 *   The ID of the queued job.
	 */
	string sendData(const ubyte[] s) const
	{
		auto id = UUIDv7!string();
		auto tmp = buildNormalizedPath(baseDir, "tmp", id);
		auto path = buildNormalizedPath(baseDir,"queued", "raw-" ~ id);

		try
		{
			std.file.write(tmp, s);
			std.file.rename(tmp, path);
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
	 *
	 * Returns:
	 *   The ID of the queued job.
	 *
	 * Throws:
	 *   Exception if the file does not exist or its name is too long to be queued.
	 */
	string sendFile(const string filePath, bool copyFile = true) const
	{
		if (!exists(filePath))
			throw new Exception("File not found: " ~ filePath);

		if (filePath.baseName.length > maxFileNameLength)
			throw new Exception("File name too long (max " ~ maxFileNameLength.to!string ~ " bytes): " ~ filePath.baseName);

		auto id = UUIDv7!string();
		auto tmp = buildNormalizedPath(baseDir, "tmp", id);
		auto path = buildNormalizedPath(baseDir, "queued", "fle-" ~ id ~ "-" ~ filePath.baseName);

		if (copyFile)
			std.file.copy(filePath, tmp);
		else
		{
			try std.file.rename(filePath, tmp);
			catch (FileException e)
			{
				// Different filesystems: fall back to copy + remove
				if (e.errno != EXDEV) throw e;
				std.file.copy(filePath, tmp);
				std.file.remove(filePath);
			}
		}

		try std.file.rename(tmp, path);
		catch (Exception e)
		{
			if (tmp.exists) try { std.file.remove(tmp); } catch (Exception) {}
			throw e;
		}

		return id;
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

		foreach (f; dirEntries(buildNormalizedPath(baseDir, directory), "{fle,raw}-*", SpanMode.shallow))
			if (f.baseName.length > 4 && f.baseName[4..$].startsWith(key))
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
	 * Counts the total number of jobs in all states (based on current keep policy).
	 *
	 * Returns:
	 *   The total number of jobs across all applicable directories.
	 */
	size_t countAll() const
	{
		size_t total = countQueued() + countProcessing();

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

			try { rename(path, buildNormalizedPath(baseDir, "queued", path.baseName)); return true; }
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
				try { rename(entry.name, buildNormalizedPath(baseDir, "queued", entry.baseName)); moved++; }
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
				// kill(pid, 0) returns 0 if it exists, -1 on error.
				// If errno is ESRCH, the process does not exist. EPERM means it exists but is not ours.
				bool isAlive = (kill(pid, 0) == 0) || (errno == EPERM);

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
								rename(entry.name, buildNormalizedPath(baseDir, "interrupted", originalIdFull));
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
		// Before processing new files, check for orphan files
		recoverStalledJobs();

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

			try { rename(file, path); }
			catch (Exception e) { try { rmdirRecurse(processingDirPath); } catch (Exception) {} continue; }

			processed++;

			if (isFile)
			{
				try {	result = onFileReceived(id, name, path); }
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
				if (result == Result.FAILED && (keepPolicy & KeepPolicy.FAILED)) rename(path, buildNormalizedPath(baseDir, "failed", id));
				else if (result == Result.SUCCESS && (keepPolicy & KeepPolicy.SUCCESS)) rename(path, buildNormalizedPath(baseDir, "success", id));
				else if (result == Result.RETRY) rename(path, buildNormalizedPath(baseDir, "queued", id));
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
	 * Params:
	 *   id = The job ID.
	 *   name = The name of the file.
	 *   path = The path to the file on disk.
	 *
	 * Returns:
	 *   The result of the processing.
	 */
	Result delegate(string id, string name, string path) onFileReceived;

	/**
	 * Callback triggered when data is received.
	 *
	 * Params:
	 *   id = The job ID.
	 *   data = The received data.
	 *
	 * Returns:
	 *   The result of the processing.
	 */
	Result delegate(string id, ubyte[] data) onDataReceived;

	private string baseDir;
	private KeepPolicy keepPolicy;
}
