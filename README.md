# Pacchettino

**Pacchettino** is a simple, robust file-based queue system for the D programming language. It is designed to be **safe for concurrent use across multiple threads and processes** simultaneously.

It uses atomic file operations (renames) and PID tracking to ensure jobs are processed exactly once and to recover gracefully from crashed consumer processes.

## Features

- **Multi-process & Multi-thread safe**: Multiple producers and consumers can operate on the same directory without race conditions.
- **Persistence**: Jobs are stored as files on disk.
- **Crash Recovery**: Automatically detects stalled jobs from dead processes and moves them to an `interrupted` state (or cleans them up based on policy).
- **Flexible Retention**: Configure which jobs to keep after processing (Success, Failed, Interrupted) using bitwise flags.
- **Simple API**: Easy methods to send data/files and define handlers for receiving them.

## Usage Example

First, add pacchettino to your project

```bash
dub add pacchettino
```

Here is a classic Producer-Consumer example. Both programs point to the same base directory.

### 1. The Producer

This program adds tasks to the queue.

```d
import pacchettino;
import std.stdio;

void main()
{
    // Initialize queue in the "./my_queue" directory
    auto queue = new Pacchettino("./my_queue");

    // Send a file
    // Note: You can also send raw data using queue.sendData("string") or queue.sendData(ubyte[])
    string id = queue.sendFile("./document.txt");
    writeln("Sent file job: ", id);

    // You can check the status of the job
    if (queue.isQueued(id)) writeln("Job is queued");
    if (queue.isProcessing(id)) writeln("Job is being processed");
    // Note: isSuccess and isFailed are only available if KeepPolicy includes SUCCESS/FAILED (default is ALL)
    if (queue.isSuccess(id)) writeln("Job completed successfully");
    if (queue.isFailed(id)) writeln("Job failed");
    if (queue.isInterrupted(id)) writeln("Job was interrupted");
}
```

### 2. The Consumer

This program reads tasks from the queue and processes them.

```d
import pacchettino;
import std.stdio;
import core.thread;

void main()
{
    // Initialize queue in the same directory.
    // KeepPolicy.ALL ensures we keep records of Success, Failed, and Interrupted jobs.
    auto queue = new Pacchettino("./my_queue", Pacchettino.KeepPolicy.ALL);

    // Define what happens when a file is received
    queue.onFileReceived = (string id, string originalName, string filePath) {

        writefln("Processing file job %s (Original name: %s)", id, originalName);
        writefln("File is located at: %s", filePath);

        // ... process the file content here ...

        // Return SUCCESS to move file to 'success' folder,
        // FAILED to move to 'failed', or RETRY to queue it again.
        return Pacchettino.Result.SUCCESS;
    };

    // Note: If you sent raw data instead of files, you would use queue.onDataReceived here.

    writeln("Waiting for jobs...");

    while (true)
    {
        // Process one job if available
        queue.receiveOne();

        // Sleep briefly to avoid busy-waiting loop
        Thread.sleep(100.msecs);
    }
}
```

## Configuration

### KeepPolicy

You can configure what happens to files after processing using `KeepPolicy`. Flags can be combined with `|`.

```d
// Keep everything (Success | Failed | Interrupted)
auto q1 = new Pacchettino("./queue", Pacchettino.KeepPolicy.ALL);

// Keep only failed jobs (useful for debugging errors)
auto q2 = new Pacchettino("./queue", Pacchettino.KeepPolicy.FAILED);

// Keep failed and interrupted jobs, discard successful ones
auto q3 = new Pacchettino("./queue", Pacchettino.KeepPolicy.FAILED | Pacchettino.KeepPolicy.INTERRUPTED);

// Auto-delete everything after processing
auto q4 = new Pacchettino("./queue", Pacchettino.KeepPolicy.NONE);
```

### Folder Structure

Pacchettino creates the following structure inside your base directory:

- `queued/`: Waiting to be processed.
- `processing/`: Currently locked by a consumer process.
- `success/`: Successfully processed jobs.
- `failed/`: Jobs that returned `Result.FAILED`.
- `interrupted/`: Jobs recovered from crashed processes.
- `tmp/`: Temporary staging area for atomic writes.
