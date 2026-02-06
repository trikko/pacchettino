module pacchettino;

import pacchettino.uuid;

import std.random 	: randomShuffle;
import std.string 	: representation, split, join, lastIndexOf;
import std.conv 		: to;
import std.array 		: array;
import std.algorithm : min, startsWith, canFind;
import std.process  : thisProcessID;
import core.sys.posix.signal : kill;
import core.stdc.errno : errno, EPERM, ESRCH;

import std.file, std.path;

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
		std.file.write(tmp, s);
		std.file.rename(tmp, path);
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
	 */
	string sendFile(const string filePath, bool copyFile = true) const
	{
		if (!exists(filePath))
			throw new Exception("File not found: " ~ filePath);

		auto id = UUIDv7!string();
		auto tmp = buildNormalizedPath(baseDir, "tmp", id);
		auto path = buildNormalizedPath(baseDir, "queued", "fle-" ~ id ~ "-" ~ filePath.baseName);

		if (copyFile)
			std.file.copy(filePath, tmp);
		else
			std.file.rename(filePath, tmp);

		std.file.rename(tmp, path);
		return id;
	}

	private bool isInDirectory(string id, string directory) const => dirEntries(buildNormalizedPath(baseDir, directory), SpanMode.shallow).canFind!(f => f.baseName.length > 4 && (f.baseName.startsWith("fle-") || f.baseName.startsWith("raw-")) && f.baseName[4..$].startsWith(id));

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
	 * Processes all available jobs in the queue.
	 *
	 * Params:
	 *   randomize = Whether to process jobs in random order.
	 */
	void receive(bool randomize = true) const { receiveImpl(randomize, 0); }

	/**
	 * Processes a single job from the queue.
	 *
	 * Params:
	 *   randomize = Whether to select a job randomly.
	 */
	void receiveOne(bool randomize = true) const { receiveImpl(randomize, 1); }

	/**
	 * Checks for stalled jobs in the processing folder belonging to no longer existing processes.
	 * If the associated process (PID in the name) does not exist, the job is marked as interrupted.
	 */
	private void recoverStalledJobs() const
	{
		auto processingDirs = dirEntries(buildNormalizedPath(baseDir, "processing"), SpanMode.shallow).array;

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

	private void receiveImpl(bool randomize = true, size_t maxFiles = 0) const
	{
		// Before processing new files, check for orphan files
		recoverStalledJobs();

		auto files = dirEntries(buildNormalizedPath(baseDir, "queued"), "{fle,raw}-*", SpanMode.shallow).array;

		if (randomize)
			files = randomShuffle(files).array;

		if (maxFiles > 0)
			files = files[0..min(maxFiles, files.length)];

		size_t i = 0;
		int myPid = thisProcessID;

		foreach (file; files)
		{
			Result result = Result.FAILED;
			string id = file.baseName;
			string path;

			// Unique directory name with PID: id.PID
			string processingDirName = id ~ "." ~ myPid.to!string;
			string processingDirPath = buildNormalizedPath(baseDir, "processing", processingDirName);

			// Already processed by someone else
			if (!file.exists)
				continue;

			if (file.baseName.startsWith("fle-"))
			{
				auto name = file.baseName.split("-")[6..$].join("-");
				path = buildNormalizedPath(processingDirPath, name);

				// A lock on the directory is needed
				try { mkdir(processingDirPath); }
				catch (Exception e) { continue; }

				try { rename(file, path); }
				catch (Exception e) { rmdirRecurse(processingDirPath); continue; }

				string backupPath = path ~ ".bak";
				if (keepPolicy != KeepPolicy.NONE)
				{
					try { std.file.copy(path, backupPath); }
					catch (Exception e) {}
				}

				try {	result = onFileReceived(id, name, path); }
				catch (Exception e) { result = Result.FAILED; }

				if (!path.exists && backupPath.exists)
					path = backupPath;

			}

			else if (file.baseName.startsWith("raw-"))
			{
				auto data = cast(ubyte[])file.read();
				path = buildNormalizedPath(processingDirPath, "raw");

				// A lock on the directory is needed
				try {	mkdir(processingDirPath); }
				catch (Exception e) { continue; }

				try { std.file.rename(file, path); }
				catch (Exception e) { rmdirRecurse(processingDirPath); continue; }

				try {	result = onDataReceived(id, data); }
				catch (Exception e) { result = Result.FAILED; }
			}

			else continue;

			try {
				if (result == Result.FAILED && (keepPolicy & KeepPolicy.FAILED)) rename(path, buildNormalizedPath(baseDir, "failed", id));
				else if (result == Result.SUCCESS && (keepPolicy & KeepPolicy.SUCCESS)) rename(path, buildNormalizedPath(baseDir, "success", id));
				else if (result == Result.RETRY) rename(path, buildNormalizedPath(baseDir, "queued", id));
			}
			catch (Exception e) { }

			rmdirRecurse(processingDirPath);
		}
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
