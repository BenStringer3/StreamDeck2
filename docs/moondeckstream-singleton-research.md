# MoonDeckStream singleton and clean state

Research into MoonDeckStream’s implementation and how to guarantee a clean working state before launch. Source: [FrogTheFrog/moondeck-buddy](https://github.com/FrogTheFrog/moondeck-buddy).

## Intended usage

- **Who starts it:** Sunshine starts MoonDeckStream when the user launches “MoonDeckStream” from Moonlight (via MoonDeck). One process per stream session.
- **Who stops it:** Sunshine terminates the process when the stream ends (e.g. SIGTERM or closing the session).
- **Design:** MoonDeckStream is a **singleton** per host: only one instance should run. A second launch must either fail or replace the first.

## Singleton implementation

- **Location:** `src/stream/main.cpp` uses `utils::SingleInstanceGuard` with the app name `"MoonDeckStream"` (from `shared::AppMetadata::App::Stream`). Implementation in `src/lib/utils/singleinstanceguard.cpp`.
- **Mechanism:**
  - **QSystemSemaphore** (key = `SHA1("MoonDeckStream" + "_mem_lock_key")`) — coordination lock.
  - **QSharedMemory** (key = `SHA1("MoonDeckStream" + "_shared_mem_key")`) — “someone is running” marker.
- **Flow:** On startup, the guard’s `tryToRun()` checks `isAnotherRunning()` (attach to existing shm); if true, the app prints “Another instance of MoonDeckStream is already running!” and exits with failure. Otherwise it creates the shm segment and continues. On normal shutdown, the destructor calls `release()` and detaches the shm.

## Why SIGTERM leaves “another instance” visible

- **Signal handling:** `utils::installSignalHandler()` (used by MoonDeckStream) registers a handler for SIGTERM (and SIGINT, SIGHUP, SIGQUIT) that calls **`std::quick_exit(128 + signum)`** (e.g. SIGTERM → 143). See `src/lib/utils/unixsignalhandler.cpp`.
- **No cleanup on exit:** `quick_exit()` does **not** run C++ destructors or `atexit` handlers. So `SingleInstanceGuard::~SingleInstanceGuard()` is never run when the process is terminated by SIGTERM; `release()` is never called and the QSharedMemory is never explicitly detached or marked for removal (IPC_RMID).
- **System V shm/sem persist:** On Linux, System V shared memory segments and semaphores are **not** automatically destroyed when the last process exits or detaches. The segment persists until some process calls `shmctl(..., IPC_RMID, ...)`. Qt’s design is “the last attachment is responsible for removing the object”; when we `quick_exit()`, we never run that path. So after the killed process exits, the kernel detaches it from the segment (nattch → 0), but the **segment itself remains**. The new process then calls `attach()` with the same key (from the same Qt key file); attach succeeds (the segment exists), so the app thinks “another instance is running” and exits. So the race hypothesis was wrong: even after waiting for stale PIDs to disappear, the orphaned segment is still there.

## How to guarantee a clean working state

1. **Kill only other PIDs:** Send SIGTERM only to stale MoonDeckStream PIDs (exclude the current wrapper’s PID). Wait until those PIDs have exited (poll `kill -0` with a timeout).
2. **Remove orphaned Qt IPC key files:** Qt uses key files in `/tmp` (e.g. `qipc_sharedmemory_<key>`, `qipc_systemsem_<key>`) for `ftok()` so that the same key string yields the same System V key. After the stale process exits, that key file still exists and the shm segment still exists. If we **remove the key file** (for MoonDeckStream’s keys only), the next run of the real binary will create a **new** key file (same path); `ftok()` will then yield a **different** key (e.g. new inode), so the new process will not attach to the orphaned segment — it will `create()` a new one and succeed. The wrapper therefore removes `/tmp/qipc_sharedmemory_*` and `/tmp/qipc_systemsem_*` (and under `/tmp/$UID` if present) whose filename contains the SHA1 of `MoonDeckStream_shared_mem_key` or `MoonDeckStream_mem_lock_key`.
3. **Diagnostics:** `collect-logs.sh` captures `ipcs -m`, `ipcs -s`, and listings of `/tmp/qipc_*`, `/tmp/$(id -u)/qipc_*`, and `XDG_RUNTIME_DIR` (e.g. `/run/user/*/qipc_*`) in `ipcs.txt` so lock state and key file locations can be inspected.

No change to MoonDeckStream itself is required; the wrapper guarantees clean state by (a) killing only other PIDs and waiting for them to exit, and (b) removing the orphaned Qt IPC key files so the new process gets a fresh key and create()s a new segment instead of attach()ing to the orphaned one.

## Verified on this setup

**Key-file cleanup (2026-02-15):** Diagnostic wrapper run showed that **key-file cleanup does not match** MoonDeckStream’s IPC on this host. In `/tmp` there are many `qipc_sharedmemory_*` and `qipc_systemsem_*` files, but **none** contain the expected hashes (HASH_SHM=4fdc6ad9708de625bd8e08736a740b3b1cbb75fa, HASH_SEM=669a9a2d0f8e7b84f2c051be7f5340038b94222d). The wrapper logged "Candidate key file: ... (match=no)" for each and "Singleton cleanup: removed 0 key file(s)". So either MoonDeckStream’s key files are in a different path (e.g. only under XDG_RUNTIME_DIR and not present at wrapper run time), or this build uses a different key format than the upstream SHA1 strings. The "remove key files" fix is therefore **not** effective here.

**Option A test (2026-02-15):** We tried **direct invocation** of the MoonDeckStream binary (no wrapper), per [Sunshine setup](https://github.com/FrogTheFrog/moondeck-buddy/wiki/Sunshine-setup): Sunshine ran `/usr/bin/MoonDeckStream` with the same env. Result: **same failure** — app exited with code 256 in ~165 ms. With the wrapper we see "Another instance of MoonDeckStream is already running!" in stderr; with direct invocation we only see exit 256 (no wrapper logs, same outcome). So the **wrapper is not at fault**: the root cause is orphaned IPC from a previous run (SIGTERM → quick_exit → no destructors → segment persists). Any new launch, wrapper or direct, hits that segment and fails. We reverted to the wrapper as the default; the wrapper at least kills stale PIDs and attempts key-file cleanup, and its diagnostic logging helps confirm the singleton message. See [troubleshooting.md](troubleshooting.md) for current mitigation and next steps (e.g. experiment-singleton.sh, ipcrm fallback).

## Running the singleton investigation

To verify where Qt creates key files and whether the wrapper's cleanup would find them, run (requires sudo):

```bash
sudo ./scripts/experiment-singleton.sh
```

Results are written to `logs/singleton-<timestamp>/findings.txt`. Paste that file (or its contents) back into the chat for analysis.

## Interpreting experiment-singleton findings

Use the **"Filename vs hash: do any qipc_* filenames contain HASH_SHM or HASH_SEM?"** section in `findings.txt`:

- **(a) Whether any qipc_* files exist after Phase 2:** See "Phase 3: qipc_* files after run then SIGTERM" and "Phase 4: Full paths of qipc_* found". If the list is empty, no Qt key files were found in `/tmp`, `/tmp/$BUDDY_UID`, or `/run/user/$BUDDY_UID` — Qt may be using a different backend (e.g. POSIX) or a path not searched (e.g. only under a different XDG path, or only when DISPLAY is active).
- **(b) Full paths and filenames:** The same sections list every `qipc_sharedmemory_*` and `qipc_systemsem_*` path found.
- **(c) Match to HASH_SHM / HASH_SEM:** Each path is compared to the wrapper’s hashes (SHA1 of `MoonDeckStream_shared_mem_key` and `MoonDeckStream_mem_lock_key`). If every file is reported as **"NO MATCH (wrapper would not remove this)"**, the key format differs from the legacy SHA1-in-filename pattern (e.g. Qt 6 native key format).

**Conclusion:** If no qipc_* files are found, or none match the hashes, key-file cleanup in the wrapper is **ineffective** on this host. Prefer **ipcrm**-based cleanup (remove orphaned shm/sem; see [troubleshooting.md](troubleshooting.md)) or, if you need key-file cleanup, determine the Qt version–specific key path (e.g. via `strace -f -e openat,open` on MoonDeckStream and grep for `qipc_`).

## References

- `main.cpp`: guard creation and “Another instance … already running!” message, `EXIT_FAILURE` on singleton failure.
- `singleinstanceguard.cpp`: QSystemSemaphore + QSharedMemory, `tryToRun()` / `isAnotherRunning()` / `release()`.
- `unixsignalhandler.cpp`: SIGTERM → `quick_exit(128+15)` (no destructors).
- MoonDeck Buddy wiki: [Sunshine setup](https://github.com/FrogTheFrog/moondeck-buddy/wiki/Sunshine-setup), [Troubleshooting](https://github.com/FrogTheFrog/moondeck-buddy/wiki/Troubleshooting).
