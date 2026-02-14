#!/bin/bash
# Experiment: Reproduce streamdeck-audio-bridge aplay failure and capture real error.
#
# Hypothesis (see AUDIO_FAILURE_ANALYSIS.md): aplay -D hw:N,0,7 --dump-hw-params fails
# when run in the systemd service context (User=__BUDDY_USER__, only XDG_RUNTIME_DIR). This script
# runs the same check in that environment and captures stderr/stdout so we can see the
# actual ALSA error and compare with a full session.
#
# Run: sudo ./experiment-audio-bridge-aplay.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/scripts/lib.sh"

BEN_USER="__BUDDY_USER__"
BEN_UID="$(id -u "$BEN_USER")"
SERVICE_ENV="XDG_RUNTIME_DIR=/run/user/${BEN_UID}"

# Match audio-bridge.sh
LOOPBACK_SUBDEVICE="${LOOPBACK_SUBDEVICE:-7}"

assert_root

log_info "=== Experiment: Audio bridge aplay check in service-like context ==="

# Detect loopback card (same as audio-bridge.sh)
LOOPBACK_CARD="$(awk '$0 ~ /^\s*[0-9]+\s+\[Loopback/ { print $1; exit }' /proc/asound/cards | tr -d ' ')"
if [[ -z "$LOOPBACK_CARD" ]]; then
    log_fatal "Loopback card not found. Is snd-aloop loaded?"
fi

ALSA_PLAYBACK_DEV="hw:${LOOPBACK_CARD},0,${LOOPBACK_SUBDEVICE}"
log_info "Loopback card: $LOOPBACK_CARD, subdevice: $LOOPBACK_SUBDEVICE, device: $ALSA_PLAYBACK_DEV"
log_info ""

# Exact command audio-bridge.sh runs (but we keep stderr)
APLAY_CMD=(aplay -D "$ALSA_PLAYBACK_DEV" --dump-hw-params -f S16_LE -r 48000 -c 2)

# --- Test 1: As __BUDDY_USER__ with SERVICE environment only (simulate systemd) ---
log_info "[Test 1] aplay check as __BUDDY_USER__ with service env only (XDG_RUNTIME_DIR only)"
log_info "Command: ${APLAY_CMD[*]} </dev/null"
TMPOUT="$(mktemp)"
TMPERR="$(mktemp)"
if sudo -u "$BEN_USER" env -i HOME="/home/${BEN_USER}" USER="$BEN_USER" "$SERVICE_ENV" \
    "${APLAY_CMD[@]}" </dev/null >"$TMPOUT" 2>"$TMPERR"; then
    log_info "Exit code: 0 (PASS)"
    cat "$TMPOUT" | head -20
else
    log_error "Exit code: $? (FAIL)"
    log_info "stdout:"
    cat "$TMPOUT" || true
    log_info "stderr:"
    cat "$TMPERR" || true
fi
rm -f "$TMPOUT" "$TMPERR"
log_info ""

# --- Test 2: As __BUDDY_USER__ with full login env (if we can get it) ---
log_info "[Test 2] aplay check as __BUDDY_USER__ with full session env (from existing login)"
# Use the same minimal env but add DISPLAY and DBUS if present in current env
EXTRA_ENV=""
[[ -n "${DISPLAY:-}" ]] && EXTRA_ENV="DISPLAY=$DISPLAY"
[[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]] && EXTRA_ENV="$EXTRA_ENV DBUS_SESSION_BUS_ADDRESS=$DBUS_SESSION_BUS_ADDRESS"
# Run as __BUDDY_USER__ with runtime dir; inherit nothing else from our (root) env
TMPOUT2="$(mktemp)"
TMPERR2="$(mktemp)"
if sudo -u "$BEN_USER" env -i HOME="/home/${BEN_USER}" USER="$BEN_USER" $SERVICE_ENV $EXTRA_ENV \
    "${APLAY_CMD[@]}" </dev/null >"$TMPOUT2" 2>"$TMPERR2"; then
    log_info "Exit code: 0 (PASS)"
    cat "$TMPOUT2" | head -20
else
    log_error "Exit code: $? (FAIL)"
    log_info "stderr:"
    cat "$TMPERR2" || true
fi
rm -f "$TMPOUT2" "$TMPERR2"
log_info ""

# --- Test 3: List playback devices as __BUDDY_USER__ (service env) ---
log_info "[Test 3] aplay -l as __BUDDY_USER__ (service env)"
sudo -u "$BEN_USER" env -i HOME="/home/${BEN_USER}" USER="$BEN_USER" $SERVICE_ENV \
    aplay -l 2>&1 | head -30
log_info ""

# --- Test 4: Try subdevice 0 (PipeWire usually uses this) ---
log_info "[Test 4] aplay check with subdevice 0 (to see if 0 works, 7 doesn't)"
DEV0="hw:${LOOPBACK_CARD},0,0"
TMPERR0="$(mktemp)"
if sudo -u "$BEN_USER" env -i HOME="/home/${BEN_USER}" USER="$BEN_USER" $SERVICE_ENV \
    aplay -D "$DEV0" --dump-hw-params -f S16_LE -r 48000 -c 2 </dev/null 2>"$TMPERR0"; then
    log_info "Subdevice 0: exit 0 (PASS)"
else
    log_error "Subdevice 0: exit $? (FAIL)"
    cat "$TMPERR0" || true
fi
rm -f "$TMPERR0"
log_info ""

# --- Test 5: Who has the loopback device open? ---
log_info "[Test 5] Processes with loopback ALSA devices open (card $LOOPBACK_CARD)"
for f in /dev/snd/pcmC"${LOOPBACK_CARD}"D*; do
    [[ -e "$f" ]] || continue
    log_info "--- $f ---"
    lsof "$f" 2>/dev/null || true
done
log_info ""

log_info "=== Summary ==="
log_info "If Test 1 fails and Test 2 passes: failure is due to minimal service env."
log_info "If both fail: failure is device/driver or something else holding the device."
log_info "If Test 4 (subdevice 0) passes but Test 1 (subdevice 7) fails: subdevice 7 may be busy or unsupported in this context."
