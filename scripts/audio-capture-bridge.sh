#!/bin/bash
# Capture bridge: ALSA loopback -> PulseAudio sink for Sunshine
# Sunshine (PulseAudio-only on Linux) captures from a sink's monitor.
# This script creates a persistent null-sink and pipes ALSA loopback into it.
# Sunshine is configured via audio_sink to capture from this sink's monitor.
set -euo pipefail

# Our custom sink name - Sunshine's audio_sink config points here
SINK_NAME="StreamDeck-Capture"
# Subdevice 0: must match audio-bridge.sh (cable#0,sub0 → cable#1,sub0)
LOOPBACK_SUBDEVICE=0

log_info() { echo "INFO: $*" >&2; }
log_err() { echo "ERROR: $*" >&2; }

# Ensure pipeline children (pacat) inherit Pulse env; systemd sets these in the unit
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-}"
export PULSE_SERVER="${PULSE_SERVER:-}"
export PULSE_RUNTIME_PATH="${PULSE_RUNTIME_PATH:-}"
if [[ -z "$PULSE_SERVER" || -z "$XDG_RUNTIME_DIR" ]]; then
    log_err "PULSE_SERVER and XDG_RUNTIME_DIR must be set (by systemd unit)"
    exit 1
fi

# Require socket to exist so pacat can connect (avoids ENOENT from pipeline)
PULSE_SOCKET="${XDG_RUNTIME_DIR}/pulse/native"
if [[ ! -S "$PULSE_SOCKET" ]]; then
    log_err "Pulse socket not found: $PULSE_SOCKET"
    exit 1
fi

log_info "XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR PULSE_SERVER=$PULSE_SERVER"

# Remove broken PulseAudio runtime symlinks that point to non-existent /tmp directories
# These can cause pacat to fail with "open(): No such file or directory"
PULSE_CONFIG_DIR="${HOME}/.config/pulse"
if [[ -d "$PULSE_CONFIG_DIR" ]]; then
    find "$PULSE_CONFIG_DIR" -type l -name "*-runtime" -exec sh -c 'test ! -e "$1" && rm -f "$1"' _ {} \; 2>/dev/null || true
fi

# Detect loopback card
LOOPBACK_CARD="$(awk '$0 ~ /^\s*[0-9]+\s+\[Loopback/ { print $1; exit }' /proc/asound/cards | tr -d ' ')"
if [[ -z "$LOOPBACK_CARD" ]]; then
    log_err "snd-aloop not loaded or no ALSA Loopback card found"
    exit 1
fi

# Use hw: (direct) instead of plughw: (plugin) to avoid ALSA config issues in systemd context
ALSA_CAPTURE_DEV="hw:${LOOPBACK_CARD},1,${LOOPBACK_SUBDEVICE}"

# Wait for PipeWire-Pulse to be ready
for i in $(seq 1 30); do
    if pactl info >/dev/null 2>&1; then
        log_info "PipeWire-Pulse ready (attempt $i)"
        break
    fi
    [[ $i -eq 30 ]] && { log_err "PipeWire-Pulse did not become ready in time"; exit 1; }
    sleep 0.5
done

# Debug: show current sinks
log_info "Current sinks:"
pactl list sinks short >&2 || true

# Create our null-sink if it doesn't exist (Sunshine will capture from its monitor)
if ! pactl list sinks short | awk '{print $2}' | grep -Fxq "$SINK_NAME"; then
    log_info "Creating null-sink: $SINK_NAME"
    if ! pactl load-module module-null-sink sink_name="$SINK_NAME" sink_properties=device.description="StreamDeck-Capture"; then
        log_err "Failed to load module-null-sink"
        exit 1
    fi
fi

# Verify sink exists
log_info "Sinks after creation:"
pactl list sinks short >&2 || true

if ! pactl list sinks short | awk '{print $2}' | grep -Fxq "$SINK_NAME"; then
    log_err "Sink $SINK_NAME not found after creation"
    exit 1
fi

log_info "Piping ALSA $ALSA_CAPTURE_DEV -> PulseAudio $SINK_NAME"

# Use pw-cat (PipeWire-native) instead of pacat (PulseAudio compat layer)
# pw-cat is more reliable in systemd context and avoids pacat's "open(): No such file" issue
# Find PipeWire node ID for the sink (pw-cli list-objects shows node.id)
# Extract node ID and strip any trailing commas/whitespace
SINK_NODE_ID=$(pw-cli list-objects 2>/dev/null | grep -B 5 -A 10 "node.name = \"$SINK_NAME\"" | grep -E '^\s*id' | head -1 | awk '{print $2}' | tr -d ', ' || echo "")

if [[ -n "$SINK_NODE_ID" ]]; then
    log_info "Found PipeWire node ID for $SINK_NAME: $SINK_NODE_ID, using pw-cat"
    # pw-cat needs --format to specify raw PCM format (s16 = signed 16-bit)
    exec arecord -q -D "$ALSA_CAPTURE_DEV" -f S16_LE -r 48000 -c 2 -t raw - | \
        pw-cat --playback --target="$SINK_NODE_ID" --rate=48000 --channels=2 --format=s16 -
else
    log_warn "Could not find PipeWire node ID for sink $SINK_NAME, trying sink name directly"
    # Try sink name directly (pw-cat may accept PulseAudio sink names)
    exec arecord -q -D "$ALSA_CAPTURE_DEV" -f S16_LE -r 48000 -c 2 -t raw - | \
        pw-cat --playback --target="$SINK_NAME" --rate=48000 --channels=2 --format=s16 -
fi
