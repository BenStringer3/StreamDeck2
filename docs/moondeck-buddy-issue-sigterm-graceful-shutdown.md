# MoonDeck Buddy issue: SIGTERM causes orphaned singleton IPC (suggested fix: graceful shutdown)

Use this document to open an issue or PR on [FrogTheFrog/moondeck-buddy](https://github.com/FrogTheFrog/moondeck-buddy). Copy or adapt the sections below.

---

## Title (suggestion)

**MoonDeckStream: SIGTERM → quick_exit() leaves orphaned System V IPC; next launch fails with "Another instance already running!"**

---

## Environment

- **MoonDeckStream** started by Sunshine when the user launches a stream from Moonlight (e.g. Steam Deck + MoonDeck).
- **Stopping:** Sunshine sends **SIGTERM** to MoonDeckStream when the stream ends (session close, disconnect, etc.).
- **OS:** Linux (System V IPC: `shmget`/`semget`, `ipcrm`).

---

## Problem

After a stream ends, Sunshine terminates MoonDeckStream with SIGTERM. The **next** time the user tries to start a stream, MoonDeckStream exits immediately with:

```text
Another instance of MoonDeckStream is already running!
```

and exit code 256 (or 15). The stream never starts; the client sees "Initial Ping Timeout" / Error 11.

---

## Root cause

1. **Singleton implementation** (`SingleInstanceGuard` in `src/lib/utils/singleinstanceguard.cpp`): MoonDeckStream uses **QSharedMemory** and **QSystemSemaphore** so only one instance runs. On normal process exit, the destructor runs and releases the IPC (detach / IPC_RMID).

2. **Signal handler** (`src/lib/utils/unixsignalhandler.cpp`): For SIGTERM (and SIGINT, SIGHUP, SIGQUIT), the handler calls **`std::quick_exit(128 + signum)`**.

3. **Effect of quick_exit():** `quick_exit()` does **not** run C++ destructors or `atexit` handlers. So when the process is killed by SIGTERM, `SingleInstanceGuard::~SingleInstanceGuard()` never runs, `release()` is never called, and the QSharedMemory/QSystemSemaphore are never removed.

4. **System V IPC semantics:** Shared memory segments and semaphore arrays persist in the kernel until some process calls `shmctl(..., IPC_RMID, ...)` (or `semctl(..., IPC_RMID, ...)). The process that exited did not do that, so the segment/semaphore remain. A **new** MoonDeckStream process then attaches to the same key (via Qt’s key files), sees existing IPC, concludes “another instance is running,” and exits.

So the **combination** of “Sunshine sends SIGTERM” (normal) and “MoonDeckStream responds with quick_exit()” (no cleanup) leaves orphaned IPC and breaks the next launch.

---

## Steps to reproduce

1. Start a stream from Moonlight to a host where Sunshine runs MoonDeckStream.
2. End the stream (disconnect or stop from client). Sunshine sends SIGTERM to MoonDeckStream.
3. Without rebooting or manually clearing IPC, start a new stream again.
4. MoonDeckStream exits immediately with “Another instance of MoonDeckStream is already running!” and the stream fails.

On Linux, orphaned IPC can be confirmed with `ipcs -m` and `ipcs -s` (segments/arrays owned by the MoonDeckStream user with no attachments / no users). Removing them with `ipcrm -m <shmid>` and `ipcrm -s <semid>` allows the next launch to succeed.

---

## Suggested fix (graceful shutdown on SIGTERM)

Handle SIGTERM (and optionally SIGINT/SIGHUP) so that the process exits **normally** and destructors run, instead of calling `quick_exit()`:

- In the signal handler: set a global or thread-safe “shutdown requested” flag and return (no `quick_exit()`).
- In the main/event loop: periodically check the flag (or use a notifier); when set, exit the loop and let the application exit normally (e.g. `return` from `main()` or `QCoreApplication::quit()`).
- Then destructors (including `SingleInstanceGuard::~SingleInstanceGuard()` and thus `release()`) run, and the singleton IPC is cleaned up. No orphaned segments or semaphores.

This matches common practice for daemons and GUI apps that receive SIGTERM: “please exit” → orderly shutdown → cleanup. If the goal of `quick_exit()` was to avoid running complex code in a signal context, moving “exit” to the main loop achieves that while still allowing cleanup.

---

## References

- Singleton: `src/stream/main.cpp` (guard creation), `src/lib/utils/singleinstanceguard.cpp` (QSystemSemaphore + QSharedMemory, `tryToRun()` / `release()`).
- Signal handler: `src/lib/utils/unixsignalhandler.cpp` (SIGTERM → `quick_exit(128+signum)`).
- Qt: QSharedMemory / QSystemSemaphore use System V IPC on Linux; segments persist until IPC_RMID.

---

## Workaround (host-side)

Until the app exits gracefully on SIGTERM, hosts can work around the issue by cleaning up before each launch: kill any stale MoonDeckStream PIDs, then remove orphaned System V shared memory (and optionally semaphores) owned by the MoonDeckStream user (e.g. with `ipcrm`). This is fragile (key-file cleanup may not match Qt’s key format; removing all user semaphores can affect other Qt apps). Prefer fixing the signal handling in MoonDeckStream.
