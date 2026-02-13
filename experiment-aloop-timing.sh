#!/bin/bash
# Experiment: Test ALSA loopback timing / cable linkage
#
# Hypothesis: The loopback bridge works (Test B proved it), but when PipeWire plays into
# the loopback sink, our capture isn't "linking" to the cable in time—so audio goes nowhere.
#
# This experiment:
# 1. Starts capture FIRST and waits for it to become active on the cable
# 2. Only THEN triggers playback
# 3. Monitors cable state throughout
# 4. Analyzes the recording
#
# Run: sudo ./experiment-aloop-timing.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/scripts/lib.sh"

STREAMDECK_USER="streamdeck"
BEN_USER="__BUDDY_USER__"
BEN_UID="$(id -u "$BEN_USER")"
BEN_XDG_RUNTIME_DIR="/run/user/${BEN_UID}"

SAMPLE_WAV="/usr/share/sounds/alsa/Front_Center.wav"
WORK_DIR="/tmp/streamdeck-aloop-timing-experiment"
RECORD_SECONDS=8

assert_root

log_info "=== Experiment: ALSA Loopback Timing ==="

# Detect loopback card
LOOPBACK_CARD="$(awk '$0 ~ /^\s*[0-9]+\s+\[Loopback/ { print $1; exit }' /proc/asound/cards | tr -d ' ')"
if [[ -z "$LOOPBACK_CARD" ]]; then
    log_fatal "Loopback card not found. Is snd-aloop loaded?"
fi
log_info "Loopback card index: $LOOPBACK_CARD"

# Detect PipeWire loopback sink
LOOPBACK_SINK="$(sudo -u "$BEN_USER" env XDG_RUNTIME_DIR="$BEN_XDG_RUNTIME_DIR" pactl -f json list sinks 2>/dev/null | python3 -c '
import json, sys
for s in json.load(sys.stdin):
    if "snd_aloop" in s.get("name", ""):
        print(s["name"])
        break
' 2>/dev/null || true)"

if [[ -z "$LOOPBACK_SINK" ]]; then
    log_fatal "Could not find PipeWire loopback sink. Is PipeWire running for $BEN_USER?"
fi
log_info "PipeWire loopback sink: $LOOPBACK_SINK"

# Get the subdevice PipeWire uses (usually 0)
PIPEWIRE_SUBDEV="$(sudo -u "$BEN_USER" env XDG_RUNTIME_DIR="$BEN_XDG_RUNTIME_DIR" pactl -f json list sinks 2>/dev/null | python3 -c '
import json, sys
for s in json.load(sys.stdin):
    if "snd_aloop" in s.get("name", ""):
        print(s.get("properties", {}).get("alsa.subdevice", "0"))
        break
' 2>/dev/null || true)"
PIPEWIRE_SUBDEV="${PIPEWIRE_SUBDEV:-0}"
log_info "PipeWire uses subdevice: $PIPEWIRE_SUBDEV"

# snd-aloop wiring: play on device 0 -> capture on device 1 (same subdevice)
ALSA_CAPTURE_DEV="plughw:${LOOPBACK_CARD},1,${PIPEWIRE_SUBDEV}"
log_info "Will capture from: $ALSA_CAPTURE_DEV"

mkdir -p "$WORK_DIR"
chmod 1777 "$WORK_DIR"

OUT_WAV="$WORK_DIR/timing-test.wav"
CABLE_LOG="$WORK_DIR/cable-state.log"
rm -f "$OUT_WAV" "$CABLE_LOG"

log_info ""
log_info "=== Phase 1: Start capture and wait for cable to become active ==="

# Start arecord in background
sudo -u "$STREAMDECK_USER" arecord -D "$ALSA_CAPTURE_DEV" -f S16_LE -r 48000 -c 2 -d "$RECORD_SECONDS" "$OUT_WAV" &
ARECORD_PID=$!
log_info "Started arecord (PID $ARECORD_PID), waiting for cable to activate..."

# Wait for capture side to become active (up to 3 seconds)
CABLE_FILE="/proc/asound/card${LOOPBACK_CARD}/cable#0"
CAPTURE_ACTIVE=0
for i in $(seq 1 30); do
    sleep 0.1
    if grep -A20 "substream ${PIPEWIRE_SUBDEV}:" "$CABLE_FILE" 2>/dev/null | grep -q "Capture" && \
       grep -A20 "substream ${PIPEWIRE_SUBDEV}:" "$CABLE_FILE" 2>/dev/null | grep -A5 "Capture" | grep -qv "inactive"; then
        CAPTURE_ACTIVE=1
        break
    fi
done

log_info ""
log_info "Cable state after arecord start (${i}00ms):"
cat "$CABLE_FILE" | tee "$CABLE_LOG"
log_info ""

if [[ $CAPTURE_ACTIVE -eq 0 ]]; then
    log_warn "Capture side may not be fully active yet. Continuing anyway..."
fi

# Check if arecord is still running
if ! kill -0 $ARECORD_PID 2>/dev/null; then
    log_error "arecord exited prematurely!"
    wait $ARECORD_PID || true
    log_fatal "Cannot proceed without active capture."
fi

log_info "=== Phase 2: Play audio via PipeWire ==="
log_info "Playing $SAMPLE_WAV to $LOOPBACK_SINK..."

# Play audio (this should complete in ~1 second)
set +e
sudo -u "$BEN_USER" env XDG_RUNTIME_DIR="$BEN_XDG_RUNTIME_DIR" paplay --device="$LOOPBACK_SINK" "$SAMPLE_WAV"
PLAY_RC=$?
set -e

if [[ $PLAY_RC -ne 0 ]]; then
    log_error "paplay failed with exit code $PLAY_RC"
fi

log_info ""
log_info "Cable state during/after playback:"
cat "$CABLE_FILE" | tee -a "$CABLE_LOG"

log_info ""
log_info "=== Phase 3: Wait for recording to complete ==="
log_info "Waiting for arecord to finish..."

set +e
wait $ARECORD_PID
ARECORD_RC=$?
set -e

log_info "arecord exited with code $ARECORD_RC"

log_info ""
log_info "=== Phase 4: Analyze recording ==="

if [[ ! -f "$OUT_WAV" ]]; then
    log_fatal "Recording file not created: $OUT_WAV"
fi

log_info "Recording file: $OUT_WAV ($(stat -c%s "$OUT_WAV") bytes)"

VOLUME_LOG="$WORK_DIR/volumedetect.log"
if ! ffmpeg -hide_banner -nostdin -i "$OUT_WAV" -af volumedetect -f null - 2>"$VOLUME_LOG"; then
    log_error "ffmpeg analysis failed"
    cat "$VOLUME_LOG"
    exit 1
fi

log_info ""
log_info "Volume analysis:"
grep -E "mean_volume|max_volume|n_samples" "$VOLUME_LOG" || cat "$VOLUME_LOG"

MAX_VOL="$(awk -F': ' '/max_volume:/ {print $2}' "$VOLUME_LOG" | tail -n1 || true)"
MEAN_VOL="$(awk -F': ' '/mean_volume:/ {print $2}' "$VOLUME_LOG" | tail -n1 || true)"

log_info ""
log_info "=== SUMMARY ==="
log_info "Capture device:  $ALSA_CAPTURE_DEV"
log_info "PipeWire sink:   $LOOPBACK_SINK"
log_info "Max volume:      ${MAX_VOL:-unknown}"
log_info "Mean volume:     ${MEAN_VOL:-unknown}"
log_info ""

# Evaluate result
MAX_DB="$(printf '%s' "${MAX_VOL:-}" | awk '{print $1}')"
if [[ -z "$MAX_DB" ]]; then
    log_error "Could not parse max volume"
    exit 1
elif [[ "$MAX_DB" == "-inf" ]]; then
    log_error "RESULT: SILENT (recording is completely empty)"
    exit 1
elif awk -v v="$MAX_DB" 'BEGIN { exit !(v <= -60.0) }'; then
    log_error "RESULT: SILENT (max_volume = $MAX_VOL is below -60 dB threshold)"
    log_error "The loopback cable is not transferring audio from PipeWire."
    log_info ""
    log_info "Debug info saved to: $WORK_DIR"
    exit 1
else
    log_info "RESULT: PASS - Audio captured successfully!"
    log_info "The narrow bridge (PipeWire -> snd-aloop -> ALSA capture) is working."
    log_info ""
    log_info "Next step: Configure Sunshine to capture from the loopback device,"
    log_info "and route Steam audio to the loopback sink."
    exit 0
fi
