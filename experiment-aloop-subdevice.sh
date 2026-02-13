#!/bin/bash
# Experiment: Test ALSA loopback with dedicated subdevice (avoiding PipeWire conflicts)
#
# Problem discovered: PipeWire manages subdevice 0 of the loopback card, and when it opens
# playback, it disrupts any existing arecord capture on the same subdevice.
#
# Hypothesis: If we use a DIFFERENT subdevice (e.g., 7) that PipeWire doesn't manage,
# we can have stable capture. We just need to route audio to that subdevice.
#
# This experiment tests:
# 1. Direct ALSA play/capture on subdevice 7 (control - should work, Test B proved it)
# 2. Whether we can create a PipeWire sink that outputs to a specific subdevice
#
# Run: sudo ./experiment-aloop-subdevice.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/scripts/lib.sh"

STREAMDECK_USER="streamdeck"
BEN_USER="__BUDDY_USER__"
BEN_UID="$(id -u "$BEN_USER")"
BEN_XDG_RUNTIME_DIR="/run/user/${BEN_UID}"

SAMPLE_WAV="/usr/share/sounds/alsa/Front_Center.wav"
WORK_DIR="/tmp/streamdeck-aloop-subdevice-experiment"
RECORD_SECONDS=6

# Use subdevice 7 to avoid PipeWire's auto-managed subdevice 0
SUBDEVICE=7

assert_root

log_info "=== Experiment: ALSA Loopback Dedicated Subdevice ==="

# Detect loopback card
LOOPBACK_CARD="$(awk '$0 ~ /^\s*[0-9]+\s+\[Loopback/ { print $1; exit }' /proc/asound/cards | tr -d ' ')"
if [[ -z "$LOOPBACK_CARD" ]]; then
    log_fatal "Loopback card not found. Is snd-aloop loaded?"
fi
log_info "Loopback card index: $LOOPBACK_CARD"
log_info "Using dedicated subdevice: $SUBDEVICE"

ALSA_PLAYBACK_DEV="plughw:${LOOPBACK_CARD},0,${SUBDEVICE}"
ALSA_CAPTURE_DEV="plughw:${LOOPBACK_CARD},1,${SUBDEVICE}"

log_info "Playback device: $ALSA_PLAYBACK_DEV"
log_info "Capture device:  $ALSA_CAPTURE_DEV"

mkdir -p "$WORK_DIR"
chmod 1777 "$WORK_DIR"

# =============================================================================
# Test 1: Direct ALSA (control test - should pass)
# =============================================================================
log_info ""
log_info "=== Test 1: Direct ALSA on subdevice $SUBDEVICE ==="

OUT_WAV="$WORK_DIR/test1-direct-alsa.wav"
rm -f "$OUT_WAV"

log_info "Starting capture as $STREAMDECK_USER..."
sudo -u "$STREAMDECK_USER" arecord -q -D "$ALSA_CAPTURE_DEV" -f S16_LE -r 48000 -c 2 -d "$RECORD_SECONDS" "$OUT_WAV" &
ARECORD_PID=$!

sleep 0.5

log_info "Playing via direct ALSA as $BEN_USER..."
sudo -u "$BEN_USER" aplay -q -D "$ALSA_PLAYBACK_DEV" "$SAMPLE_WAV" || log_warn "aplay returned non-zero"

wait $ARECORD_PID || true

if [[ -f "$OUT_WAV" ]] && [[ $(stat -c%s "$OUT_WAV") -gt 100 ]]; then
    VOLUME_LOG="$WORK_DIR/test1-volume.log"
    ffmpeg -hide_banner -nostdin -i "$OUT_WAV" -af volumedetect -f null - 2>"$VOLUME_LOG" || true
    MAX_VOL="$(awk -F': ' '/max_volume:/ {print $2}' "$VOLUME_LOG" | tail -n1 || true)"
    log_info "Test 1 max_volume: ${MAX_VOL:-unknown}"
    
    MAX_DB="$(printf '%s' "${MAX_VOL:-}" | awk '{print $1}')"
    if [[ -n "$MAX_DB" ]] && [[ "$MAX_DB" != "-inf" ]] && awk -v v="$MAX_DB" 'BEGIN { exit (v <= -60.0) }'; then
        log_info "Test 1: PASS"
        TEST1="PASS"
    else
        log_error "Test 1: SILENT"
        TEST1="SILENT"
    fi
else
    log_error "Test 1: FAIL (no recording)"
    TEST1="FAIL"
fi

# =============================================================================
# Test 2: Play via paplay to a custom ALSA device (not PipeWire sink)
# =============================================================================
log_info ""
log_info "=== Test 2: paplay with PULSE_SERVER=unix:/dev/null (bypass PipeWire) ==="
log_info "This tests if we can use paplay's --raw mode to play directly to ALSA"

# Actually, paplay can't do this. Let's try pw-play or pw-cat instead.
log_info "Checking for pw-play/pw-cat..."

if command -v pw-play &>/dev/null; then
    log_info "pw-play is available"
else
    log_warn "pw-play not found"
fi

if command -v pw-cat &>/dev/null; then
    log_info "pw-cat is available"
else
    log_warn "pw-cat not found"
fi

# =============================================================================
# Test 3: Use ffplay to play directly to ALSA device
# =============================================================================
log_info ""
log_info "=== Test 3: ffplay to ALSA device ==="

OUT_WAV="$WORK_DIR/test3-ffplay.wav"
rm -f "$OUT_WAV"

log_info "Starting capture as $STREAMDECK_USER..."
sudo -u "$STREAMDECK_USER" arecord -q -D "$ALSA_CAPTURE_DEV" -f S16_LE -r 48000 -c 2 -d "$RECORD_SECONDS" "$OUT_WAV" &
ARECORD_PID=$!

sleep 0.5

log_info "Playing via ffmpeg (to ALSA) as $BEN_USER..."
# Use ffmpeg to play to ALSA device directly
sudo -u "$BEN_USER" ffmpeg -hide_banner -loglevel error -i "$SAMPLE_WAV" -f alsa "$ALSA_PLAYBACK_DEV" 2>&1 || log_warn "ffmpeg playback returned non-zero"

wait $ARECORD_PID || true

if [[ -f "$OUT_WAV" ]] && [[ $(stat -c%s "$OUT_WAV") -gt 100 ]]; then
    VOLUME_LOG="$WORK_DIR/test3-volume.log"
    ffmpeg -hide_banner -nostdin -i "$OUT_WAV" -af volumedetect -f null - 2>"$VOLUME_LOG" || true
    MAX_VOL="$(awk -F': ' '/max_volume:/ {print $2}' "$VOLUME_LOG" | tail -n1 || true)"
    log_info "Test 3 max_volume: ${MAX_VOL:-unknown}"
    
    MAX_DB="$(printf '%s' "${MAX_VOL:-}" | awk '{print $1}')"
    if [[ -n "$MAX_DB" ]] && [[ "$MAX_DB" != "-inf" ]] && awk -v v="$MAX_DB" 'BEGIN { exit (v <= -60.0) }'; then
        log_info "Test 3: PASS"
        TEST3="PASS"
    else
        log_error "Test 3: SILENT"
        TEST3="SILENT"
    fi
else
    log_error "Test 3: FAIL (no recording)"
    TEST3="FAIL"
fi

# =============================================================================
# Test 4: Create a PipeWire null-sink and link it to ALSA loopback
# =============================================================================
log_info ""
log_info "=== Test 4: Check if PipeWire can route to specific ALSA subdevice ==="

# Check current PipeWire nodes
log_info "PipeWire nodes related to loopback:"
sudo -u "$BEN_USER" env XDG_RUNTIME_DIR="$BEN_XDG_RUNTIME_DIR" pw-cli list-objects 2>/dev/null | grep -i "loopback\|aloop" | head -20 || true

log_info ""
log_info "Checking if we can create a custom ALSA sink node pointing to subdevice $SUBDEVICE..."
log_info "(This would require pw-loopback or a custom PipeWire config - skipping automated test)"

# =============================================================================
# Summary
# =============================================================================
log_info ""
log_info "=== SUMMARY ==="
log_info "Test 1 (Direct ALSA aplay→arecord on subdevice $SUBDEVICE): ${TEST1:-SKIP}"
log_info "Test 3 (ffmpeg ALSA output→arecord on subdevice $SUBDEVICE): ${TEST3:-SKIP}"
log_info ""

if [[ "${TEST1:-}" == "PASS" ]]; then
    log_info "CONCLUSION: Direct ALSA bridge works on dedicated subdevice."
    log_info ""
    log_info "The path forward is to route Steam/game audio to this ALSA device."
    log_info "Options:"
    log_info "  1. Configure PipeWire to use subdevice $SUBDEVICE for the loopback sink"
    log_info "  2. Use ALSA dmix/dsnoop to multiplex access"
    log_info "  3. Use pw-loopback to bridge PipeWire to ALSA"
    log_info "  4. Configure Steam to use ALSA directly (SDL_AUDIODRIVER=alsa)"
else
    log_error "CONCLUSION: Even direct ALSA failed. Check permissions or snd-aloop state."
fi
