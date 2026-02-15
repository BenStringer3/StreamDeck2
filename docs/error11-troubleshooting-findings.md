# Error 11 (MoonDeckStream exit 15) — Troubleshooting Findings

This document records deliverables from the [Error 11 troubleshooting plan](.cursor/plans/error_11_moondeckstream_troubleshooting_fac8cf0d.plan.md). It is updated as phases complete.

---

## Phase 1: Findings from failing run (log dir `streamdeck-20260215-124301`)

### 1. MoonDeckStream stderr

**File:** `moondeckstream-stderr.log` (and `/tmp/moondeckstream-stderr.log` when collect-logs ran)

**Contents:**
```
buddy.stream: Another instance of "MoonDeckStream" is already running!
buddy.stream: Another instance of "MoonDeckStream" is already running!
```

So stderr is **not** missing/empty. MoonDeckStream printed the singleton message ("Another instance already running") to stderr before exiting. The troubleshooting doc describes exit **256** for this case; this run showed exit **15**.

### 2. MoonDeckStream stdout (Sunshine app output)

**File:** `LOG_DIR/moondeckstream.log` (in the bundle; Sunshine writes app stdout to config dir as `moondeckstream.log`)

**Contents:** The copied `moondeckstream.log` in the bundle contains entries from a **different** run (timestamps `[15:02:08]` and `[15:10:08]`), not the failing run at 12:42:15. For the 12:42:15 launch there is no stdout in the bundle from that ~80 ms window—either Sunshine did not flush/write it before the process exited, or the file was overwritten by a later run. **Documented:** stdout for the failing run is effectively missing/empty in the bundle (only older run content present).

### 3. Buddy at failure time (12:42:15)

**Files:** `journalctl-moondeckbuddy.log`, `moondeck-diagnostics.txt`

**Finding:** No Buddy log lines at **12:42:15**. Last Buddy activity on Feb 15 in the journal is `12:40:08.741` — "Server started listening at port 59999". No "Stream started", no connection from MoonDeckStream, no errors in that second. **Documented:** No Buddy activity at 12:42:15; MoonDeckStream exited before Buddy logged any interaction (or before any connection was established).

### 4. Sunshine log (exact command and exit)

**File:** `sunshine-logs/sunshine.log`

**Executing (12:42:15.809):**
```
Executing: [sudo -u __BUDDY_USER__ HOME=/home/__BUDDY_USER__ USER=__BUDDY_USER__ XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus DISPLAY=:99 SUNSHINE_LAUNCHED=1 __NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia __VK_LAYER_NV_optimus=NVIDIA_only /usr/local/bin/MoonDeckStream] in ["/usr/bin"]
```

**Exit (12:42:15.890):**
```
App exited with code [15]
Process terminated
```

**Timeline (Phase 1):**
- 12:42:15.809 — Sunshine executes MoonDeckStream (command above).
- 12:42:15.889 — Sunshine: "New streaming session started [active sessions: 1]".
- 12:42:15.890 — Sunshine: "App exited with code [15]", "Process terminated".
- No Buddy log lines at 12:42:15. MoonDeckStream stderr shows "Another instance already running" (two lines).

**Deliverable summary:** MoonDeckStream stderr shows the singleton message; stdout for that run is not present in the bundle; Buddy had no activity at 12:42:15; Sunshine log gives the exact command for reproduction.

---

## Phase 2: Interpreting exit code 15

**Objective:** Determine whether "code [15]" is a signal (SIGTERM = 15) or a process exit status (e.g. `exit(15)`).

- **Unix convention:** For `wait()` status: if the process exited normally, the low 8 bits are the exit status (0–255). If the process was terminated by a signal, the status is often reported as 128+signum (e.g. 128+15=143 for SIGTERM). So a raw status of **15** is consistent with the process having called `exit(15)` (normal exit with status 15), not with being killed by SIGTERM (which would typically be 143 in raw form, unless the reporter decodes and shows the signal number separately).
- **Sunshine:** The exact format "App exited with code [15]" was not found in LizardByte/Sunshine source via public search; the codebase may use a different string or locale. Without the exact source line we assume the number is the exit status as reported by the runtime (e.g. WEXITSTATUS on Linux). **Conclusion:** Treat **15** as the process exit status (MoonDeckStream likely called `exit(15)` for the "Another instance already running" path, or another internal reason). If it were SIGTERM we would expect 143 unless Sunshine decodes and prints the signal number—then "15" could mean signal 15. The stderr message points to the singleton exit path; that path may use exit code 15 in MoonDeckStream.

**Deliverable:** When you see "App exited with code [15]", check MoonDeckStream stderr first for "Another instance already running". If present, the root cause is the singleton check (stale instance or wrapper pkill timing). Code 15 in this codebase is consistent with an intentional exit(15), not necessarily SIGTERM.

**Update (repro run 2026-02-15):** Local repro with `sudo ./experiment.sh repro` produced **exit code 143** (128+15 = killed by SIGTERM). So when Sunshine reports "App exited with code [15]", it is likely reporting the **signal number** (15 = SIGTERM), not the raw wait status. The process is being terminated by SIGTERM; the "Terminated" message in the repro confirms it. Captured stdout/stderr in the repro run were empty (process may have been killed before flush, or output went elsewhere). Root cause remains: singleton path or something sending SIGTERM to MoonDeckStream shortly after start.

---

## Phase 4: Timeline and conclusion

**Timeline (from Phase 1 log bundle):**

| Time (Sunshine log)   | Event |
|----------------------|--------|
| 12:42:15.809         | Sunshine: Executing MoonDeckStream (sudo -u __BUDDY_USER__ … /usr/local/bin/MoonDeckStream) |
| 12:42:15.889         | Sunshine: New streaming session started [active sessions: 1] |
| 12:42:15.890         | Sunshine: App exited with code [15], Process terminated |
| (stderr)              | MoonDeckStream: "Another instance of MoonDeckStream is already running!" (×2) |
| 12:42:15             | Buddy: no log lines (last Buddy activity 12:40:08) |

**Conclusion (from Phase 1 evidence):** MoonDeckStream writes "Another instance already running" to stderr then exits with code 15; Buddy sees no connection at 12:42:15. Root cause is the singleton check (stale instance or wrapper pkill not clearing before the new process starts).

**Repro run (2026-02-15):** `sudo ./experiment.sh repro` → exit **143** (SIGTERM), stdout/stderr empty in capture. Sunshine’s "code [15]" is therefore the signal number (SIGTERM), not raw wait status. Either the wrapper’s `pkill -u $(whoami) -x MoonDeckStream` is hitting the new process (e.g. if process name matches before/after exec), or MoonDeckStream self-signals SIGTERM on singleton detection. Next: ensure no stale MoonDeckStream before launch; consider making the wrapper avoid killing the just-started process (e.g. delay pkill until after a short sleep and only target PIDs that existed before the current PID).

---

## Additional run: streamdeck-20260215-132455 (exit 256, wrapper logs)

**Sunshine:** Executing 13:24:49.009 → App exited with code [256] 13:24:49.641.

**moondeckstream-stderr.log (this run):**
```
buddy.stream: Another instance of "MoonDeckStream" is already running!
buddy.stream: Another instance of "MoonDeckStream" is already running!
[2026-02-15T13:24:49+01:00] wrapper: Sending SIGTERM to stale MoonDeckStream PIDs (excluding self 1206620): 1206621
[2026-02-15T13:24:49+01:00] wrapper: Waiting 0.5s for stale processes to release lock...
[2026-02-15T13:24:49+01:00] wrapper: Exec-ing real binary: /usr/bin/MoonDeckStream
buddy.stream: Another instance of "MoonDeckStream" is already running!
```

**Insight:** The first two lines are from an earlier run. For this run: the wrapper (PID 1206620) found a stale MoonDeckStream PID 1206621, sent SIGTERM, waited 0.5s, then exec'd the real binary. The real binary started and **still** printed "Another instance already running!" and exited with 256. So **after killing the stale process and waiting 0.5s, the new instance still sees "another instance"**. The singleton uses QSharedMemory + QSystemSemaphore; on SIGTERM the app calls `quick_exit()` so it never runs destructors and never releases the lock; the kernel frees it only after the process fully exits. So 0.5s was insufficient for the killed process to exit. **Follow-up:** See [moondeckstream-singleton-research.md](moondeckstream-singleton-research.md) for implementation and clean-state guarantees. The wrapper was updated to wait 2s after SIGTERM before starting the new instance.

---

## Remove key files fix — not observed

In all failing runs inspected, the wrapper **never** logs "Removed orphaned Qt IPC key file: ...". So the "remove key files" cleanup is not taking effect: either no key files exist at the paths the wrapper checks (`/tmp`, `/tmp/$(id -u)`), or the filenames do not match the wrapper’s hash filter, or Qt uses a different IPC backend (e.g. POSIX) with no key files. **Next step:** Run `sudo ./scripts/experiment-singleton.sh` and inspect `logs/singleton-<timestamp>/findings.txt` to verify where (if anywhere) Qt creates key files and whether they match the wrapper’s hashes. See [moondeckstream-singleton-research.md](moondeckstream-singleton-research.md) (Running the singleton investigation).
