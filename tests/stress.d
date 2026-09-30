/+ dub.sdl:
	name "stress"
	dependency "pacchettino" path=".."
+/

// Many processes and threads on the same queue, and a consumer killed while processing a job.
// Usage: dub run --single tests/stress.d [-- --lock] [-- --lock --spawn="unshare ..."]
//   --lock    consumers use CrashDetection.LOCK_FILE
//   --spawn   command prefix for the consumer processes, e.g. to put each one in its own PID
//             namespace like a container: --spawn="unshare --user --map-root-user --pid --fork --kill-child"

import core.sync.mutex, core.thread, pacchettino, std;

enum jobs = 2000;
enum processes = 4;
enum threads = 4;

bool lock;

Pacchettino open(string base)
{
	auto queue = new Pacchettino(buildPath(base, "q"));
	if (lock) queue.crashDetection = Pacchettino.CrashDetection.LOCK_FILE;
	return queue;
}

void main(string[] args)
{
	string base = buildPath(tempDir, "pacchettino-stress");
	string spawn;
	getopt(args, "lock", &lock, "spawn", &spawn);

	string[] child(string what) { return spawn.split ~ [thisExePath, what] ~ (lock ? ["--lock"] : []); }

	if (args.length > 1 && args[1] == "worker") return worker(base);
	if (args.length > 1 && args[1] == "slow") return slow(base);

	if (exists(base)) rmdirRecurse(base);
	mkdirRecurse(base);

	// Every job processed exactly once by one of many processes and threads
	auto queue = open(base);
	foreach (i; 0 .. jobs) queue.sendData(i.to!string);

	Pid[] pids;
	foreach (k; 0 .. processes) pids ~= spawnProcess(child("worker"));
	foreach (p; pids) enforce(wait(p) == 0, "worker failed");

	string[] done;
	foreach (log; dirEntries(base, "log-*", SpanMode.shallow)) done ~= readText(log).splitLines;

	enforce(done.length == jobs, format("%s jobs processed, %s expected", done.length, jobs));
	enforce(done.sort.uniq.walkLength == jobs, "some jobs were processed twice");
	enforce(queue.countQueued == 0 && queue.countProcessing == 0 && queue.countSuccessful == jobs);
	writeln("ok: ", jobs, " jobs, ", processes, " processes x ", threads, " threads", lock ? ", lock files" : "", spawn.length ? ", spawned with " ~ spawn : "");

	// A consumer killed while processing: the job is recovered as interrupted
	auto id = queue.sendData("slow");
	auto slowPid = spawnProcess(child("slow"));

	auto limit = MonoTime.currTime + 30.seconds;
	while (!queue.isProcessing(id))
	{
		enforce(MonoTime.currTime < limit, "the slow job was never taken");
		Thread.sleep(20.msecs);
	}

	// A real crash: SIGKILL cannot be caught (unshare ignores SIGTERM, too)
	version(Posix) { import core.sys.posix.signal : SIGKILL; kill(slowPid, SIGKILL); }
	else kill(slowPid);
	wait(slowPid);

	// The process may take a moment to go away completely (its children, in a PID namespace)
	limit = MonoTime.currTime + 10.seconds;
	while (true)
	{
		queue.receive();
		if (queue.status(id) == Pacchettino.Status.INTERRUPTED || MonoTime.currTime > limit) break;
		Thread.sleep(50.msecs);
	}

	enforce(queue.status(id) == Pacchettino.Status.INTERRUPTED, format("status %s after the crash", queue.status(id)));
	enforce(queue.countProcessing == 0);
	enforce(queue.requeueAll(Pacchettino.KeepPolicy.INTERRUPTED) == 1 && queue.isQueued(id));
	writeln("ok: crashed job recovered");

	rmdirRecurse(base);
}

void worker(string base)
{
	// Not the PID: in PID namespaces every worker can be PID 1
	import pacchettino.uuid : UUIDv4;
	auto log = File(buildPath(base, "log-" ~ UUIDv4()), "w");
	auto mutex = new Mutex;

	auto queue = open(base);
	queue.onDataReceived = (string id, ubyte[] data) {
		synchronized (mutex) log.writeln(cast(string) data);
		return Pacchettino.Result.SUCCESS;
	};

	Thread[] ts;
	foreach (t; 0 .. threads)
		ts ~= new Thread({ while (queue.receiveOne(500.msecs)) {} }).start();

	foreach (t; ts) t.join();
}

void slow(string base)
{
	auto queue = open(base);
	queue.onDataReceived = (string id, ubyte[] data) {
		Thread.sleep(1.minutes);
		return Pacchettino.Result.SUCCESS;
	};
	queue.receiveOne(false);
}
