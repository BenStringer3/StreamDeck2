# ENV regex shared memory — research and experiment

## Problem

MoonDeckStream logs **"Failed to read ENV regex from shared memory!"** when started by Sunshine on `DISPLAY=:99`. It then never launches Steam, so the stream shows a black screen with cursor only. When MoonDeckStream runs in the same desktop session as Buddy, the log shows **"Got the following ENV regex from Buddy: …"** and Steam is launched.

## Hypothesis (pre-experiment)

Buddy (desktop session) and MoonDeckStream (Sunshine on `:99`) use **Qt shared memory** to pass the ENV regex. The **native key** might depend on session/display (e.g. DISPLAY, XDG_SESSION_ID), so MoonDeckStream on `:99` would not see the segment Buddy created on the desktop.

## Experiment results (2026-02-15)

**Run:** `sudo ./scripts/experiment-env-regex.sh` (Phase A: DISPLAY=:99, Phase B: DISPLAY=:0).

**Outcome:** **Both phases failed** to read ENV regex (“Failed to read ENV regex from shared memory!”). No difference between :99 and :0 in this setup.

**Conclusion:** No smoking gun. DISPLAY alone is not the differentiator under the conditions we tested.

## Revised hypothesis

Given both phases failed:

1. **Timing / trigger:** Buddy may **only create or write** the ENV regex segment when it detects that a stream has started (e.g. when Sunshine has already launched the app and/or a client has connected). In the experiment we ran MoonDeckStream in isolation with no client; Buddy was idle and may never have written the segment. So the “Got the following ENV regex” seen in earlier logs (e.g. 15:02) might have been from a run where Buddy had already reacted to a stream start in that session.

2. **Session context:** Even with `DISPLAY=:0`, the process was still `sudo -u __BUDDY_USER__` (child of root/sudo), not a process started inside the user’s graphical session. So it may not share `XDG_SESSION_ID`, Wayland socket, or other session-specific state that Buddy uses to derive the key or to decide when to write. So “DISPLAY=:0” does not necessarily put us in the same IPC context as Buddy.

3. **Wayland:** If the host is Wayland, Buddy runs in the compositor’s session; `:0` might be XWayland and not the session where Buddy creates the segment. So Phase B still wouldn’t match Buddy’s context.

**Implication:** The real-stream failure (black screen, no Steam on :99) could still be due to key/session mismatch when Sunshine launches MoonDeckStream — but we can’t conclude that from DISPLAY alone. The more plausible refinement is: **Buddy writes the ENV regex segment only when it considers a stream to have started** (or when MoonDeckStream registers from the “right” session). Under Sunshine, that moment and the segment key might not align with the :99-launched MoonDeckStream.

## Source-code findings (MoonDeck Buddy repo)

**When is the ENV regex segment created/filled?**

- **Buddy** writes it **once at startup**, not when a stream starts. In `src/buddy/main.cpp` (`mainLoop()`), right after starting the heartbeat and before starting the HTTP server:
  - `utils::ShmSerializer env_regex_serializer{app_meta.getSharedEnvRegexKey()};`
  - `env_regex_serializer.write(app_settings.getEnvCaptureRegex());`
- So the segment exists whenever Buddy is running. The “Buddy only writes when stream starts” hypothesis is **wrong**; the segment is written at Buddy startup.

**Key identity:**

- Both apps use the same logical key from `shared::AppMetadata`: `getSharedEnvRegexKey()` returns the literal string `"MoonDeck_EnvRegex_Key"` (see `src/lib/shared/appmetadata.cpp`).
- In `src/lib/utils/shmserialization.cpp`, that string is hashed with SHA1 and the **hex string** is passed to `QSharedMemory` (e.g. `QSharedMemory(generateKeyHash(key))`). So both Buddy (writer) and MoonDeckStream (reader) use the same key string and the same hash; the only way they can end up with different System V keys is if **Qt’s native key path** differs between the two processes.

**When does MoonDeckStream read?**

- In `src/stream/main.cpp`, immediately after the singleton guard and log init: it creates `ShmDeserializer{app_meta.getSharedEnvRegexKey()}`, calls `read()`, and logs either “Got the following ENV regex from Buddy” or “Failed to read ENV regex from shared memory!”. So the read happens at MoonDeckStream startup, and the segment must already exist (written by Buddy at its startup).

## How session/display can affect the key (Qt and Linux)

**Qt System V key path:**

- Qt docs: [Native IPC Keys](https://doc.qt.io/qt-6/native-ipc-keys.html). For System V, the native key is a **file path**. “If the input was already absolute, they will return their input unchanged. Otherwise, they will **prepend a suitable path** where the application usually has permission to create files in.”
- In Qt 5 `qsharedmemory.cpp`, for Unix (non–POSIX-IPC) the path is **`QDir::tempPath() + '/' + result`** (where `result` is derived from the key string). So the System V key depends on **`QDir::tempPath()`**.
- On Linux, `QDir::tempPath()` typically uses the **`TMPDIR`** environment variable if set, otherwise falls back to `/tmp` (e.g. `P_tmpdir`). So if Buddy runs with one `TMPDIR` (e.g. from the graphical session) and MoonDeckStream runs with another (or unset), the two processes use **different file paths** for the same logical key → **different `ftok()` values** → different System V shared-memory keys → MoonDeckStream cannot see the segment Buddy created.

**DISPLAY, XDG_SESSION_ID, Wayland:**

- The MoonDeck Buddy/Stream source does **not** use DISPLAY, XDG_SESSION_ID, or Wayland socket to build the shared-memory key. The key is the fixed string `"MoonDeck_EnvRegex_Key"` (then hashed). So these affect the IPC **only indirectly**: the **session** in which Buddy runs may set **TMPDIR** (e.g. to `$XDG_RUNTIME_DIR` or a session-specific temp dir). When Sunshine launches MoonDeckStream with `sudo -u <user>` and only passes a limited set of variables (e.g. `DISPLAY`, `XDG_RUNTIME_DIR`, `DBUS_SESSION_BUS_ADDRESS`), it often does **not** pass **TMPDIR**. So Buddy (in the desktop session) might use `TMPDIR=/run/user/1000` (or similar), while MoonDeckStream uses the default `/tmp` → different Qt key paths → read fails.

**Conclusion:** The most likely cause of “Failed to read ENV regex” when MoonDeckStream is started by Sunshine is **TMPDIR mismatch**: Buddy and MoonDeckStream use different `QDir::tempPath()` values, so they use different System V key files and different shared-memory segments. **Mitigation:** When configuring Sunshine’s launch command for MoonDeckStream, ensure **TMPDIR** is set the same as in the Buddy user’s session (e.g. `TMPDIR=/tmp` for both, or pass the session’s `TMPDIR`/`XDG_RUNTIME_DIR` into the Sunshine launch env so Qt uses the same path).

## Web / upstream

- **MoonDeck Buddy:** [Sunshine setup](https://github.com/FrogTheFrog/moondeck-buddy/wiki/Sunshine-setup), [Troubleshooting](https://github.com/FrogTheFrog/moondeck-buddy/wiki/Troubleshooting) — no mention of shared memory or DISPLAY for the stream helper.
- **Qt 6 native IPC keys:** [doc.qt.io/qt-6/native-ipc-keys.html](https://doc.qt.io/qt-6/native-ipc-keys.html) — System V key is file-path based; “prepend a suitable path” for relative keys can vary by environment; Qt 5 uses `QDir::tempPath()` for that path.
- **Isolation:** The key string is fixed; only the **temp path** (TMPDIR / QDir::tempPath()) can differ between Buddy and MoonDeckStream, leading to different ftok() keys.

## Experiment

**Script:** `scripts/experiment-env-regex.sh`

**What it does:**

1. Ensures Buddy is running; stops any MoonDeckStream.
2. **Phase A:** Runs MoonDeckStream with `DISPLAY=:99` (Sunshine-like env) for ~5s, then SIGTERM. Captures the new lines written to `/tmp/moondeckstream.log` and checks for “Failed to read ENV regex” vs “Got the following ENV regex”.
3. **Phase B:** Same, but with `DISPLAY=:0` (or a desktop DISPLAY you pass as the first argument). This approximates “same display as Buddy” when the host uses X11; on Wayland, `:0` is often XWayland.
4. Writes a short conclusion in `logs/experiment-env-regex-<timestamp>/findings.txt`.

**Run:**

```bash
sudo ./scripts/experiment-env-regex.sh          # Phase B uses DISPLAY=:0
sudo ./scripts/experiment-env-regex.sh :0      # same, explicit
sudo ./scripts/experiment-env-regex.sh ''      # skip Phase B
```

**Interpretation:**

- **A fails to read, B gets regex:** Supports the hypothesis that the shared-memory key (or the path Qt chooses) differs by display/session.
- **Both fail (observed 2026-02-15):** No smoking gun. See **Revised hypothesis** above: Buddy writes at startup (see Source-code findings); failure is likely TMPDIR / QDir::tempPath() mismatch, and/or `sudo -u __BUDDY_USER__ DISPLAY=:0` does not match Buddy’s session (e.g. XDG_SESSION_ID, Wayland).
- **A gets regex:** Hypothesis not supported for this setup.

**Next steps (to narrow it down):** (1) During a real stream from Moonlight, check Buddy logs for “Stream started” and whether ENV regex is written at that time. (2) Run MoonDeckStream **manually from a terminal inside the desktop session** (same session as Buddy) and see if that run gets “Got the following ENV regex” in `/tmp/moondeckstream.log`.

## References

- `docs/troubleshooting.md` — “Black screen with cursor, no Steam GUIs”
- Qt 6: Native IPC Keys (System V, file path, `platformSafeKey` / legacy key)
