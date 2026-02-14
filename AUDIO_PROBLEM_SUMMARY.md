# Audio Problem Summary

## What you see

- **Symptom**: No audio when streaming games (e.g. Horizon Forbidden West) from Linux to Steam Deck via Sunshine + Moonlight. Video is fine.
- **Log line**: Sunshine reports:  
  `Couldn't connect to pulseaudio: Access denied` → `Unable to initialize audio capture. The stream will not have audio.`

---

## Root cause (why Sunshine has no audio)

1. **Sunshine runs as user `streamdeck`** (systemd service, no desktop session).
2. **Steam/games run as user `__BUDDY_USER__`** (needed for Steam library under `/home/__BUDDY_USER__`).
3. **Game audio goes to `__BUDDY_USER__`’s audio stack**: PipeWire (Pulse compat) in `__BUDDY_USER__`’s session, socket under `/run/user/1000/`.
4. **Sunshine needs to capture that playback**, but it runs as `streamdeck` and has no access to `__BUDDY_USER__`’s session:
   - Cannot use `__BUDDY_USER__`’s Pulse/PipeWire socket (per-user, cookie/auth).
   - Cookie sharing was tried: **failed** (PipeWire still denies; and PA needs write under `/run/user/1000/pulse` which `streamdeck` cannot do).
   - Direct cross-user Pulse/PipeWire access is not viable without opening security holes.

So: **Sunshine (streamdeck) and game audio (__BUDDY_USER__) are in different users’ audio sessions**, and Linux audio does not allow that cross-user capture by default.

---

## What was tried (from docs and experiments)

| Approach | Result |
|----------|--------|
| Share PulseAudio cookie with `streamdeck` | **Failed** – still “Access denied”; PipeWire uses more than cookie; PA also needs write in `__BUDDY_USER__`’s runtime dir. |
| Fix `/run/user/1000/pulse` permissions / cross-user Pulse | **Not pursued** – security and complexity. |
| ALSA direct (add `streamdeck` to `audio`, Sunshine uses ALSA) | **Incomplete** – ALSA alone has no “monitor” of desktop playback; need a loopback path. |
| **ALSA loopback bridge** | **Chosen** – route `__BUDDY_USER__`’s audio into ALSA loopback; `streamdeck` captures from loopback and feeds its own Pulse; Sunshine captures from that. |

---

## Intended solution (ALSA loopback bridge)

Design:

1. **Steam/games** (__BUDDY_USER__): Output to a **PipeWire null-sink** `StreamDeck-Bridge` (`PULSE_SINK=StreamDeck-Bridge` in apps).
2. **audio-bridge** (runs as __BUDDY_USER__): Capture from `StreamDeck-Bridge.monitor` → `pw-record | aplay` → **ALSA loopback** (snd-aloop) playback side.
3. **streamdeck-pipewire**: Headless PipeWire instance for `streamdeck` in `/run/streamdeck-audio`, so Sunshine has a Pulse server to talk to.
4. **audio-capture-bridge** (runs as streamdeck): Capture from **ALSA loopback** capture side → feed into `streamdeck`’s Pulse sink `StreamDeck-Capture`.
5. **Sunshine** (streamdeck): Configured with `audio_sink = StreamDeck-Capture` and captures from that sink’s monitor.

So: **__BUDDY_USER__’s game audio → PipeWire null-sink → ALSA loopback (kernel) → streamdeck’s PipeWire sink → Sunshine.** No cross-user Pulse socket access.

---

## Implementation status and possible issues

- **Implemented**: `install.sh` adds `streamdeck` to `audio`, loads `snd-aloop`, installs `audio-bridge.sh`, `audio-capture-bridge.sh`, `streamdeck-audio-bridge.service`, `streamdeck-audio-capture.service`, `streamdeck-pipewire.service`; apps use `PULSE_SINK=StreamDeck-Bridge`; Sunshine uses `audio_sink = StreamDeck-Capture`.
- **Subdevice mismatch**: Experiments (`experiment-pw-loopback-bridge.sh`, `experiment-aloop-subdevice.sh`, `AUDIO_IMPLEMENTATION_PLAN.md`) say **use ALSA loopback subdevice 7** so that PipeWire’s auto-managed use of **subdevice 0** does not conflict with the bridge. The current **scripts use subdevice 0** (`audio-bridge.sh`, `audio-capture-bridge.sh`). If PipeWire has already taken subdevice 0 on the loopback card, the bridge and capture may conflict or see no/silent data. **Worth changing both scripts to subdevice 7** and re-testing.
- **Early finding vs current setup**: `AUDIO_FINDINGS_SUMMARY.md` once reported “snd-aloop not available in kernel”; on Arch it usually is. If your kernel has it, the bridge path is valid; if not, the bridge cannot work until the module is available.
- **Dependency order**: Audio bridge requires **__BUDDY_USER__’s session** (user@1000) so PipeWire and the null-sink exist. If you boot headless or before `__BUDDY_USER__` is logged in, the bridge will fail until that session is up.
- **Capture bridge bug**: `audio-capture-bridge.sh` calls `log_warn` which is not defined (only `log_info` and `log_err` exist); if that branch runs, the script can fail.

---

## Experiments reference

- **experiment-audio-access.sh** – Baseline Pulse/cookie access; cookie sharing test (failed).
- **experiment-audio-pipewire.sh** – PipeWire vs Pulse, socket access, ALSA, Sunshine config.
- **experiment-audio-alsa-loopback-bridge.sh** – Proves ALSA loopback play (__BUDDY_USER__) → capture (streamdeck) works; Test B (direct ALSA) on a dedicated subdevice; Test A (PipeWire → loopback) showed conflict on subdevice 0.
- **experiment-aloop-subdevice.sh** – Use a dedicated subdevice (e.g. 7) to avoid PipeWire subdevice 0.
- **experiment-pw-loopback-bridge.sh** – Null-sink + `pw-record | aplay` to subdevice 7; streamdeck captures from subdevice 7; **passed**.
- **experiment-aloop-timing.sh** – Timing/linkage of capture vs playback on the loopback cable.

---

## Short checklist when audio still fails

1. **__BUDDY_USER__ logged in** (graphical or user session) so `/run/user/1000` and PipeWire exist.
2. **snd-aloop loaded**: `lsmod | grep snd_aloop`; `cat /proc/asound/cards` shows Loopback.
3. **Services up**: `streamdeck-audio-bridge`, `streamdeck-pipewire`, `streamdeck-audio-capture`, then `streamdeck-sunshine`; check `journalctl -u streamdeck-audio-bridge.service -u streamdeck-audio-capture.service`.
4. **Subdevice**: Consider switching both bridge scripts from subdevice **0** to **7** to match experiments and avoid PipeWire conflict.
5. **Sunshine config**: `audio_sink = StreamDeck-Capture` in Sunshine config (for streamdeck user); apps launched by Sunshine use `PULSE_SINK=StreamDeck-Bridge`.
6. **Diagnostics**: `./collect-logs.sh` and inspect `sunshine-diagnostics.txt` and audio-bridge/capture journal output; grep for “audio” and “pulse”.
