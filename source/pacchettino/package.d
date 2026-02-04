module pacchettino;

import pacchettino.uuid;

import std.random 	: randomShuffle;
import std.string 	: representation, split, join;
import std.conv 		: to;
import std.array 		: array;
import std.algorithm : min, startsWith, canFind;

import std.file, std.path;

class Pacchettino
{
	enum Result
	{
		SUCCESS,
		FAILED,
		RETRY
	}

	enum KeepPolicy
	{
		ALL,
		FAILED_ONLY,
		SUCCESS_ONLY,
		NONE
	}

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
	}

	string sendData(string s) const { return sendData(s.representation); }

	string sendData(const ubyte[] s) const
	{
		auto id = UUIDv7!string();
		auto tmp = buildNormalizedPath(baseDir, "tmp", id);
		auto path = buildNormalizedPath(baseDir,"queued", "raw-" ~ id);
		std.file.write(tmp, s);
		std.file.rename(tmp, path);
		return id;
	}

	string sendFile(const string filePath, bool copyFile = true) const
	{
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

	bool isProcessing(string id) const => isInDirectory(id, "processing");
	bool isQueued(string id) const => isInDirectory(id, "queued");

	bool isFailed(string id) const {
		if (keepPolicy == KeepPolicy.SUCCESS_ONLY || keepPolicy == KeepPolicy.NONE) throw new Exception("isFailed is not supported with success only or none policy");
		return isInDirectory(id, "failed");
	}

	bool isSuccess(string id) const {
		if (keepPolicy == KeepPolicy.FAILED_ONLY || keepPolicy == KeepPolicy.NONE) throw new Exception("isSuccess is not supported with failed only or none policy");
		return isInDirectory(id, "success");
	}

	void receive(bool randomize = true) const { receiveImpl(randomize, 0); }
	void receiveOne(bool randomize = true) const { receiveImpl(randomize, 1); }

	private void receiveImpl(bool randomize = true, size_t maxFiles = 0) const
	{

		auto files = dirEntries(buildNormalizedPath(baseDir, "queued"), "{fle,raw}-*", SpanMode.shallow).array;

		if (randomize)
			files = randomShuffle(files).array;

		if (maxFiles > 0)
			files = files[0..min(maxFiles, files.length)];

		size_t i = 0;
		foreach (file; files)
		{
			Result result = Result.FAILED;
			string id = file.baseName;
			string path;

			// Already processed by someone else
			if (!file.exists)
				continue;

			if (file.baseName.startsWith("fle-"))
			{
				auto name = file.baseName.split("-")[6..$].join("-");
				path = buildNormalizedPath(baseDir, "processing", id, name);

				// A lock on the directory is needed
				try { mkdir(buildNormalizedPath(baseDir, "processing", id)); }
				catch (Exception e) { continue; }

				try { rename(file, path); }
				catch (Exception e) { rmdirRecurse(buildNormalizedPath(baseDir, "processing", id)); continue; }

				try {	result = onFileReceived(id, name, path); }
				catch (Exception e) { result = Result.FAILED; }

			}

			else if (file.baseName.startsWith("raw-"))
			{
				auto data = cast(ubyte[])file.read();
				path = buildNormalizedPath(baseDir, "processing", id, "raw");

				// A lock on the directory is needed
				try {	mkdir(buildNormalizedPath(baseDir, "processing", id)); }
				catch (Exception e) { continue; }

				try { std.file.rename(file, path); }
				catch (Exception e) { rmdirRecurse(buildNormalizedPath(baseDir, "processing", id)); continue; }

				try {	result = onDataReceived(id, data); }
				catch (Exception e) { result = Result.FAILED; }
			}

			else continue;

			try {
				if (result == Result.FAILED && (keepPolicy == KeepPolicy.ALL || keepPolicy == KeepPolicy.FAILED_ONLY)) rename(path, buildNormalizedPath(baseDir, "failed", id));
				else if (result == Result.SUCCESS && (keepPolicy == KeepPolicy.ALL || keepPolicy == KeepPolicy.SUCCESS_ONLY)) rename(path, buildNormalizedPath(baseDir, "success", id));
				else if (result == Result.RETRY) rename(path, buildNormalizedPath(baseDir, "queued", id));
			}
			catch (Exception e) { }

			rmdirRecurse(buildNormalizedPath(baseDir, "processing", id));
		}
	}

	Result delegate(string id, string name, string path) onFileReceived;
	Result delegate(string id, ubyte[] data) onDataReceived;

	private string baseDir;
	private KeepPolicy keepPolicy;
}

