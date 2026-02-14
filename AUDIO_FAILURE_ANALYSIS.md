# Audio Pipeline Failure Analysis (test-full-cycle 2026-02-14)

## Failure chain (from logs)

1. **Health check fails**: `streamdeck-audio-bridge.service is not active`
2. **Root cause**: `streamdeck-audio-bridge.service` exits with code 1 immediately on start.
3. **Script error** (from `journalctl-audio-bridge.log`):
   ```
   ERROR: ALSA playback device not usable: hw:3,0,7
   ERROR: Try: aplay -l ; cat /proc/asound/cards ; ls -la /dev/snd
   ```
4. **Where it fails**: In `audio-bridge.sh`, the preflight check runs:
   `aplay -D hw:3,0,7 --dump-hw-params -f S16_LE -r 48000 -c 2 </dev/null`
   and the script treats non-zero exit as "device not usable" and exits. The actual ALSA error is not logged (stderr was discarded).

## System state at log collection

- **ALSA**: Card 3 = Loopback (snd-aloop loaded). Cable 0 substream 7 shows "valid: 2, running: 2" (capture side active — likely from a previous or parallel capture-bridge run).
- **__BUDDY_USER__'s PipeWire**: Has `alsa_output.platform-snd_aloop.0.analog-stereo` and `alsa_input.platform-snd_aloop.0.analog-stereo` — i.e. **subdevice 0** is used by PipeWire. Subdevice 7 is intended to be free for the bridge.
- **Timing**: The failure started 2026-02-14 14:16:26; before that (Feb 13) the bridge was running successfully ("Playing raw data..."). So something changed (e.g. reboot, or card order changed).

## Downstream effects

- Because the audio-bridge never starts, no audio is fed into the ALSA loopback. The capture-bridge (when it runs) would read silence. So the **first failure point** is the audio-bridge aplay check.

## Hypothesis

**H1**: When `audio-bridge.sh` runs under the systemd unit (User=__BUDDY_USER__, only `XDG_RUNTIME_DIR=/run/user/1000`), `aplay -D hw:3,0,7 --dump-hw-params ...` fails with a non-zero exit. The real ALSA/libasound error is unknown because stderr was not captured.

**Possible causes**:

- **H1a** PipeWire (__BUDDY_USER__'s session) has the loopback card open (subdevice 0). On some setups the driver or a policy might block another process (same user) from opening a different subdevice, or the card might be reported "busy".
- **H1b** In the minimal systemd environment (no DISPLAY, no DBUS_SESSION_BUS_ADDRESS) ALSA or Pulse/plugin layer behaves differently and the open fails (e.g. permission or device visibility).
- **H1c** The loopback card index or subdevice is wrong at the moment the service starts (e.g. card order differs at boot so "first Loopback" is not card 3, or subdevice 7 is reserved by WirePlumber in a newer config).

**Experiment**: Run the same aplay check as user `__BUDDY_USER__` with the **exact** environment the service has (only `XDG_RUNTIME_DIR=/run/user/1000`), capture full stderr/stdout and exit code. Compare with running as __BUDDY_USER__ in a full login session. If it fails only in the minimal env, the cause is environment/session-related. If it fails in both, the cause is device/card/subdevice or driver.

See `experiment-audio-bridge-aplay.sh`.
