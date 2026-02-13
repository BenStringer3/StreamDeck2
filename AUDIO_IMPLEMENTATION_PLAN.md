# Audio Implementation Plan: ALSA Loopback Bridge

## Summary

This document describes the implementation plan for fixing audio streaming in the Stream Deck setup.
The solution uses an ALSA loopback device (`snd-aloop`) as a "narrow bridge" between __BUDDY_USER__'s audio
(where Steam runs) and streamdeck's audio capture (where Sunshine runs).

## Problem Statement

- **Sunshine runs as `streamdeck` user** and needs to capture audio
- **Steam runs as `__BUDDY_USER__` user** (to access game library) and outputs audio to __BUDDY_USER__'s PipeWire session
- **Cross-user audio access fails**: streamdeck cannot access `/run/user/1000/pulse` or PipeWire sockets
- **Goal**: Route Steam audio to a device that streamdeck can capture without cross-user socket access

**Hard prerequisite (explicit)**: The bridge depends on __BUDDY_USER__'s PipeWire/PulseAudio-compat session being
active (i.e., `/run/user/1000/` exists and `pactl info` works as __BUDDY_USER__). This is not a best-effort
optimization: if __BUDDY_USER__'s session isn't up, the bridge cannot function and the install/health checks
should fail with a clear next step.

## Proven Solution

Experiments have verified this audio path works:

```
Steam (__BUDDY_USER__) → PipeWire null-sink "StreamDeck-Bridge" 
            → pw-record (__BUDDY_USER__) | aplay (__BUDDY_USER__) → ALSA loopback hw:N,0,7
            → ALSA capture hw:N,1,7 → arecord (streamdeck) → Sunshine
```

Key findings from experiments:
- **Test B passed**: Direct ALSA play/capture on subdevice 7 works cross-user
- **Test A failed initially**: PipeWire's auto-managed subdevice 0 conflicts with arecord
- **pw-loopback bridge passed**: Creating a null-sink and bridging via `pw-record|aplay` to subdevice 7 works

## Implementation Components

### 1. Kernel Module: snd-aloop

**Purpose**: Provides virtual ALSA loopback devices for audio routing.

**Files to create/modify**:
- `/etc/modules-load.d/snd-aloop.conf` - Load module at boot

**Module parameters**: None needed; defaults provide 8 subdevices which is sufficient.

### 2. Systemd Service: streamdeck-audio-bridge.service

**Purpose**: Runs the `pw-record | aplay` bridge that routes audio from the PipeWire null-sink
to the ALSA loopback device.

**Runs as**: `__BUDDY_USER__` user (needs access to __BUDDY_USER__'s PipeWire session)

**Dependencies**: 
- Requires __BUDDY_USER__'s PipeWire/user session to be running (explicit hard dependency; fail-fast if absent)
- Should start when streamdeck-sunshine starts

**Files to create**:
- `systemd/streamdeck-audio-bridge.service`
- `scripts/audio-bridge.sh` - Bridge script with health checks

### 3. PipeWire Null-Sink Configuration

**Purpose**: Creates a persistent "StreamDeck-Bridge" sink that Steam can output to.

**Options**:
- A) Create via `pactl load-module` in the bridge service (simpler, but transient)
- B) Create via PipeWire config file (persistent across reboots)

**Recommendation**: Option A for simplicity; the bridge service creates the sink on start.

**Idempotency note**: the service must treat sink creation as an idempotent step and should validate
that the sink's *name* matches exactly (avoid substring matches) before deciding "it already exists".

### 4. Steam Launch Configuration

**Purpose**: Route Steam's audio to the StreamDeck-Bridge sink.

**Implementation**: Add `PULSE_SINK=StreamDeck-Bridge` to Steam's environment in apps.json.

**Files to modify**:
- `sunshine/apps.json.template`

### 5. Sunshine Audio Capture Configuration

**Purpose**: Configure Sunshine to capture from the ALSA loopback device.

**Implementation**: Sunshine needs to be told to use ALSA capture from the loopback device.
This must be implemented as: **probe + then set explicitly** (do not guess config keys/values).
Specifically:
- First, confirm Sunshine's supported audio capture config keys for this version (via docs and/or
  `sunshine --help`/existing config schema in this repo).
- Then, set the capture source explicitly to the ALSA loopback capture device (card `Loopback`,
  device 1, chosen subdevice), and add a health check that validates Sunshine is actually capturing.

**Files to modify**:
- `sunshine/sunshine.conf.template`

### 6. Group Membership

**Purpose**: Allow streamdeck user to access ALSA devices.

**Implementation**: Add streamdeck to `audio` group (already done per experiments).

**Files to modify**:
- `install.sh` - Ensure `usermod -aG audio streamdeck`

### 7. Diagnostics

**Purpose**: Collect audio-related logs for debugging.

**Files to modify**:
- `collect-logs.sh` - Add audio bridge logs, ALSA state, PipeWire state

---

## Detailed Implementation

### File: `/etc/modules-load.d/snd-aloop.conf`

```
# ALSA loopback device for Stream Deck audio bridge
# Creates virtual audio devices that can be used to route audio between users
snd-aloop
```

### File: `systemd/streamdeck-audio-bridge.service`

```ini
[Unit]
Description=Stream Deck Audio Bridge (PipeWire to ALSA Loopback)
Documentation=file:///path/to/AUDIO_IMPLEMENTATION_PLAN.md
# Start after __BUDDY_USER__'s user session is up (provides PipeWire)
After=user@1000.service
Requires=user@1000.service
# Also start with Sunshine
Before=streamdeck-sunshine.service
Wants=streamdeck-sunshine.service

[Service]
Type=simple
User=__BUDDY_USER__
Group=__BUDDY_USER__
# Need access to __BUDDY_USER__'s PipeWire session
Environment="XDG_RUNTIME_DIR=/run/user/1000"
ExecStart=/home/__BUDDY_USER__/streamdeck/scripts/audio-bridge.sh
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

### File: `scripts/audio-bridge.sh`

```bash
#!/bin/bash
# Audio bridge: routes PipeWire null-sink to ALSA loopback for cross-user capture
set -euo pipefail

SINK_NAME="StreamDeck-Bridge"
LOOPBACK_SUBDEVICE=7

log_err() { echo "ERROR: $*" >&2; }

# Detect loopback card
LOOPBACK_CARD="$(awk '$0 ~ /^\s*[0-9]+\s+\[Loopback/ { print $1; exit }' /proc/asound/cards | tr -d ' ')"
if [[ -z "$LOOPBACK_CARD" ]]; then
    log_err "snd-aloop not loaded or no ALSA Loopback card found in /proc/asound/cards"
    exit 1
fi

ALSA_PLAYBACK_DEV="plughw:${LOOPBACK_CARD},0,${LOOPBACK_SUBDEVICE}"

# Fail fast if PipeWire/PulseAudio-compat isn't reachable in __BUDDY_USER__'s session
if ! pactl info >/dev/null 2>&1; then
    log_err "cannot talk to PipeWire/PulseAudio as __BUDDY_USER__ (is __BUDDY_USER__'s user session active?)"
    log_err "expected XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR} and a working pactl"
    exit 1
fi

# Create null-sink if it doesn't exist (exact name match, not substring)
module_id=""
if ! pactl list sinks short | awk '{print $2}' | grep -Fxq "$SINK_NAME"; then
    module_id="$(pactl load-module module-null-sink sink_name="$SINK_NAME" \
        sink_properties=device.description="$SINK_NAME")"
    # Best-effort cleanup if we created it (server-local; safe to attempt unload on exit)
    trap '[[ -n "${module_id}" ]] && pactl unload-module "${module_id}" >/dev/null 2>&1 || true' EXIT
fi

# Validate expected monitor source exists before starting long-running pipeline
if ! pactl list sources short | awk '{print $2}' | grep -Fxq "${SINK_NAME}.monitor"; then
    log_err "expected monitor source '${SINK_NAME}.monitor' not found; null-sink creation failed?"
    exit 1
fi

# Run the bridge: capture from sink monitor, play to ALSA loopback
exec pw-record --target="${SINK_NAME}.monitor" - | \
    aplay -D "$ALSA_PLAYBACK_DEV" -f S16_LE -r 48000 -c 2 -
```

### File: `sunshine/apps.json.template` (modified)

Add `PULSE_SINK=StreamDeck-Bridge` to Steam commands:

```json
{
  "env": {
    "PATH": "/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin",
    "DISPLAY": ":99"
  },
  "apps": [
    {
      "name": "Desktop",
      "cmd": "xterm",
      "output": "desktop.log"
    },
    {
      "name": "Steam Big Picture",
      "cmd": "sudo -u __BUDDY_USER__ HOME=/home/__BUDDY_USER__ USER=__BUDDY_USER__ XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus PULSE_SINK=StreamDeck-Bridge steam -gamepadui --disable-gpu --disable-software-rasterizer",
      "output": "steam-bp.log"
    },
    {
      "name": "Horizon Forbidden West",
      "cmd": "sudo -u __BUDDY_USER__ HOME=/home/__BUDDY_USER__ USER=__BUDDY_USER__ XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus PULSE_SINK=StreamDeck-Bridge steam steam://rungameid/2420110",
      "output": "hfw.log"
    },
    {
      "name": "Satisfactory",
      "cmd": "sudo -u __BUDDY_USER__ HOME=/home/__BUDDY_USER__ USER=__BUDDY_USER__ XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus PULSE_SINK=StreamDeck-Bridge steam steam://rungameid/526870",
      "output": "game-526870.log"
    }
  ]
}
```

### File: `sunshine/sunshine.conf.template` (additions)

```ini
# Audio capture: do not guess keys/values here.
# Once confirmed for the Sunshine version in use, set the audio capture backend/source explicitly
# to the ALSA loopback capture device (Loopback card, device 1, chosen subdevice).
```

Note: Sunshine's exact audio capture config key(s) vary by version. This plan requires a probe step
to confirm the correct key/value and then add a health check that validates capture is active.

### File: `install.sh` (additions)

```bash
# --- Audio Bridge Setup ---

# Ensure streamdeck user is in audio group for ALSA access
log_info "Adding streamdeck user to audio group..."
usermod -aG audio "$STREAM_USER"

# Install snd-aloop module load config
log_info "Configuring snd-aloop module..."
cat > /etc/modules-load.d/snd-aloop.conf <<'EOF'
# ALSA loopback device for Stream Deck audio bridge
snd-aloop
EOF

# Load module now if not already loaded
if ! lsmod | grep -q snd_aloop; then
    modprobe snd-aloop
fi

# Install audio bridge script
log_info "Installing audio bridge script..."
install -m 0755 "$REPO_ROOT/scripts/audio-bridge.sh" /home/__BUDDY_USER__/streamdeck/scripts/

# Install audio bridge service
log_info "Installing audio bridge service..."
cp "$REPO_ROOT/systemd/streamdeck-audio-bridge.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable streamdeck-audio-bridge.service

# Start audio bridge (hard requirement; fail-fast with actionable message)
if ! systemctl start streamdeck-audio-bridge.service; then
    log_error "audio bridge failed to start (__BUDDY_USER__'s PipeWire session must be active)"
    log_error "next step: ensure __BUDDY_USER__ is logged in (user session running), then re-run install/health checks"
    exit 1
fi
```

### File: `collect-logs.sh` (additions)

```bash
# --- Audio Bridge Diagnostics ---

log_info "Collecting audio bridge state..."

# Audio bridge service status
collect_systemctl_status streamdeck-audio-bridge.service "$LOG_DIR/systemctl-audio-bridge.status"
collect_journalctl streamdeck-audio-bridge.service "$LOG_DIR/journalctl-audio-bridge.log" 100

# ALSA state
log_info "Collecting ALSA state..."
{
    echo "=== ALSA Cards ==="
    cat /proc/asound/cards
    echo ""
    echo "=== snd-aloop module ==="
    lsmod | grep snd_aloop || echo "snd_aloop not loaded"
    echo ""
    echo "=== Loopback Cable State ==="
    for cable in /proc/asound/card*/cable#*; do
        if [[ -f "$cable" ]]; then
            echo "--- $cable ---"
            cat "$cable"
        fi
    done
} > "$LOG_DIR/alsa-state.txt" 2>&1

# PipeWire/PulseAudio state (as __BUDDY_USER__)
log_info "Collecting PipeWire state..."
{
    echo "=== pactl info (__BUDDY_USER__) ==="
    sudo -u __BUDDY_USER__ XDG_RUNTIME_DIR=/run/user/1000 pactl info 2>&1 || echo "Could not run pactl info"
    echo ""
    echo "=== PipeWire Sinks ==="
    sudo -u __BUDDY_USER__ XDG_RUNTIME_DIR=/run/user/1000 pactl list sinks short 2>&1 || echo "Could not list sinks"
    echo ""
    echo "=== PipeWire Sources ==="
    sudo -u __BUDDY_USER__ XDG_RUNTIME_DIR=/run/user/1000 pactl list sources short 2>&1 || echo "Could not list sources"
    echo ""
    echo "=== StreamDeck-Bridge Sink ==="
    sudo -u __BUDDY_USER__ XDG_RUNTIME_DIR=/run/user/1000 pactl list sinks 2>&1 | grep -A30 "StreamDeck-Bridge" || echo "StreamDeck-Bridge sink not found"
} > "$LOG_DIR/pipewire-state.txt" 2>&1

# Sunshine audio config
log_info "Collecting Sunshine audio config..."
if [[ -f "/home/streamdeck/.config/sunshine/sunshine.conf" ]]; then
    grep -i audio /home/streamdeck/.config/sunshine/sunshine.conf > "$LOG_DIR/sunshine-audio-config.txt" 2>&1 || true
fi
```

---

## Install Order

1. **snd-aloop module**: Load and persist
2. **audio group**: Add streamdeck user
3. **audio-bridge.sh**: Install script
4. **streamdeck-audio-bridge.service**: Install and enable
5. **apps.json**: Update with PULSE_SINK
6. **sunshine.conf**: Update with audio capture config (if needed)
7. **Restart services**: audio-bridge, sunshine

## Testing

After installation:

```bash
# Verify snd-aloop is loaded
lsmod | grep snd_aloop

# Verify audio bridge is running
systemctl status streamdeck-audio-bridge.service

# Verify null-sink exists (as __BUDDY_USER__)
pactl list sinks short | grep StreamDeck-Bridge

# Run the timing experiment to verify end-to-end
sudo ./experiment-aloop-timing.sh

# Test with actual game launch via Moonlight
```

## Rollback

To disable the audio bridge:

```bash
systemctl stop streamdeck-audio-bridge.service
systemctl disable streamdeck-audio-bridge.service
rm /etc/modules-load.d/snd-aloop.conf
# Optionally unload module (or reboot)
modprobe -r snd-aloop
```

## Known Limitations

1. **Requires __BUDDY_USER__'s session**: The audio bridge runs as __BUDDY_USER__ and needs __BUDDY_USER__'s PipeWire session active.
   If __BUDDY_USER__ is not logged in (e.g., no desktop session), the bridge cannot run.

2. **Subdevice 7 is hardcoded**: We use subdevice 7 to avoid conflicts with PipeWire's auto-managed
   subdevice 0. This is stable but slightly arbitrary.

3. **Latency**: The `pw-record | aplay` pipeline adds some latency. For gaming this should be
   acceptable, but it's not zero.

4. **No automatic sink selection**: Games/Steam need `PULSE_SINK` set explicitly. They won't
   automatically use the bridge sink.
