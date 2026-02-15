# MoonDeck: How game "started" is detected (research)

This doc summarizes how MoonDeck (Steam Deck plugin) decides that a game has started, and why "Failed to launch app in time!" / "didn't start app in time" appears when the game never shows on the stream. Sources: MoonDeck and MoonDeck-Buddy GitHub repos, issue #41, and code inspection.

## Who shows the message?

The message **"Failed to launch app in time!"** comes from the **MoonDeck plugin** (Steam Deck), not from Moonlight. It is defined in MoonDeck's `lib/runnerresult.py` as `Result.AppLaunchFailed`. (User may see a variant like "didn't start app in time" depending on locale or UI.)

When this result is set, the plugin treats the launch as failed and runs cleanup (e.g. end stream), so the stream closes and Moonlight disconnects.

## Detection chain (Deck → Host)

1. **MoonDeck plugin (Deck)**  
   - After starting Moonlight and the MoonDeckStream app, it calls `MoonDeckAppLauncher.wait_for_app_to_be_launched()`.
   - That function **polls** Buddy on the host via `client.get_streamed_app_data()` once per second (or similar interval).
   - It waits until the response has `data["app_state"] == AppState.Running` and stays Running for a **stability** period (to ignore brief state flips from launchers).
   - Timeout: if `AppState.Running` is never seen within `launch_timeout` retries, it raises `RunnerError(Result.AppLaunchFailed)` → "Failed to launch app in time!".

2. **Buddy (host)**  
   - Implements the API that returns "streamed app data", including **app_state** (Stopped / Updating / Running).
   - Buddy gets "game is running" from **Steam** on the same machine. On Windows, logs show: "Running appID change detected (via global key)" and "App &lt;AppID&gt; 'running' value change detected: true". So Buddy observes Steam’s notion of which app is running (e.g. via Steam client API or a global key Steam updates).
   - On Linux, Buddy similarly tracks which Steam AppID is running; that state ultimately comes from Steam (e.g. "Add &lt;AppID&gt; to running list" in `gameprocess_log.txt`, and the same notion that produces "Adding process … for gameID" in logs).

3. **Steam (host)**  
   - When a game actually starts, Steam adds it to the running list and logs "Add &lt;AppID&gt; to running list" and "Adding process … for gameID". Buddy’s "running" state for that AppID reflects this.

## Why we see "Failed to launch app in time!" in our setup

- Buddy sends `steam://launch/&lt;AppID&gt;/dialog` to Steam (and logs "Started watching AppID").
- The game **never** starts on the host (e.g. launch not handed off to the Steam instance on :99, or that instance never starts the game). So Steam never adds the AppID to the running list.
- Buddy therefore never reports `AppState.Running` for that AppID.
- MoonDeck’s poller never sees Running and hits `launch_timeout` → sets `Result.AppLaunchFailed` → shows "Failed to launch app in time!" and ends the stream.
- So the **plugin (MoonDeck)** is the one closing the stream and showing the message; Moonlight then disconnects because the stream was ended.

## Relevant code references

| Component | What to look at |
|-----------|------------------|
| MoonDeck (plugin) | `defaults/python/lib/runner/moondeckapprunner.py`: `wait_for_app_to_be_launched()`, `TimedPooler`, `client.get_streamed_app_data()`, `AppState.Running`. |
| MoonDeck (plugin) | `defaults/python/lib/runnerresult.py`: `Result.AppLaunchFailed = "Failed to launch app in time!"`. |
| MoonDeck Buddy (host) | API that returns streamed app data / app_state; on Windows, logs "Running appID change detected (via global key)" and "App &lt;id&gt; 'running' value change detected". |
| Steam (host) | `gameprocess_log.txt`: "Add &lt;AppID&gt; to running list"; journal: "Adding process … for gameID". |

## Implications for our troubleshooting

- To fix "Failed to launch app in time!", the game must actually enter Steam’s "running" state on the host (so Buddy can report Running and MoonDeck can see it before timeout).
- That requires the game to start on the display we stream (:99), which brings us back to ensuring the launch is handled by the Steam instance on :99 (e.g. steam wrapper with `DISPLAY=:99` when streaming) and that Steam on :99 can start the game.

## Log coverage audit (where the failure can be pinpointed)

After a test run, `collect-logs.sh` produces `steam-game-launch.txt` in the log bundle. It is structured to answer:

| Question | Can we confirm? | How |
|----------|-----------------|-----|
| **Did Buddy tell Steam to start the game?** | Yes | Section 1: journal grep for `Executing: ... steam ... launch` and `Started watching AppID`. If present, Buddy ran `/usr/bin/steam steam://launch/<AppID>/dialog`. |
| **Did the game enter Steam's running list?** | Yes | Section 3 + 4: `gameprocess_log` has "Add <AppID> to running list" and journal has "Adding process … for gameID" when the game actually starts. If Buddy sent launch but these are missing, the game never started on the host. |
| **Is the game trying to start but slow (e.g. shaders)?** | Partially | Section 4 + 7: "Compiling shaders" and "Updating" in journal / shader_log indicate Steam began processing the launch; if we see those but no "Add to running list" before the stream ends, the launch was slow or stuck. |
| **Did Steam on :99 receive the launch request?** | No | We do not have per-display or per-process DISPLAY in logs. Buddy runs `steam` in the desktop session; that process may connect to the pre-launched Steam on :99 (singleton) or start another. We see Steam PIDs in section 2 but not which display each used. To know "Steam on :99 received it" would require Buddy or a wrapper to log DISPLAY when invoking steam, or capturing `/proc/<steam_pid>/environ` at launch time. |

**Conclusion:** We can confirm (1) Buddy sent the launch command and (2) whether the game ever entered the running list. We cannot distinguish "the steam command never reached the Steam instance on :99" from "Steam on :99 received it but did not start the game" without additional instrumentation (e.g. DISPLAY logged when Buddy runs steam).
