module tests;

import pacchettino;
import pacchettino.uuid;
import std;

unittest
{

	auto p = new Pacchettino(buildPath(tempDir, "test-pacchettino"));

   p.onDataReceived = (id, data) {
      assert(data == "Hello World");
      return Pacchettino.Result.SUCCESS;
   };

	auto id = p.sendData("Hello World");

   assert(p.isQueued(id));
   assert(!p.isProcessing(id));
   assert(!p.isFailed(id));
   assert(!p.isSuccess(id));

   p.receiveOne();

   assert(!p.isProcessing(id));
   assert(!p.isQueued(id));
   assert(!p.isFailed(id));
   assert(p.isSuccess(id));


   rmdirRecurse(buildPath(tempDir, "test-pacchettino"));
}

unittest
{

	auto p = new Pacchettino(buildPath(tempDir, "test-pacchettino"));

   std.file.write(buildPath(tempDir, "test-pacchettino-file"), "Hello World");

   p.onFileReceived = (id, name, path) {

      assert(name == "test-pacchettino-file");
      assert(std.file.readText(path) == "Hello World");
      return Pacchettino.Result.SUCCESS;
   };

	auto id = p.sendFile(buildPath(tempDir, "test-pacchettino-file"));

   assert(p.isQueued(id));
   assert(!p.isProcessing(id));
   assert(!p.isFailed(id));
   assert(!p.isSuccess(id));

   p.receiveOne();

   assert(!p.isProcessing(id));
   assert(!p.isQueued(id));
   assert(!p.isFailed(id));
   assert(p.isSuccess(id));


   rmdirRecurse(buildPath(tempDir, "test-pacchettino"));
   std.file.remove(buildPath(tempDir, "test-pacchettino-file"));
}

unittest
{
   auto p = new Pacchettino(buildPath(tempDir, "test-pacchettino-missing"));

   try {
      p.sendFile(buildPath(tempDir, "non-existent-file-12345"));
      assert(false, "Should have thrown Exception");
   } catch (Exception e) {
      assert(e.msg.startsWith("File not found"), "Unexpected error message: " ~ e.msg);
   }

   if (exists(buildPath(tempDir, "test-pacchettino-missing")))
      rmdirRecurse(buildPath(tempDir, "test-pacchettino-missing"));
}

unittest
{
    // Reproduction test for file retention
    string baseDir = buildPath(tempDir, "test-pacchettino-retention");
    if (exists(baseDir)) rmdirRecurse(baseDir);

    auto p = new Pacchettino(baseDir); // Defaults to KeepPolicy.ALL

    // Test Data Retention
    p.onDataReceived = (id, data) {
        return Pacchettino.Result.SUCCESS;
    };

    auto id1 = p.sendData("Test Data");
    p.receiveOne();

    // Check if file exists in success folder
    // The file name in success/ should be "raw-" ~ id1
    string successPath1 = buildNormalizedPath(baseDir, "success", "raw-" ~ id1);
    assert(exists(successPath1), "Success file for data not found: " ~ successPath1);


    // Test File Retention
    string testFile = buildNormalizedPath(baseDir, "testfile.txt");
    std.file.write(testFile, "File Content");

    p.onFileReceived = (id, name, path) {
        return Pacchettino.Result.SUCCESS;
    };

    auto id2 = p.sendFile(testFile);
    p.receiveOne();

    // Check if file exists in success folder
    // The file name in success/ should be "fle-" ~ id2 ~ "-testfile.txt"
    string successPath2 = buildNormalizedPath(baseDir, "success", "fle-" ~ id2 ~ "-testfile.txt");
    assert(exists(successPath2), "Success file for file not found: " ~ successPath2);

    // Test File Retention with Move
    string testFileMove = buildNormalizedPath(baseDir, "testfile_move.txt");
    std.file.write(testFileMove, "File Content Move");

    string userDest = buildNormalizedPath(baseDir, "user_dest.txt");

    p.onFileReceived = (id, name, path) {
        // User moves the file
        std.file.rename(path, userDest);
        return Pacchettino.Result.SUCCESS;
    };

    auto id3 = p.sendFile(testFileMove);
    p.receiveOne();

    // Check if file exists in user dest
    assert(exists(userDest), "User destination file not found");

    // Check if file exists in success folder
    string successPath3 = buildNormalizedPath(baseDir, "success", "fle-" ~ id3 ~ "-testfile_move.txt");

    // Since we removed the backup logic, the file will NOT be in the success folder if moved by user.
    // We expect a warning in the logs (verified manually or via log capture if possible, but here we just check logic)
    assert(!exists(successPath3), "File should not exist in success folder if moved by user");

    // We want to verify behavior first. If I assert true and it fails, I confirmed the issue.
    // assert(exists(successPath3));

    // Cleanup
    if (exists(baseDir)) rmdirRecurse(baseDir);
}

unittest
{
    // Test counter methods
    string baseDir = buildPath(tempDir, "test-pacchettino-counters");
    if (exists(baseDir)) rmdirRecurse(baseDir);

    auto p = new Pacchettino(baseDir);

    // Initially all counters should be 0
    assert(p.countQueued() == 0);
    assert(p.countProcessing() == 0);
    assert(p.countSuccessful() == 0);
    assert(p.countFailed() == 0);
    assert(p.countAll() == 0);

    // Add a job to queue
    auto id1 = p.sendData("Test Data 1");
    assert(p.countQueued() == 1);
    assert(p.countAll() == 1);

    // Add another job to queue
    auto id2 = p.sendData("Test Data 2");
    assert(p.countQueued() == 2);
    assert(p.countAll() == 2);

    // Process one job successfully
    p.onDataReceived = (id, data) {
        return Pacchettino.Result.SUCCESS;
    };
    p.receiveOne();

    // After processing one job successfully
    assert(p.countQueued() == 1);      // One still queued
    assert(p.countProcessing() == 0);  // None currently processing
    assert(p.countSuccessful() == 1);  // One successful
    assert(p.countAll() == 2);       // Total remains the same

    // Process the remaining job as failure
    p.onDataReceived = (id, data) {
        return Pacchettino.Result.FAILED;
    };
    p.receiveOne();

    // After processing second job as failure
    assert(p.countQueued() == 0);      // None queued
    assert(p.countProcessing() == 0);  // None currently processing
    assert(p.countSuccessful() == 1);  // One successful
    assert(p.countFailed() == 1);      // One failed
    assert(p.countAll() == 2);       // Total remains the same

    // Test with different keep policy
    string baseDir2 = buildPath(tempDir, "test-pacchettino-counters-policy");
    if (exists(baseDir2)) rmdirRecurse(baseDir2);

    auto p2 = new Pacchettino(baseDir2, Pacchettino.KeepPolicy.NONE);

    auto id3 = p2.sendData("Test Data 3");
    assert(p2.countQueued() == 1);
    assert(p2.countAll() == 1);

    // Process with NONE policy - should throw exceptions for status methods
    p2.onDataReceived = (id, data) {
        return Pacchettino.Result.SUCCESS;
    };
    p2.receiveOne();

    // After processing with NONE policy, job should be gone
    assert(p2.countQueued() == 0);
    assert(p2.countAll() == 0);

    // Trying to check success/failure status with NONE policy should throw
    try {
        p2.countSuccessful();
        assert(false, "Should have thrown Exception");
    } catch (Exception e) {
        // Expected
    }

    try {
        p2.countFailed();
        assert(false, "Should have thrown Exception");
    } catch (Exception e) {
        // Expected
    }

    // Cleanup
    if (exists(baseDir)) rmdirRecurse(baseDir);
    if (exists(baseDir2)) rmdirRecurse(baseDir2);
}

unittest
{
    // Stale jobs left by a previous process with our same PID (e.g. PID 1 in containers) are recovered
    string baseDir = buildPath(tempDir, "test-pacchettino-pid-reuse");
    if (exists(baseDir)) rmdirRecurse(baseDir);

    auto p = new Pacchettino(baseDir);

    string jobName = "raw-" ~ UUIDv7!string();
    string stale = buildNormalizedPath(baseDir, "processing", jobName ~ "." ~ thisProcessID.to!string);
    mkdir(stale);
    std.file.write(buildNormalizedPath(stale, "raw"), "Stale");

    p.receive();

    assert(!exists(stale));
    assert(p.countProcessing() == 0);
    assert(p.isInterrupted(jobName[4..$]));

    rmdirRecurse(baseDir);
}

unittest
{
    // receiveOne skips invalid entries and still processes one job; receive(false) is FIFO
    string baseDir = buildPath(tempDir, "test-pacchettino-fifo");
    if (exists(baseDir)) rmdirRecurse(baseDir);

    auto p = new Pacchettino(baseDir);

    // Malformed entry, sorted before any valid UUIDv7
    std.file.write(buildNormalizedPath(baseDir, "queued", "fle-0000"), "bad");

    string[] sent;
    foreach (i; 0 .. 20) sent ~= p.sendData(i.to!string);

    string[] received;
    p.onDataReceived = (id, data) { received ~= id[4..$]; return Pacchettino.Result.SUCCESS; };

    p.receiveOne(false);
    assert(received == sent[0..1]);

    p.receive(false);
    assert(received == sent);
    assert(p.countQueued() == 1); // Only the malformed entry is left

    rmdirRecurse(baseDir);
}

unittest
{
    // Data read errors are handled as failures instead of crashing receive()
    string baseDir = buildPath(tempDir, "test-pacchettino-bad-raw");
    if (exists(baseDir)) rmdirRecurse(baseDir);

    auto p = new Pacchettino(baseDir);

    // A directory instead of a file: it can be locked, but not read
    mkdir(buildNormalizedPath(baseDir, "queued", "raw-" ~ UUIDv7!string()));
    auto id = p.sendData("ok");

    bool called = false;
    p.onDataReceived = (i, data) { called = true; return Pacchettino.Result.SUCCESS; };
    p.receive(false);

    assert(called);
    assert(p.isSuccess(id));
    assert(p.countFailed() == 1);

    rmdirRecurse(baseDir);
}

// Test files with long names can exceed MAX_PATH on Windows
string longPath(string path)
{
    version(Windows) return `\\?\` ~ buildNormalizedPath(absolutePath(path));
    else return path;
}

unittest
{
    // File names too long are rejected upfront, without leaving temporary files
    string baseDir = buildPath(tempDir, "test-pacchettino-long-name");
    if (exists(baseDir)) rmdirRecurse(longPath(baseDir));

    auto p = new Pacchettino(baseDir);

    string longFile = buildNormalizedPath(baseDir, 'a'.repeat(210).array.to!string);
    std.file.write(longPath(longFile), "x");

    try {
        p.sendFile(longFile);
        assert(false, "Should have thrown Exception");
    } catch (Exception e) {
        assert(e.msg.startsWith("File name too long"), e.msg);
    }

    assert(p.countQueued() == 0);
    assert(dirEntries(buildNormalizedPath(baseDir, "tmp"), SpanMode.shallow).empty);

    // Just over the limit
    string overFile = buildNormalizedPath(baseDir, 'c'.repeat(201).array.to!string);
    std.file.write(longPath(overFile), "x");
    try { p.sendFile(overFile); assert(false, "Should have thrown Exception"); }
    catch (Exception e) { assert(e.msg.startsWith("File name too long"), e.msg); }

    // The longest allowed name is queued and processed, even when delayed
    string delayedFile = buildNormalizedPath(baseDir, 'd'.repeat(200).array.to!string);
    std.file.write(longPath(delayedFile), "x");
    auto delayedId = p.sendFile(delayedFile, true, 1.msecs);
    assert(p.isScheduled(delayedId));

    string okFile = buildNormalizedPath(baseDir, 'b'.repeat(200).array.to!string);
    std.file.write(longPath(okFile), "x");
    auto id = p.sendFile(okFile);

    p.onFileReceived = (i, name, path) => Pacchettino.Result.SUCCESS;
    p.receive();
    assert(p.isSuccess(id));

    rmdirRecurse(longPath(baseDir));
}

unittest
{
    // Moving a file from another filesystem falls back to copy + remove
    string baseDir = buildPath(tempDir, "test-pacchettino-xdev");
    string source = "/dev/shm/test-pacchettino-xdev-file";

    if (!exists("/dev/shm")) return;
    if (exists(baseDir)) rmdirRecurse(baseDir);

    auto p = new Pacchettino(baseDir);
    std.file.write(source, "cross device");

    auto id = p.sendFile(source, false);
    assert(!exists(source));
    assert(p.isQueued(id));

    rmdirRecurse(baseDir);
}

unittest
{
    // cleanup removes kept jobs
    string baseDir = buildPath(tempDir, "test-pacchettino-cleanup");
    if (exists(baseDir)) rmdirRecurse(baseDir);

    auto p = new Pacchettino(baseDir);

    p.sendData("a");
    p.sendData("b");
    p.onDataReceived = (id, data) => data == "a" ? Pacchettino.Result.SUCCESS : Pacchettino.Result.FAILED;
    p.receive();

    assert(p.countSuccessful() == 1 && p.countFailed() == 1);

    // Nothing is old enough
    assert(p.cleanup(Pacchettino.KeepPolicy.ALL, 1.hours) == 0);

    assert(p.cleanup(Pacchettino.KeepPolicy.SUCCESS) == 1);
    assert(p.countSuccessful() == 0 && p.countFailed() == 1);

    assert(p.cleanup() == 1);
    assert(p.countAll() == 0);

    // Empty id never matches
    p.sendData("c");
    assert(!p.isQueued(""));

    rmdirRecurse(baseDir);
}

unittest
{
    // UUIDv7 must be strictly monotonic, even beyond 4096 ids per millisecond
    import pacchettino.uuid;

    string prev = UUIDv7!string();
    foreach (i; 0 .. 20_000)
    {
        auto cur = UUIDv7!string();
        assert(cur > prev, prev ~ " >= " ~ cur);
        assert(cur[14] == '7');
        prev = cur;
    }

    // Known v5/v3 values (RFC 4122 DNS namespace)
    assert(UUIDv5("www.example.com", UUIDNamespace.DNS) == "2ed6657d-e927-568b-95e1-2665a8aea6a2");
    assert(UUIDv3("www.example.com", UUIDNamespace.DNS) == "5df41881-3aed-3515-88a7-2f4a814cf09e");
}

unittest
{
    // status, sentAt and requeue
    string baseDir = buildPath(tempDir, "test-pacchettino-status");
    if (exists(baseDir)) rmdirRecurse(baseDir);

    auto p = new Pacchettino(baseDir);
    auto before = Clock.currTime;
    auto id = p.sendData("fail me");
    auto after = Clock.currTime;

    assert(p.status(id) == Pacchettino.Status.QUEUED);
    assert(p.status(UUIDv7!string()) == Pacchettino.Status.UNKNOWN);
    assert(p.status("") == Pacchettino.Status.UNKNOWN);

    auto sent = Pacchettino.sentAt(id);
    assert(sent >= before - 1.msecs && sent <= after + 1.msecs);

    string callbackId;
    Pacchettino.Status inCallback;
    p.onDataReceived = (i, data) {
        callbackId = i;
        inCallback = p.status(i);
        return Pacchettino.Result.FAILED;
    };

    assert(p.receiveOne());
    assert(!p.receiveOne());
    assert(inCallback == Pacchettino.Status.PROCESSING);
    assert(p.status(id) == Pacchettino.Status.FAILED);

    // The id passed to callbacks works too
    assert(p.status(callbackId) == Pacchettino.Status.FAILED);
    assert(Pacchettino.sentAt(callbackId) == sent);

    assert(p.requeue(callbackId));
    assert(!p.requeue(callbackId));
    assert(p.status(id) == Pacchettino.Status.QUEUED);

    p.onDataReceived = (i, data) => Pacchettino.Result.SUCCESS;
    assert(p.receive() == 1);
    assert(p.status(id) == Pacchettino.Status.SUCCESS);

    // Status never throws, even when the policy does not keep jobs
    auto p2 = new Pacchettino(baseDir, Pacchettino.KeepPolicy.NONE);
    assert(p2.status(id) == Pacchettino.Status.SUCCESS);

    try {
        Pacchettino.sentAt("not-an-id");
        assert(false, "Should have thrown Exception");
    } catch (Exception e) {}

    rmdirRecurse(baseDir);
}

unittest
{
    // requeueAll
    string baseDir = buildPath(tempDir, "test-pacchettino-requeue-all");
    if (exists(baseDir)) rmdirRecurse(baseDir);

    auto p = new Pacchettino(baseDir);

    std.file.write(buildNormalizedPath(baseDir, "doc.txt"), "x");
    p.sendFile(buildNormalizedPath(baseDir, "doc.txt"));
    p.sendData("a");
    p.sendData("b");

    p.onDataReceived = (i, data) => data == "a" ? Pacchettino.Result.SUCCESS : Pacchettino.Result.FAILED;
    p.onFileReceived = (i, name, path) => Pacchettino.Result.FAILED;
    assert(p.receive() == 3);

    assert(p.requeueAll() == 2);
    assert(p.countQueued() == 2 && p.countFailed() == 0 && p.countSuccessful() == 1);

    // The requeued file job keeps its original name
    string name;
    p.onFileReceived = (i, n, path) { name = n; return Pacchettino.Result.SUCCESS; };
    p.onDataReceived = (i, data) => Pacchettino.Result.SUCCESS;
    assert(p.receive() == 2);
    assert(name == "doc.txt");

    assert(p.requeueAll(Pacchettino.KeepPolicy.SUCCESS) == 3);
    assert(p.countQueued() == 3);

    rmdirRecurse(baseDir);
}

unittest
{
    // receiveOne with timeout
    import core.thread : Thread;
    string baseDir = buildPath(tempDir, "test-pacchettino-wait");
    if (exists(baseDir)) rmdirRecurse(baseDir);

    auto p = new Pacchettino(baseDir);
    p.onDataReceived = (i, data) => Pacchettino.Result.SUCCESS;

    // Empty queue: waits for the timeout
    auto start = MonoTime.currTime;
    assert(!p.receiveOne(200.msecs));
    auto elapsed = MonoTime.currTime - start;
    assert(elapsed >= 200.msecs && elapsed < 1.seconds);

    // A job sent while waiting is picked up
    auto t = new Thread({ Thread.sleep(150.msecs); new Pacchettino(baseDir).sendData("late"); }).start();
    start = MonoTime.currTime;
    assert(p.receiveOne(5.seconds, true, 20.msecs));
    assert(MonoTime.currTime - start < 1.seconds);
    t.join();

    rmdirRecurse(baseDir);
}

unittest
{
    // Delayed jobs
    import core.thread : Thread;

    string baseDir = buildPath(tempDir, "test-pacchettino-delay");
    if (exists(baseDir)) rmdirRecurse(baseDir);

    auto p = new Pacchettino(baseDir);
    p.onDataReceived = (i, data) => Pacchettino.Result.SUCCESS;

    auto late = p.sendData("late", 400.msecs);
    auto soon = p.sendData("soon", 150.msecs);
    auto now = p.sendData("now");

    assert(p.status(late) == Pacchettino.Status.SCHEDULED);
    assert(p.isScheduled(soon));
    assert(p.countScheduled() == 2);
    assert(p.countAll() == 3);

    // Only the job without delay is ready
    assert(p.receive() == 1);
    assert(p.isSuccess(now));

    // The shortest delay expires first
    assert(p.receiveOne(2.seconds, true, 20.msecs));
    assert(p.isSuccess(soon) && p.isScheduled(late));

    Thread.sleep(300.msecs);
    assert(p.receive() == 1);
    assert(p.isSuccess(late));
    assert(p.countScheduled() == 0);

    // Delayed files keep their name
    std.file.write(buildNormalizedPath(baseDir, "doc.txt"), "x");
    auto fileId = p.sendFile(buildNormalizedPath(baseDir, "doc.txt"), true, 50.msecs);
    assert(p.status(fileId) == Pacchettino.Status.SCHEDULED);

    string name;
    p.onFileReceived = (i, n, path) { name = n; return Pacchettino.Result.SUCCESS; };
    assert(p.receiveOne(2.seconds, true, 20.msecs));
    assert(name == "doc.txt");

    rmdirRecurse(baseDir);
}

unittest
{
    // retryDelay
    import core.thread : Thread;

    string baseDir = buildPath(tempDir, "test-pacchettino-retry-delay");
    if (exists(baseDir)) rmdirRecurse(baseDir);

    auto p = new Pacchettino(baseDir);
    p.retryDelay = 200.msecs;

    int attempts = 0;
    p.onDataReceived = (i, data) => ++attempts < 2 ? Pacchettino.Result.RETRY : Pacchettino.Result.SUCCESS;

    auto id = p.sendData("retry me");
    assert(p.receive() == 1);
    assert(p.status(id) == Pacchettino.Status.SCHEDULED);

    // Not ready yet
    assert(!p.receiveOne());

    assert(p.receiveOne(2.seconds, true, 20.msecs));
    assert(attempts == 2);
    assert(p.status(id) == Pacchettino.Status.SUCCESS);

    // Without delay, RETRY queues the job again immediately
    p.retryDelay = Duration.zero;
    attempts = 0;
    id = p.sendData("retry me again");
    assert(p.receive() == 1);
    assert(p.status(id) == Pacchettino.Status.QUEUED);

    rmdirRecurse(baseDir);
}

version(Windows) unittest
{
    // Paths beyond MAX_PATH work; callbacks get the \\?\ prefix only when needed
    string root = buildPath(tempDir, "test-pacchettino-longpath");
    if (exists(root)) rmdirRecurse(root);

    string shortBase = buildPath(root, "short");
    string longBase = buildPath(root, 'x'.repeat(120).array.to!string, 'y'.repeat(120).array.to!string);

    foreach (base; [shortBase, longBase])
    {
        auto p = new Pacchettino(base);

        string file = buildPath(root, base == shortBase ? "doc.txt" : 'n'.repeat(150).array.to!string ~ ".txt");
        if (!exists(root)) mkdirRecurse(root);
        std.file.write(file, "long");
        auto id = p.sendFile(file);

        string got;
        p.onFileReceived = (i, name, path) { got = path; assert(readText(path) == "long"); return Pacchettino.Result.SUCCESS; };
        assert(p.receive() == 1);
        assert(p.isSuccess(id));

        if (base == shortBase) assert(!got.startsWith(`\\?\`), got);
        else assert(got.startsWith(`\\?\`), got);
    }

    rmdirRecurse(`\\?\` ~ absolutePath(root));
}
