module tests;

import pacchettino;
import std;

unittest
{

	auto p = new Pacchettino("/tmp/test-pacchettino");

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


   rmdirRecurse("/tmp/test-pacchettino");
}

unittest
{

	auto p = new Pacchettino("/tmp/test-pacchettino");

   std.file.write("/tmp/test-pacchettino-file", "Hello World");

   p.onFileReceived = (id, name, path) {

      assert(name == "test-pacchettino-file");
      assert(std.file.readText(path) == "Hello World");
      return Pacchettino.Result.SUCCESS;
   };

	auto id = p.sendFile("/tmp/test-pacchettino-file");

   assert(p.isQueued(id));
   assert(!p.isProcessing(id));
   assert(!p.isFailed(id));
   assert(!p.isSuccess(id));

   p.receiveOne();

   assert(!p.isProcessing(id));
   assert(!p.isQueued(id));
   assert(!p.isFailed(id));
   assert(p.isSuccess(id));


   rmdirRecurse("/tmp/test-pacchettino");
   std.file.remove("/tmp/test-pacchettino-file");
}

unittest
{
   auto p = new Pacchettino("/tmp/test-pacchettino-missing");

   try {
      p.sendFile("/tmp/non-existent-file-12345");
      assert(false, "Should have thrown Exception");
   } catch (Exception e) {
      assert(e.msg.startsWith("File not found"), "Unexpected error message: " ~ e.msg);
   }

   if (exists("/tmp/test-pacchettino-missing"))
      rmdirRecurse("/tmp/test-pacchettino-missing");
}

unittest
{
    // Reproduction test for file retention
    string baseDir = "/tmp/test-pacchettino-retention";
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

    // Check if file exists in success folder (It probably won't if implementation is as suspected)
    string successPath3 = buildNormalizedPath(baseDir, "success", "fle-" ~ id3 ~ "-testfile_move.txt");
    // This assertion is expected to fail if my hypothesis is correct
    assert(exists(successPath3), "Success file for moved file not found: " ~ successPath3);

    // We want to verify behavior first. If I assert true and it fails, I confirmed the issue.
    // assert(exists(successPath3));

    // Cleanup
    if (exists(baseDir)) rmdirRecurse(baseDir);
}
