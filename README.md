# Pacchettino

**Pacchettino** is a simple, robust file-based queue system for the D programming language. It is designed to be **safe for concurrent use across multiple threads and processes** simultaneously.

It uses atomic file operations (renames) and PID tracking to ensure jobs are processed exactly once and to recover gracefully from crashed consumer processes.

## Features

- **Multi-process & Multi-thread safe**: Multiple producers and consumers can operate on the same directory without race conditions.
- **Persistence**: Jobs are stored as files on disk.
- **Crash Recovery**: Automatically detects stalled jobs from dead processes and moves them to an `interrupted` state (or cleans them up based on policy).
- **Flexible Retention**: Configure which jobs to keep after processing (Success, Failed, Interrupted) using bitwise flags.
- **Simple API**: Easy methods to send data/files and define handlers for receiving them.
- **Delayed jobs and retries**: Send jobs with a delay, or wait before retrying.
- **FIFO or random order**: `receive(false)` / `receiveOne(false)` process jobs in the order they were sent.

> **Note:** Pacchettino relies on POSIX APIs (`kill`) for crash recovery: it runs on Linux, macOS and BSD, but not on Windows.

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
    // (SCHEDULED, QUEUED, PROCESSING, SUCCESS, FAILED, INTERRUPTED or UNKNOWN)
    writeln("Job status: ", queue.status(id));
    writeln("Sent at: ", Pacchettino.sentAt(id));

    // Or use the single checks.
    // Note: isSuccess, isFailed and isInterrupted require the corresponding KeepPolicy flags (enabled by default in KeepPolicy.ALL).
    if (queue.isQueued(id)) writeln("Job is queued");
    if (queue.isFailed(id)) writeln("Job failed");
}
```

> **Note:** `sendFile` accepts file names up to 200 bytes (the filesystem limit is 255 bytes per name, and Pacchettino adds its own prefixes).

### 2. The Consumer

This program reads tasks from the queue and processes them.

```d
import pacchettino;
import std.stdio;
import std.datetime;

void main()
{
    // Initialize queue in the same directory.
    // KeepPolicy.ALL ensures we keep records of Success, Failed, and Interrupted jobs.
    auto queue = new Pacchettino("./my_queue", Pacchettino.KeepPolicy.ALL);

    // Define what happens when a file is received
    queue.onFileReceived = (string id, string originalName, string filePath) {

        writeln("Processing file: ", originalName);
        writeln("File path: ", filePath);
        writeln("Job ID: ", id);

        // ... process the file content here ...

        // Return SUCCESS if processing was successful,
        // FAILED if something went wrong,
        // or RETRY to re-queue the job for another attempt.
        return Pacchettino.Result.SUCCESS;
    };

    // Note: If you sent raw data instead of files, you would use queue.onDataReceived here.

    writeln("Waiting for jobs...");

    while (true)
    {
        // Wait up to 5 seconds for a job and process it.
        // Returns false if no job arrived in time.
        if (!queue.receiveOne(5.seconds))
            writeln("Still waiting...");
    }
}
```

`receiveOne()` without a timeout returns immediately (`true` if a job was processed), while `receive()` processes all queued jobs and returns how many.

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

Kept jobs are never deleted automatically. Use `cleanup` to remove them:

```d
// Remove successful jobs older than 7 days
queue.cleanup(Pacchettino.KeepPolicy.SUCCESS, 7.days);

// Remove all kept jobs
queue.cleanup();
```

### Retrying jobs

Failed and interrupted jobs can be moved back to the queue:

```d
queue.requeue(id);   // A single job
queue.requeueAll();  // All failed and interrupted jobs
queue.requeueAll(Pacchettino.KeepPolicy.INTERRUPTED); // Only interrupted jobs
```

### Delayed jobs

Jobs can be sent with a delay: they stay in `scheduled/` and are moved to the queue when the delay expires.

```d
queue.sendData("reminder", 10.minutes);
queue.sendFile("./report.pdf", true, 1.hours);

// RETRY waits 30 seconds before processing the job again (default: immediately)
queue.retryDelay = 30.seconds;
```

Delayed jobs are picked up by the next `receive`/`receiveOne` call after their delay, so with `receiveOne(timeout)` they are processed within one poll interval.

Job ids passed to callbacks can be used too with `status`, `requeue`, `sentAt` and the `is*` methods.

### Counters

`countScheduled`, `countQueued`, `countProcessing`, `countSuccessful`, `countFailed`, `countInterrupted` and `countAll` return the number of jobs in each state.

### Folder Structure

Pacchettino creates the following structure inside your base directory:

- `scheduled/`: Sent with a delay not yet expired.
- `queued/`: Waiting to be processed.
- `processing/`: Currently locked by a consumer process.
- `success/`: Successfully processed jobs.
- `failed/`: Jobs that returned `Result.FAILED`.
- `interrupted/`: Jobs recovered from crashed processes.
- `tmp/`: Temporary staging area for atomic writes.
