# Troubleshoot Stream Deck test-full-cycle logs

You are analyzing diagnostic logs produced by `test-full-cycle.sh` (deploy → manual stream from Steam Deck → log collection). Your job is to identify bad behavior, build a timeline of relevant evidence, hypothesize root causes, and drive fixes via targeted experiments. Follow AGENTS.md (fail-fast, scientific method, maintain collect-logs and docs/troubleshooting.md).

## 1. Establish test-run time bounds (ignore prior runs)

**Disregard all log lines with timestamps before the start of this test run.** They are from prior runs or earlier sessions and will confuse the timeline.

Identify these three timestamps so you only analyze the current run:

| Marker | How to identify |
|--------|------------------|
| **Test start** | Beginning of `test-full-cycle.sh`. **Infer** from the **first** streamdeck-related restart in this run: in `journalctl-sunshine.log` and `journalctl-xorg.log`, look for the earliest `Starting streamdeck-sunshine.service` / `Starting streamdeck-xorg.service` (or equivalent "Started" lines) that correspond to Step 1 (install.sh). If the log bundle was created after a health-check failure or interrupt, use the first such restart before that. All lines **before** this timestamp are from prior runs — **disregard them**. |
| **Services up, awaiting input** | After Step 2 (health checks) and Step 3 prompt; script is at "Press Enter after you've completed the above steps...". Not explicitly logged. **Infer** as the time of the **last** "system ready" event before collection: e.g. last Sunshine "Listening" or service "active (running)" in `journalctl-sunshine.log` or `sunshine-logs/sunshine.log`, or last Xorg ready line in `journalctl-xorg.log`, before the collection timestamp. Events between this time and "Enter pressed" are from the manual test phase. |
| **Enter pressed** | When the user continued past the prompt; log collection started immediately after. **Use**: (1) the log directory name `logs/streamdeck-YYYYMMDD-HHMMSS` (e.g. `streamdeck-20260215-143803` → 2026-02-15 14:38:03), and (2) the line in `summary.txt`: `Generated: <date>`. Collected logs reflect system state at or just before this time. |

When building the timeline (section 4), **only include lines with timestamps in [test start, Enter pressed]**; treat "services up, awaiting input" as the start of the manual-test window.

## 2. Locate the log bundle

- If the user did not specify a path: use the **latest** `logs/streamdeck-*` directory (e.g. `logs/streamdeck-20260215-143803`). Prefer the run from the manual test step (later timestamp).
- If the user pasted a summary or path from the test output, use that directory.
- **Report output:** you will write the analysis report to `<LOG_DIR>/TROUBLESHOOTING-ANALYSIS.md` (see Output section below).

## 3. Identify bad behavior

- Read **`<LOG_DIR>/summary.txt`** first. It aggregates health checks, service status, recent errors, stream session (MoonDeckStream exit codes), port state, and MoonDeck Buddy.
- From the summary, list each **failure or warning** (e.g. "App exited with code [256]", "Sunshine is NOT binding UDP 47999", "Another instance of MoonDeckStream is already running", "Couldn't connect to pulseaudio").
- Treat these as the **bad behaviors** to explain; avoid chasing unrelated log noise.

## 4. Build a timeline

- Use the **time bounds** from section 1: include only lines with timestamps between **test start** and **Enter pressed**; disregard earlier lines.
- For each bad behavior, collect **timestamped** lines that lead up to it. Prefer:
  - **`sunshine-logs/sunshine.log`** — Sunshine startup, app launch, app exit, audio/encoder errors.
  - **`moondeckstream-stderr.log`** — MoonDeckStream/wrapper stderr (singleton, wrapper steps).
  - **`journalctl-sunshine.log`** — same events from systemd/journal.
  - **`moondeck-diagnostics.txt`** — Buddy/MoonDeck grep (another instance, port, errors).
- Order lines by time so the sequence of events is clear (e.g. "Sunshine executes MoonDeckStream → wrapper logs singleton cleanup → buddy.stream: Another instance... → App exited with code [256]").
- Include only lines that are **relevant** to the failure; omit routine startup/encoder-probe noise unless it contradicts a hypothesis.

## 5. Collect supporting evidence

- Use the **log bundle layout** from `collect-logs.sh` to know what exists:
  - **Summary / errors:** `summary.txt`
  - **Sunshine:** `sunshine-logs/sunshine.log`, `sunshine-logs/moondeckstream.log` (app stdout/stderr when launched by Sunshine), `sunshine-diagnostics.txt`
  - **MoonDeckStream / Buddy:** `moondeckstream-stderr.log`, `moondeckstream.log`, `moondeckbuddy.log`, `moondeck-diagnostics.txt`, `journalctl-moondeckbuddy.log`
  - **System:** `systemctl-*.status`, `journalctl-xorg.log`, `Xorg.99.log`, `versions.txt`
- For each bad behavior, cite **specific files and line ranges** (or short quotes) that support or contradict candidate causes.

## 6. Brainstorm root causes

- For each bad behavior, list **possible root causes** (e.g. MoonDeckStream exit 256: Qt singleton lock from previous run or different user; UDP not bound: Sunshine version or config not opening control ports; audio: PulseAudio/PipeWire not available to streamdeck user).
- Prefer causes that fit the **timeline** and the **evidence**; note if a cause would predict other log lines you don’t see (and adjust or drop it).

## 7. Validate with experiments (AGENTS.md)

- Do **not** assume system state. Use **targeted experiment scripts** to validate hypotheses:
  - Create or modify `scripts/experiment-*.sh` scripts for the current hypothesis (setup / run / teardown), document hypothesis and findings in the script, run with `sudo ./scripts/experiment-<name>.sh` when needed.
  - Remove or archive experiment scripts once the hypothesis is confirmed or discarded.
- Recommend **concrete next steps** (e.g. "Run `sudo ./experiment.sh` with step X to confirm that UDP binds only after a client connects" or "Add to collect-logs.sh: copy `/run/user/<uid>/qipc_*` listing for streamdeck and Buddy user").

## 8. Keep diagnostics in sync

- If the current bundle is **missing** logs or state that would have clarified the failure (e.g. per-user Qt IPC dirs, a new service, or a specific Sunshine sublog), **propose changes to `collect-logs.sh`** so the next run captures them. Follow the script’s existing patterns (sections, `log_info`, ownership fix for sudo).
- When a root cause or fix is confirmed, **update `docs/troubleshooting.md`**: add or adjust failure mode, cause, and remediation so the doc stays accurate and complete.

## Output: write report to the log run folder

**Create a report file in the log bundle you analyzed:** `<LOG_DIR>/TROUBLESHOOTING-ANALYSIS.md`

- Use the **same** `<LOG_DIR>` you used in section 2 (e.g. `logs/streamdeck-20260215-165714`). The report belongs to that run.
- Write the full analysis as markdown into that file. Include:
  - **Header:** `# Troubleshooting Analysis — <dirname>` (e.g. `streamdeck-20260215-165714`).
  - **Test-run time bounds:** the three markers from section 1 in a short table.
  - **Bad behaviors:** short list from summary.
  - **Timeline:** ordered, timestamped excerpts per behavior with file references (paths relative to the log dir or absolute).
  - **Evidence:** which files support/contradict which cause.
  - **Root cause hypotheses:** ranked by fit to evidence.
  - **Next steps:** specific experiment(s) (script + command) and any `collect-logs.sh` / `docs/troubleshooting.md` updates to apply.
- After writing the file, you may summarize the main findings in chat; the canonical record is the markdown report in the logs folder.
