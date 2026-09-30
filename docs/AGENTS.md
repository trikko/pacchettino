# pacchettino

pacchettino is a job queue for the D programming language made of plain
directories on disk: producers add jobs, consumers (in other processes or
threads) process them. No server, no database, no dependencies. POSIX only
(Linux, macOS, BSD).

Read the reference before writing pacchettino code. It is two files:

- **`llms-full.txt`** — the whole API in one file: sending, receiving,
  callbacks, results, delays and retries, status, counters, requeue, cleanup,
  keep policy, crash recovery, directory layout, worked examples. This is the
  one to read.
  <https://trikko.github.io/pacchettino/llms-full.txt>
- **`llms.txt`** — a page of overview, when the full one is more than you need.
  <https://trikko.github.io/pacchettino/llms.txt>

In the packaged skill both sit next to this file; installed from the web, fetch
them from the addresses above. The html API reference is at
<https://trikko.github.io/pacchettino/>.

pacchettino is not a Redis, RabbitMQ or database client, and it has no
`Queue!T`, `push`/`pop`, `enqueue`/`dequeue`, `Worker` or `Job` class: none of
those names exist here. What follows are the rules that are easiest to get
wrong.

## Shape of a program

```d
import pacchettino;
import core.time;   // for 10.minutes, 5.seconds, ...

// Producer
void producer()
{
    auto queue = new Pacchettino("/var/spool/myapp");

    string id = queue.sendFile("/tmp/video.mp4");      // copied into the queue
    queue.sendData("resize 42");                       // some bytes
    queue.sendData("remind 42", 10.minutes);           // not before 10 minutes
}

// Consumer: another program, or another thread
void consumer()
{
    auto queue = new Pacchettino("/var/spool/myapp");

    queue.onFileReceived = (string id, string name, string path) {
        upload(path);                           // throwing counts as FAILED
        return Pacchettino.Result.SUCCESS;      // or FAILED, or RETRY
    };

    queue.onDataReceived = (string id, ubyte[] data) {
        auto command = cast(string) data;
        return Pacchettino.Result.SUCCESS;
    };

    queue.retryDelay = 30.seconds;              // RETRY waits before the next attempt

    while (true)
        queue.receiveOne(5.seconds);            // waits up to 5s for a job
}
```

`dub add pacchettino`. dmd or ldc2.

## Rules

1. **Set the callbacks before receiving.** The default `onDataReceived` and
   `onFileReceived` return `Result.FAILED`: a consumer that only sets
   `onFileReceived` marks every `sendData` job as failed, and the other way
   round. Set the callback for every kind of job that can arrive.
2. **Every program opens the same directory.** `new Pacchettino(dir)` creates
   the subdirectories if missing; there is no connect, no open, no close. Any
   number of producers and consumers can use the same directory at once.
3. **Nothing happens by itself.** There is no background thread and no
   notification: jobs are processed only inside `receive`, `receiveOne` or
   `receiveOne(timeout)`, in the thread that calls them, one at a time.
   Delayed jobs and crashed jobs are also handled there. A consumer is a loop.
4. **`receiveOne(timeout)` is the consumer loop.** It polls every 100 ms (the
   third argument changes it) and returns `true` as soon as it processed a job,
   `false` on timeout. `receiveOne()` returns at once; `receive()` processes
   every job queued and returns how many. Do not write a `sleep` loop around
   `receiveOne()`.
5. **Random order by default.** `receive()` and `receiveOne()` pick jobs in
   random order, so that many consumers do not all fight for the same job.
   Pass `false` (`receiveOne(false)`, `receiveOne(5.seconds, false)`) for FIFO.
6. **Two kinds of id.** `sendData`/`sendFile` return a UUIDv7
   (`"01a0f35b-14fd-7000-903a-e2144b506627"`); the callbacks receive the name of
   the job (`"raw-<uuid>"` or `"fle-<uuid>-<name>"`). `status`, `requeue`,
   `sentAt` and the `is*` methods accept both.
7. **Do not move or delete the file in `onFileReceived`.** Read it, or copy it.
   pacchettino moves it afterwards to `success/`, `failed/` or back to the
   queue, or deletes it, according to the result. `name` is the original file
   name, `path` where it is now.
8. **`sendFile` copies by default.** `sendFile(path, false)` moves the file
   instead (also across filesystems). Names longer than 200 bytes are refused.
   `sendData` loads the whole payload in memory on the consumer side: for big
   payloads send a file.
9. **Results.** `SUCCESS` and `FAILED` are final; `RETRY` puts the job back in
   the queue, or in `scheduled/` for `retryDelay` if set. There is no attempt
   counter: count the attempts yourself if you need a limit. An exception from
   the callback is `FAILED`.
10. **Crashed jobs are not retried automatically.** If a consumer dies while
    processing, the next `receive*` of any consumer moves that job to
    `interrupted/` (or deletes it with a keep policy without `INTERRUPTED`).
    The callback may have done part of the work. Call `requeueAll()` (or
    `requeueAll(KeepPolicy.INTERRUPTED)`) to try again.
11. **Delays**: `sendData(data, delay)`, `sendFile(path, true, delay)`. The job
    waits in `scheduled/` and becomes `QUEUED` at the first `receive*` after the
    delay. `copyFile` comes before `delay` in `sendFile`.
12. **Keep policy.** `new Pacchettino(dir, KeepPolicy.FAILED | KeepPolicy.INTERRUPTED)`
    keeps only those; the default `ALL` keeps every processed job forever:
    call `cleanup(which, olderThan)` periodically. `isSuccess`, `isFailed`,
    `isInterrupted`, `countSuccessful`, `countFailed` and `countInterrupted`
    throw if the policy does not keep that state; `status(id)` never throws.
13. **One machine only.** Crash detection uses the PIDs of local processes: do
    not share the directory between machines (NFS, SMB, synced folders). Use a
    local filesystem.
14. **Duration literals need an import.** `5.seconds`, `10.minutes` come from
    `core.time` (or `std.datetime`); `import pacchettino;` does not bring them.
15. **UUIDs**: `import pacchettino.uuid;` for `UUIDv7()`, `UUIDv4()`,
    `UUIDv5(name, UUIDNamespace.DNS)`, `UUIDv3(...)`; `!ubyte` gives `ubyte[16]`.

## Not in pacchettino

No priorities, no attempt limit, no job dependencies, no scheduling by date
(only a delay), no notifications or inotify, no network or multi-machine
queue, no Windows. Do not invent these: say they are missing, or build them on
top (a priority can be a second queue directory).

## If the project uses another version

This file documents the `main` branch. The last release, 1.0.3, has only the
constructor, `sendData`/`sendFile` without delay, `receive`/`receiveOne`
returning `void`, the callbacks and the `is*` methods. `status`, `sentAt`,
`requeue`, `requeueAll`, `cleanup`, the `count*` methods, delays, `retryDelay`,
`isScheduled`, `receiveOne(timeout)` and FIFO order came after. If
`dub.selections.json` pins an older pacchettino, check the signatures against
the source in `source/pacchettino/package.d`.
