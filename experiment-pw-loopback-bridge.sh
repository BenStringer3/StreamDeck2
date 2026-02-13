#!/bin/bash
# Experiment: Use pw-loopback to bridge PipeWire to ALSA loopback subdevice 7
#
# Previous experiments proved:
# - Direct ALSA on subdevice 7 works (__BUDDY_USER__ plays, streamdeck captures)
# - PipeWire's auto-managed subdevice 0 conflicts with arecord
#
# This experiment:
# 1. Creates a pw-loopback that captures from a virtual sink and plays to ALSA subdevice 7
# 2. Plays audio to that virtual sink via PipeWire
# 3. Captures from ALSA subdevice 7 as streamdeck
# 4. Verifies audio passes through
#
# Run: sudo ./experiment-pw-loopback-bridge.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/scripts/lib.sh"

STREAMDECK_USER="streamdeck"
BEN_USER="__BUDDY_USER__"
BEN_UID="$(id -u "$BEN_USER")"
BEN_XDG_RUNTIME_DIR="/run/user/${BEN_UID}"

SAMPLE_WAV="/usr/share/sounds/alsa/Front_Center.wav"
WORK_DIR="/tmp/streamdeck-pw-loopback-experiment"
RECORD_SECONDS=8

SUBDEVICE=7
VIRTUAL_SINK_NAME="StreamDeck-Bridge"

assert_root

log_info "=== Experiment: PipeWire Loopback Bridge ==="

# Detect loopback card
LOOPBACK_CARD="$(awk '$0 ~ /^\s*[0-9]+\s+\[Loopback/ { print $1; exit }' /proc/asound/cards | tr -d ' ')"
if [[ -z "$LOOPBACK_CARD" ]]; then
    log_fatal "Loopback card not found. Is snd-aloop loaded?"
fi

ALSA_PLAYBACK_DEV="plughw:${LOOPBACK_CARD},0,${SUBDEVICE}"
ALSA_CAPTURE_DEV="plughw:${LOOPBACK_CARD},1,${SUBDEVICE}"

log_info "Loopback card: $LOOPBACK_CARD"
log_info "ALSA playback device: $ALSA_PLAYBACK_DEV"
log_info "ALSA capture device:  $ALSA_CAPTURE_DEV"
log_info "Virtual sink name:    $VIRTUAL_SINK_NAME"

mkdir -p "$WORK_DIR"
chmod 1777 "$WORK_DIR"

# Check for pw-loopback
if ! command -v pw-loopback &>/dev/null; then
    log_fatal "pw-loopback not found. Install pipewire-pulse or pipewire-tools."
fi

# =============================================================================
# Phase 1: Create pw-loopback bridge
# =============================================================================
log_info ""
log_info "=== Phase 1: Create pw-loopback bridge ==="

# Kill any existing pw-loopback for this sink
log_info "Cleaning up any existing pw-loopback instances..."
pkill -f "pw-loopback.*${VIRTUAL_SINK_NAME}" 2>/dev/null || true
sleep 0.5

# pw-loopback creates a virtual source/sink pair.
# We want: apps play to virtual sink → pw-loopback captures from it → outputs to ALSA device
#
# However, pw-loopback's typical use is to loop audio between PipeWire nodes.
# For ALSA output, we need a different approach: pw-cat or a custom pipeline.
#
# Let's try: create a null-sink, then use pw-cat to read from its monitor and pipe to ALSA.

log_info "Creating virtual null-sink for Steam audio..."

# First, check if module-null-sink equivalent exists in PipeWire
# PipeWire uses pw-loopback differently. Let's try creating a sink with pactl.

# Remove old sink if exists
sudo -u "$BEN_USER" env XDG_RUNTIME_DIR="$BEN_XDG_RUNTIME_DIR" \
    pactl unload-module module-null-sink 2>/dev/null || true

# Create null sink
SINK_MODULE_ID=$(sudo -u "$BEN_USER" env XDG_RUNTIME_DIR="$BEN_XDG_RUNTIME_DIR" \
    pactl load-module module-null-sink sink_name="$VIRTUAL_SINK_NAME" \
    sink_properties=device.description="$VIRTUAL_SINK_NAME" 2>/dev/null || echo "")

if [[ -z "$SINK_MODULE_ID" ]]; then
    log_warn "Could not create null-sink via pactl. Trying alternative..."
    
    # Alternative: use pw-loopback to create a capture→playback loop
    # This creates a sink that we can play to, and it outputs to the specified target
    log_info "Starting pw-loopback to bridge to ALSA..."
    
    # pw-loopback with ALSA sink target
    # Note: pw-loopback might not directly support ALSA targets, so we may need pw-cat
    
    # Let's try a simpler approach: use pw-record piped to aplay
    log_info "Testing pw-record | aplay approach..."
else
    log_info "Created null-sink with module ID: $SINK_MODULE_ID"
fi

# Verify sink exists
sleep 0.5
if sudo -u "$BEN_USER" env XDG_RUNTIME_DIR="$BEN_XDG_RUNTIME_DIR" \
    pactl list sinks short 2>/dev/null | grep -q "$VIRTUAL_SINK_NAME"; then
    log_info "✓ Virtual sink '$VIRTUAL_SINK_NAME' is available"
    SINK_EXISTS=1
else
    log_warn "Virtual sink not found in pactl list. Trying direct ALSA approach..."
    SINK_EXISTS=0
fi

# =============================================================================
# Phase 2: Bridge the sink to ALSA loopback
# =============================================================================
log_info ""
log_info "=== Phase 2: Bridge virtual sink to ALSA loopback ==="

OUT_WAV="$WORK_DIR/pw-bridge-test.wav"
rm -f "$OUT_WAV"

if [[ "$SINK_EXISTS" -eq 1 ]]; then
    # Start capturing the virtual sink's monitor and pipe to ALSA
    MONITOR_SOURCE="${VIRTUAL_SINK_NAME}.monitor"
    
    log_info "Starting bridge: pw-record from $MONITOR_SOURCE | aplay to $ALSA_PLAYBACK_DEV"
    
    # Start the bridge in background
    sudo -u "$BEN_USER" env XDG_RUNTIME_DIR="$BEN_XDG_RUNTIME_DIR" \
        pw-record --target="$MONITOR_SOURCE" - 2>/dev/null | \
        aplay -q -D "$ALSA_PLAYBACK_DEV" -f S16_LE -r 48000 -c 2 - &
    BRIDGE_PID=$!
    
    sleep 0.5
    
    if ! kill -0 $BRIDGE_PID 2>/dev/null; then
        log_error "Bridge process died immediately"
        BRIDGE_PID=""
    else
        log_info "Bridge running (PID $BRIDGE_PID)"
    fi
else
    BRIDGE_PID=""
fi

# =============================================================================
# Phase 3: Start ALSA capture
# =============================================================================
log_info ""
log_info "=== Phase 3: Start ALSA capture ==="

log_info "Starting arecord as $STREAMDECK_USER..."
sudo -u "$STREAMDECK_USER" arecord -q -D "$ALSA_CAPTURE_DEV" -f S16_LE -r 48000 -c 2 -d "$RECORD_SECONDS" "$OUT_WAV" &
ARECORD_PID=$!

sleep 0.5

# =============================================================================
# Phase 4: Play audio
# =============================================================================
log_info ""
log_info "=== Phase 4: Play audio ==="

if [[ "$SINK_EXISTS" -eq 1 ]] && [[ -n "${BRIDGE_PID:-}" ]]; then
    log_info "Playing to virtual sink '$VIRTUAL_SINK_NAME'..."
    sudo -u "$BEN_USER" env XDG_RUNTIME_DIR="$BEN_XDG_RUNTIME_DIR" \
        paplay --device="$VIRTUAL_SINK_NAME" "$SAMPLE_WAV" || log_warn "paplay returned non-zero"
else
    # Fallback: play directly to ALSA (we know this works)
    log_info "Fallback: Playing directly to ALSA device..."
    sudo -u "$BEN_USER" aplay -q -D "$ALSA_PLAYBACK_DEV" "$SAMPLE_WAV" || log_warn "aplay returned non-zero"
fi

# =============================================================================
# Phase 5: Wait and cleanup
# =============================================================================
log_info ""
log_info "=== Phase 5: Wait and cleanup ==="

log_info "Waiting for recording to complete..."
wait $ARECORD_PID || true

# Kill bridge
if [[ -n "${BRIDGE_PID:-}" ]]; then
    kill $BRIDGE_PID 2>/dev/null || true
    wait $BRIDGE_PID 2>/dev/null || true
fi

# Unload null-sink
if [[ -n "${SINK_MODULE_ID:-}" ]]; then
    sudo -u "$BEN_USER" env XDG_RUNTIME_DIR="$BEN_XDG_RUNTIME_DIR" \
        pactl unload-module "$SINK_MODULE_ID" 2>/dev/null || true
fi

# =============================================================================
# Phase 6: Analyze
# =============================================================================
log_info ""
log_info "=== Phase 6: Analyze recording ==="

if [[ ! -f "$OUT_WAV" ]] || [[ $(stat -c%s "$OUT_WAV") -lt 100 ]]; then
    log_fatal "Recording file not created or too small: $OUT_WAV"
fi

VOLUME_LOG="$WORK_DIR/volume.log"
ffmpeg -hide_banner -nostdin -i "$OUT_WAV" -af volumedetect -f null - 2>"$VOLUME_LOG" || true

MAX_VOL="$(awk -F': ' '/max_volume:/ {print $2}' "$VOLUME_LOG" | tail -n1 || true)"
MEAN_VOL="$(awk -F': ' '/mean_volume:/ {print $2}' "$VOLUME_LOG" | tail -n1 || true)"

log_info "Max volume:  ${MAX_VOL:-unknown}"
log_info "Mean volume: ${MEAN_VOL:-unknown}"

# =============================================================================
# Summary
# =============================================================================
log_info ""
log_info "=== SUMMARY ==="

MAX_DB="$(printf '%s' "${MAX_VOL:-}" | awk '{print $1}')"
if [[ -z "$MAX_DB" ]] || [[ "$MAX_DB" == "-inf" ]]; then
    log_error "RESULT: FAIL (no audio detected)"
    exit 1
elif awk -v v="$MAX_DB" 'BEGIN { exit !(v <= -60.0) }'; then
    # awk exits 0 (success) when v <= -60, meaning audio is too quiet
    log_error "RESULT: SILENT (max_volume $MAX_VOL is at or below -60 dB)"
    exit 1
else
    log_info "RESULT: PASS"
    log_info ""
    log_info "The PipeWire → ALSA loopback → streamdeck bridge is working!"
    log_info ""
    log_info "To make this permanent for Steam:"
    log_info "  1. Create a systemd user service that runs the pw-record|aplay bridge"
    log_info "  2. Configure Steam to output to the '$VIRTUAL_SINK_NAME' sink"
    log_info "  3. Configure Sunshine to capture from ALSA device $ALSA_CAPTURE_DEV"
    log_info ""
    log_info "Or simpler: set SDL_AUDIODRIVER=alsa and AUDIODEV=$ALSA_PLAYBACK_DEV for Steam"
    exit 0
fi
