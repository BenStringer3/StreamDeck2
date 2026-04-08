# Troubleshooting

## install.sh: `BUDDY_USER not set`

The installer needs the **desktop user** (MoonDeck Buddy / Steam). With **`sudo ./install.sh`**, `sudo` sets `SUDO_USER` and that becomes `BUDDY_USER` by default. If you run the script as **root without `sudo`** (e.g. `su -`), `SUDO_USER` is empty — set the user explicitly: `BUDDY_USER=myuser ./install.sh`. See [installing.md](installing.md).

## Health checks or test-full-cycle fail

Logs are collected automatically (install and test-full-cycle both run `collect-logs.sh`). To capture logs manually, run `./collect-logs.sh`. The bundle includes:

- Sunshine and Xorg logs
- **MoonDeck Buddy:** `/tmp/moondeck*.log`, user journal for `moondeckbuddy.service` / `moondeckbuddy-gui-session.service`, and `~/.config/moondeckbuddy/settings.json`
- A grep summary for Buddy/MoonDeck (errors, port, listen, pair, etc.)
- **`steam-game-launch.txt`** — Buddy `steam://` / AppID watch lines plus Steam log greps (`gameprocess_log`, `console-linux`, `webhelper`) to see whether a game ever entered Steam's running list

Common issues:

1. **Xorg not starting**: Check NVIDIA driver and EDID configuration
2. **Sunshine can't see display**: Verify `DISPLAY=:99` is set correctly
3. **Encoder init fails**: Check NVENC availability with `nvidia-smi`
4. **Buddy not running**: Start with `systemctl --user start moondeckbuddy.service` (as your desktop user, not root). If autostart was never set up: `MoonDeckBuddy --enable-autostart` then `systemctl --user enable --now moondeckbuddy.service`. See [docs/installing.md](installing.md) for BUDDY_USER.
5. **First pairing**: Pairing and general behaviour are described in the [MoonDeck plugin docs](https://github.com/FrogTheFrog/moondeck); the plugin explicitly requires Buddy installed on the host

## No audio on stream (Moonlight silent)

See [audio-pipeline.md](audio-pipeline.md) for the full architecture. Quick checklist:

1. **TCP bridge health check:** `sudo -u streamdeck PULSE_SERVER=tcp:127.0.0.1:4713 pactl info`. If this fails, `pipewire-pulse` is not listening on TCP. Check that `~/.config/pipewire/pipewire-pulse.conf.d/10-tcp-localhost.conf` exists for BUDDY_USER and restart: `systemctl --user restart pipewire-pulse.service`. Re-run `sudo ./install.sh` to deploy the drop-in.
2. **Sunshine log says "Couldn't set default-sink: Access denied" / "Unable to initialize audio capture"**: The TCP drop-in must use `client.access = "unrestricted"`. Sunshine needs full graph access (load sink modules, set-default-sink) at stream start. Re-run `sudo ./install.sh` to deploy the updated drop-in, then `systemctl --user restart pipewire-pulse.service` as BUDDY_USER.
3. **Sunshine log says "Couldn't connect to pulseaudio: Access denied"**: The Sunshine service does not have `PULSE_SERVER=tcp:127.0.0.1:4713`, or step 1 fails. Re-run `sudo ./install.sh`.
4. **Sunshine connects but wrong sink**: `audio_sink` in `sunshine.conf` does not match where games send audio. Run `pactl list short sinks` and set `audio_sink` explicitly.
5. **`StreamDeck-Bridge` does not exist**: Only the "Steam Big Picture" app uses `PULSE_SINK=StreamDeck-Bridge`; if the sink is missing, Steam audio may fail or go elsewhere. Create the sink or remove `PULSE_SINK` from the app command.

## Moonlight connection issues

- Ensure Sunshine is running: `systemctl status streamdeck-sunshine`
- Verify pairing PIN matches
- **Firewall:** If Moonlight shows "Starting control stream establishment" then fails, or Sunshine logs "Initial Ping Timeout", open the Sunshine and Buddy ports (see **Firewall** below).
- Buddy (MoonDeck): default port **59999** (TCP).

## Firewall (Initial Ping Timeout / control stream establishment)

**First check:** If the test summary **Post-connection port state** shows `UDP 47999: (none)` (and other Sunshine UDP as (none)), Sunshine never bound those ports because the **app (MoonDeckStream) exited** — fix the app exit (see "Desktop streams but MoonDeckStream fails"); opening firewall will not help.

Sunshine needs the following ports open on the **host**:

| Port  | Protocol | Purpose        |
|-------|----------|----------------|
| 47984 | TCP      | Web UI (pairing) |
| 47989 | TCP      | Control        |
| 47990 | TCP      | Web UI (HTTPS) |
| 47998 | UDP      | Streaming      |
| 47999 | UDP      | Streaming      |
| 48000 | UDP      | Streaming      |
| 48002 | UDP      | Streaming      |
| 48010 | TCP+UDP  | Streaming      |
| 5353  | UDP      | mDNS/Avahi     |

**Buddy (MoonDeck):** 59999 TCP.

```bash
# ufw
ufw allow 47984/tcp
ufw allow 47989/tcp
ufw allow 47990/tcp
ufw allow 47998/udp
ufw allow 47999/udp
ufw allow 48000/udp
ufw allow 48002/udp
ufw allow 48010/tcp
ufw allow 48010/udp
ufw allow 5353/udp
ufw allow 59999/tcp
ufw reload

# firewalld
firewall-cmd --permanent --add-port=47984/tcp --add-port=47989/tcp --add-port=47990/tcp
firewall-cmd --permanent --add-port=47998/udp --add-port=47999/udp --add-port=48000/udp --add-port=48002/udp --add-port=48010/udp --add-port=5353/udp
firewall-cmd --permanent --add-port=48010/tcp --add-port=59999/tcp
firewall-cmd --reload
```

## Desktop streams but MoonDeckStream fails (Error 11 / Initial Ping Timeout)

If you can stream **Desktop** (or other Sunshine apps) with Moonlight but launching **MoonDeckStream** gives Error 11 or "Initial Ping Timeout", the cause is **MoonDeckStream exiting** shortly after Sunshine starts it. When the app exits, Sunshine tears down the session and **does not bind the UDP control ports** (47998, 47999, etc.). Moonlight then times out.

**Confirm root cause:** In the test summary, **Post-connection port state** will show `UDP 47999: (none)`. That means Sunshine never established the session — the app exited, not a firewall block.

**TMPDIR stripped by sudo (exit 256 + Error 11):** If `journalctl -u streamdeck-sunshine` shows `sorry, you are not allowed to set the following environment variables: TMPDIR`, sudo is stripping TMPDIR. MoonDeckStream then uses a different Qt temp path than Buddy → "Failed to read ENV regex from shared memory" → no Steam launch → app exits 256 → Error 11. **Fix:** Re-run `sudo ./install.sh` (adds TMPDIR to `env_keep` in sudoers).

**Diagnosing by exit code:**

1. **Exit 15 (SIGTERM):** Check `moondeckstream-stderr.log` — if it shows "Another instance of MoonDeckStream is already running!", see exit 256 below.
2. **Exit 256 (missing env):** MoonDeckStream only stays running if it sees an env var matching `SUNSHINE.*` or `APOLLO.*`. The install passes `SUNSHINE_LAUNCHED=1` explicitly. Re-run `sudo ./install.sh` to deploy the latest `apps.json`.
3. **"Another instance already running":** MoonDeckStream's singleton uses QSharedMemory + QSystemSemaphore. On SIGTERM it calls `quick_exit()` without running destructors, so System V IPC segments persist. The wrapper at `/usr/local/bin/MoonDeckStream` handles this: it kills stale PIDs, removes orphaned Qt IPC key files, and falls back to `ipcrm` for orphaned shm/sem segments. **Manual recovery:** run `ipcs -m` as the Buddy user, find segments with **nattch** 0, and remove with `ipcrm -m <shmid>`. For semaphores: `ipcs -s` then `ipcrm -s <semid>`.
4. **Check MoonDeckStream logs:** In the collected log dir, look at `moondeckstream-stderr.log`, `sunshine-logs/moondeckstream.log`, and `moondeck-diagnostics.txt`.
5. **Buddy reachable:** Buddy must be running and reachable (`https://localhost:59999/apiVersion`). See [Buddy troubleshooting](https://github.com/FrogTheFrog/moondeck-buddy/wiki/Troubleshooting).

## MoonDeckStream starts then closes (exit 134)

If the stream starts and then closes immediately with **exit 134** (SIGABRT):

1. MoonDeckStream uses Qt shared memory/semaphore to talk to Buddy. If MoonDeckStream runs as the stream user while Buddy runs as your desktop user, the process gets "permission denied" on the semaphore and aborts. **Fix:** Re-run `install.sh` — Sunshine must launch MoonDeckStream as the same user as Buddy (via sudo).
2. With `wait-all: false`, when MoonDeckStream exits, Sunshine ends the stream.

## Black screen with cursor, no Steam GUIs, stream then exits

You see the stream (black screen + mouse pointer) for several seconds, no Steam/Big Picture appears, then the stream ends.

**Root cause:** MoonDeckStream needs to read the "ENV regex" from Buddy via **Qt shared memory**. The shared-memory key path depends on `QDir::tempPath()` (i.e. TMPDIR). If Buddy and MoonDeckStream use different TMPDIR values, they access different IPC segments and MoonDeckStream logs "Failed to read ENV regex from shared memory!".

**What to do:**

1. **Confirm:** Check `moondeckstream.log` or `moondeck-diagnostics.txt` for `Failed to read ENV regex from shared memory!`.
2. **Buddy running:** `systemctl --user is-active moondeckbuddy.service` (as your desktop user).
3. **TMPDIR fix:** Install sets `TMPDIR=/tmp` for MoonDeckStream in Sunshine's app command and adds `TMPDIR=/tmp` to the Buddy service override. Re-run `sudo ./install.sh`. If you installed before that change, add `Environment=TMPDIR=/tmp` to `~/.config/systemd/user/moondeckbuddy.service.d/override.conf`, then `systemctl --user daemon-reload && systemctl --user restart moondeckbuddy.service`.
4. **Workaround:** Use the **"Steam Big Picture"** Sunshine app to stream Big Picture on `:99` without MoonDeckStream/Buddy IPC.

## Steam/game on physical monitor; Deck shows black screen with cursor

Steam (and the game) start correctly, but they appear on your **physical monitor**. Sunshine captures display :99, which has nothing on it.

**Root cause:** Buddy launches Steam in the desktop session instead of on `:99`. The install configures Buddy's `steam_exec_override` to `/usr/local/bin/steam-headless` and captures `DISPLAY=:99` via `env_capture_regex`.

**What to do:**

1. **Confirm:** Check `moondeck-diagnostics.txt` for `SDL_VIDEODRIVER='wayland'` or similar right after "Stream started" — that indicates Steam ran in the desktop session.
2. **Fix:** Re-run `sudo ./install.sh`. Check that `env_capture_regex` includes `DISPLAY` in `~/.config/moondeckbuddy/settings.json`. Restart Buddy after any settings change.

## Steam Big Picture on Deck but game never launches

Steam Big Picture appears on the stream, but the game does not start and the stream eventually closes.

**Root cause (three layers, any one blocks the launch):**

1. **GLX vendor mismatch.** The Sunshine service sets `__GLX_VENDOR_LIBRARY_NAME=nvidia` (for NVENC). Buddy captures this and passes it to Steam. But Xorg `:99` (dummy driver) only provides `DRISWRAST` (Mesa software GLX). NVIDIA's client-side GLX can't negotiate with Mesa's server-side GLX, so Steam's CEF compositor fails: `CreateOutputWindow: failed to acquire a gl context`. In degraded mode, CEF silently drops all game launch commands.

2. **Launch-options dialog blocks.** Buddy sends `steam://launch/<AppID>/dialog`. For games with multiple launch configs (e.g. Satisfactory: with/without EAC), both `/dialog` and `rungameid` show a config selection dialog. On the dummy display, CEF can't render this dialog (`X_PutImage BadMatch`), so the launch blocks silently. Games without multiple configs (e.g. Horizon Forbidden West) are unaffected and launch normally.

3. **Shader cache dialog blocks.** Games with a pending Vulkan shader pre-cache download trigger a "Processing Vulkan Shaders" progress dialog during the launch pipeline (`GameAction … ProcessingShaderCache waiting for user response`). On the headless display CEF can't render this dialog, so the launch hangs indefinitely. This affects any game whose shader cache was not fully downloaded — check `~/.local/share/Steam/logs/content_log.txt` for `update started : download 0/<N>` with a non-zero N and `result Suspended`.

**Fix:** Re-run `sudo ./install.sh`. The `steam-headless` wrapper (`/usr/local/bin/steam-headless`):

- **Unsets `__GLX_VENDOR_LIBRARY_NAME` and `__NV_PRIME_RENDER_OFFLOAD`** so Mesa's GLX matches the swrast server. Games use Vulkan (Proton/DXVK), not GLX.
- **Rewrites `steam://launch/<AppID>/dialog` → `steam://launch/<AppID>/0`** to select the first (default) launch config directly, bypassing both the dialog and CEF rendering requirements.
- **Passes `-noshaders`** to disable Steam's shader manager, preventing the `ProcessingShaderCache` step from blocking on an unrenderable progress dialog. Games still compile shaders at runtime via DXVK's pipeline cache — only the pre-compiled download cache is skipped, which may cause minor first-run stuttering.

The install also sets Buddy's `steam_exec_override` to `/usr/local/bin/steam-headless`, expands `env_capture_regex`, and removes the MoonDeckStream wrapper's Steam pre-launch. After install, restart Buddy: `systemctl --user restart moondeckbuddy.service`.

**Note:** The `/0` config always selects the first launch option. If a user prefers a non-default config (e.g. "Launch without Anti-Cheat"), they must set it as the default in Steam or configure the AppID-specific config number.

**Diagnostic steps:**

1. Check **steam-game-launch.txt** sections 1-6 in the log bundle. If section 1 shows `Started watching AppID` but sections 2-3 show no `Adding process`, the game never launched.
2. Check **section 5** (`console_log.txt` GameAction steps) for the last `LaunchApp changed task to` line. If it ends at `ProcessingShaderCache waiting for user response`, the shader cache dialog blocked the launch.
3. Check `webhelper.txt` for `BadMatch` / `X_PutImage` errors — indicates CEF can't render on the dummy driver.
4. Check `content_log.txt` for `AppID <N> update started` with incomplete download — a suspended shader cache download triggers the blocking dialog.

**MoonDeck "Failed to launch app in time!":** This message is from the **MoonDeck plugin** (Steam Deck), not Moonlight. MoonDeck polls Buddy for the game's app state; if the game never enters Steam's "running" list, MoonDeck hits its launch timeout and ends the stream. Root cause: the game never started on the host (see above).

## Steam Deck trackpad/mouse moves the PC desktop cursor

Moonlight client input (trackpad, mouse, keyboard) from the Steam Deck leaks into the PC desktop session — moving the PC cursor, typing on the PC, etc. The reverse (PC mouse on the stream) does not happen.

**Root cause:** systemd-logind manages input devices tagged with `seat`. It opens them as root and passes file descriptors to the desktop compositor (Hyprland) via `TakeDevice`, completely bypassing file permissions and ACLs. Sunshine's virtual passthrough devices (`Mouse passthrough`, `Keyboard passthrough`, etc.) inherit the `seat` tag from systemd's `70-seat.rules` unless our udev rules explicitly remove it.

**Diagnose:** In the test summary / `input-pipeline-summary.txt`:
- `FAIL: Desktop has Sunshine input devices open (trackpad moves PC cursor)` confirms the leak.
- Run `udevadm info -q all /sys/devices/virtual/input/inputN` on the parent of a passthrough event device. If `TAGS` or `CURRENT_TAGS` contain `:seat:`, this is the cause.
- `lsof /dev/input/eventN` showing `Hyprland` (or your compositor) confirms the fd leak.

**Fix:** Re-run `sudo ./install.sh`. The udev rules (`85-streamdeck-sunshine-input-isolation.rules`) must include both `TAG-="seat"` and `TAG-="uaccess"`, and must run at priority > 73 (after systemd's `71-seat.rules` and `73-seat-late.rules`). After install, restart Sunshine: `sudo systemctl restart streamdeck-sunshine`. Start a new Moonlight session.

**If the issue persists after rule update:** The compositor retains open file descriptors from before the rule change. Restarting Sunshine destroys and recreates the uinput devices, forcing logind to re-evaluate. If still leaking, verify with `udevadm info` that the `seat` tag is actually removed from the parent input device (not just the child event device).

## Resolution / scaling (black borders, wrong size)

Set Moonlight display resolution to native where possible. Be aware of external display being primary on the Deck.
