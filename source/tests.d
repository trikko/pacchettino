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