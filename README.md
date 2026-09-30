# Pacchettino

[![CI](https://github.com/trikko/pacchettino/actions/workflows/ci.yml/badge.svg)](https://github.com/trikko/pacchettino/actions/workflows/ci.yml)
[![DUB](https://img.shields.io/dub/v/pacchettino)](https://code.dlang.org/packages/pacchettino)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**Pacchettino** is a job queue for the D programming language made of plain
directories: one program sends jobs, another one (or many, in other processes
or threads) processes them. Jobs are files on disk, so they survive crashes and
reboots. No server, no database, no dependencies.

**Documentation:** [API reference](https://trikko.github.io/pacchettino/) ·
[for AI agents](#using-pacchettino-with-an-ai-agent) · `dub add pacchettino`

## Why

A program often has to do something slow or unreliable that it should not wait
for: upload a video to a server, send an email, resize a photo, call an API
that is sometimes down. Doing it on the spot blocks the program, and if the
network fails or the process crashes halfway, the work is simply lost.

The usual answer is a message broker (Redis, RabbitMQ, a table in a database
used as a queue): one more service to install, configure and keep running,
often for a single machine and a few jobs a minute. Pacchettino is the small
version of that answer, on the filesystem you already have:

- the program that has the work **hands it over and moves on**: `sendFile` or
  `sendData` return as soon as the job is safely on disk;
- a **worker**, a separate program or a thread, picks the jobs up and processes
  them; add more workers to go faster, each job goes to one of them only;
- if a job fails it is kept in `failed/`, if it should be **tried again later**
  the worker says so (`RETRY`, with a delay if you want), if a worker **crashes**
  mid-job the job is found and moved to `interrupted/`, ready to be requeued;
- the state of every job is **visible**: `queue.status(id)` in code, or just
  `ls` on the directories.

Typical uses: a kiosk or photo booth that uploads its videos when the network
is there, a web server that hands long tasks to a background worker, a script
that feeds jobs to another program, anything that should keep working after a
power cut.

It is not meant for queues shared between machines, or for millions of jobs per
second: there, use a real broker.

## Features

- **Multi-process & Multi-thread safe**: Multiple producers and consumers can operate on the same directory without race conditions; each job is given to one consumer only.
- **Persistence**: Jobs are stored as files on disk.
- **Crash Recovery**: Automatically detects stalled jobs from dead processes and moves them to an `interrupted` state (or cleans them up based on policy).
- **Flexible Retention**: Configure which jobs to keep after processing (Success, Failed, Interrupted) using bitwise flags.
- **Simple API**: Easy methods to send data/files and define handlers for receiving them.
- **Status tracking**: `status(id)`, counters, requeue of failed and interrupted jobs, cleanup of old ones.
- **Delayed jobs and retries**: Send jobs with a delay, or wait before retrying.
- **FIFO or random order**: `receive(false)` / `receiveOne(false)` process jobs in the order they were sent.

> **Note:** Pacchettino runs on Linux, macOS, BSD and Windows, on a local filesystem of a single machine.

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

## Using pacchettino with an AI agent

pacchettino is small and not well known, so it is barely in the training data
of the models: a model left to guess writes code for another queue library, or
invents one. Give it the reference instead:

* [SKILL.md](https://trikko.github.io/pacchettino/SKILL.md): the rules that are
  easiest to get wrong, as a skill. [AGENTS.md](https://trikko.github.io/pacchettino/AGENTS.md)
  is the same text without the front matter, for tools that want a rules file
  (`AGENTS.md`, `CLAUDE.md`, `.cursorrules`, ...).
* [llms-full.txt](https://trikko.github.io/pacchettino/llms-full.txt): the whole API;
  [llms.txt](https://trikko.github.io/pacchettino/llms.txt): a short overview.

The easiest way: ask your agent to do it.

> Install the skill at https://trikko.github.io/pacchettino/SKILL.md. It is the
> reference for pacchettino, the D job queue I am using.

Or by hand: a skill is a folder with `SKILL.md` in it (`llms-full.txt` next to
it saves a download).

| Tool | For all projects | For one project |
|---|---|---|
| Claude Code | `~/.claude/skills/pacchettino/` | `.claude/skills/pacchettino/` |
| Antigravity (IDE, 2.0) | `~/.gemini/config/skills/pacchettino/` | `.agents/skills/pacchettino/` |
| Antigravity CLI | `~/.gemini/antigravity-cli/skills/pacchettino/` | `.agents/skills/pacchettino/` |
| Gemini CLI | `~/.gemini/skills/pacchettino/` | `.gemini/skills/pacchettino/` |
| Codex | `~/.agents/skills/pacchettino/` | `.agents/skills/pacchettino/` |

For example, for Claude Code:

```sh
mkdir -p ~/.claude/skills/pacchettino && cd ~/.claude/skills/pacchettino
curl -fsSLO https://trikko.github.io/pacchettino/SKILL.md
curl -fsSLO https://trikko.github.io/pacchettino/llms-full.txt
```

The skill is loaded when the task is about pacchettino or job queues in D; in
Claude Code you can also call it with `/pacchettino`.

## Development

```sh
dub test        # unit tests
tools/docs.sh   # regenerate the documentation in docs/
```

The html reference in `docs/`, served by GitHub Pages, is generated from the
comments in the source with `tools/docs.sh` (ddox with the scod skin).
`docs/AGENTS.md`, `docs/llms.txt` and `docs/llms-full.txt` are written by hand;
`docs/SKILL.md` is generated from `AGENTS.md`.
