/+ dub.sdl:
	name "stress"
	dependency "pacchettino" path=".."
+/

// Many processes and threads on the same queue, and a consumer killed while processing a job.
// Usage: dub run --single tests/stress.d

import core.sync.mutex, core.thread, pacchettino, std;

enum jobs = 2000;
enum processes = 4;
enum threads = 4;

void main(string[] args)
{
	string base = buildPath(tempDir, "pacchettino-stress");

	if (args.length > 1 && args[1] == "worker") return worker(base);
	if (args.length > 1 && args[1] == "slow") return slow(base);

	if (exists(base)) rmdirRecurse(base);
	mkdirRecurse(base);

	// Every job processed exactly once by one of many processes and threads
	auto queue = new Pacchettino(buildPath(base, "q"));
	foreach (i; 0 .. jobs) queue.sendData(i.to!string);

	Pid[] pids;
	foreach (k; 0 .. processes) pids ~= spawnProcess([thisExePath, "worker"]);
	foreach (p; pids) enforce(wait(p) == 0, "worker failed");

	string[] done;
	foreach (log; dirEntries(base, "log-*", SpanMode.shallow)) done ~= readText(log).splitLines;

	enforce(done.length == jobs, format("%s jobs processed, %s expected", done.length, jobs));
	enforce(done.sort.uniq.walkLength == jobs, "some jobs were processed twice");
	enforce(queue.countQueued == 0 && queue.countProcessing == 0 && queue.countSuccessful == jobs);
	writeln("ok: ", jobs, " jobs, ", processes, " processes x ", threads, " threads");

	// A consumer killed while processing: the job is recovered as interrupted
	auto id = queue.sendData("slow");
	auto slowPid = spawnProcess([thisExePath, "slow"]);

	auto limit = MonoTime.currTime + 30.seconds;
	while (!queue.isProcessing(id))
	{
		enforce(MonoTime.currTime < limit, "the slow job was never taken");
		Thread.sleep(20.msecs);
	}

	kill(slowPid);
	wait(slowPid);

	queue.receive();
	enforce(queue.status(id) == Pacchettino.Status.INTERRUPTED, format("status %s after the crash", queue.status(id)));
	enforce(queue.countProcessing == 0);
	enforce(queue.requeueAll(Pacchettino.KeepPolicy.INTERRUPTED) == 1 && queue.isQueued(id));
	writeln("ok: crashed job recovered");

	rmdirRecurse(base);
}

void worker(string base)
{
	auto log = File(buildPath(base, "log-" ~ thisProcessID.to!string), "w");
	auto mutex = new Mutex;

	auto queue = new Pacchettino(buildPath(base, "q"));
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
	auto queue = new Pacchettino(buildPath(base, "q"));
	queue.onDataReceived = (string id, ubyte[] data) {
		Thread.sleep(1.minutes);
		return Pacchettino.Result.SUCCESS;
	};
	queue.receiveOne(false);
}
