/+ dub.sdl:
	name "bench"
	dependency "pacchettino" path=".."
+/

// Throughput of sendData and receive.
// Usage: dub run --single -b release --compiler=ldc2 tests/bench.d -- [--dir=DIR] [--jobs=N] [--consumers=N] [--loop] [--durable] [--lock]
//   --consumers  number of consumer processes (1 = the benchmark itself)
//   --loop       with one consumer, call receiveOne in a loop instead of receive

import core.time, pacchettino, std;

void main(string[] args)
{
	string dir = buildPath(tempDir, "pacchettino-bench");
	size_t jobs = 20_000;
	size_t consumers = 1;
	bool durable, lock, loop;
	string role;

	getopt(args, "dir", &dir, "jobs", &jobs, "consumers", &consumers, "durable", &durable, "lock", &lock, "loop", &loop, "role", &role);

	Pacchettino open()
	{
		auto queue = new Pacchettino(buildPath(dir, "q"), Pacchettino.KeepPolicy.ALL);
		queue.durable = durable;
		if (lock) queue.crashDetection = Pacchettino.CrashDetection.LOCK_FILE;
		queue.onDataReceived = (string id, ubyte[] data) => Pacchettino.Result.SUCCESS;
		return queue;
	}

	// A consumer process: works until the queue is empty
	if (role == "consumer")
	{
		auto queue = open();
		while (queue.receiveOne(200.msecs)) {}
		return;
	}

	if (exists(dir)) rmdirRecurse(dir);
	mkdirRecurse(dir);

	auto queue = open();
	auto payload = new ubyte[256];

	auto t0 = MonoTime.currTime;
	foreach (i; 0 .. jobs) queue.sendData(payload);
	auto t1 = MonoTime.currTime;

	if (consumers == 1 && loop) while (queue.receiveOne()) {}
	else if (consumers == 1) queue.receive(false);
	else
	{
		string[] self = [thisExePath, "--dir=" ~ dir, "--role=consumer"] ~ (durable ? ["--durable"] : []) ~ (lock ? ["--lock"] : []);
		Pid[] pids;
		foreach (k; 0 .. consumers) pids ~= spawnProcess(self);
		foreach (p; pids) wait(p);
	}
	auto t2 = MonoTime.currTime;

	enforce(queue.countSuccessful == jobs, "not every job was processed");

	double rate(Duration d) { return jobs / (d.total!"usecs" / 1e6); }
	writefln("%-8s %-8s %2s consumer%s %-11s  send %7.0f job/s   receive %7.0f job/s",
		durable ? "durable" : "-", lock ? "lock" : "pid", consumers, consumers > 1 ? "s" : " ", consumers > 1 || loop ? "receiveOne" : "receive", rate(t1 - t0), rate(t2 - t1));

	rmdirRecurse(dir);
}
