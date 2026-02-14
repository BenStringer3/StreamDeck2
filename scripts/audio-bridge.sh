#!/bin/bash
# Audio bridge: routes PipeWire null-sink to ALSA loopback for cross-user capture
# Steam (__BUDDY_USER__) outputs to StreamDeck-Bridge sink -> pw-record|aplay -> ALSA loopback
# streamdeck captures from ALSA loopback via separate capture bridge
set -euo pipefail

SINK_NAME="${SINK_NAME:-StreamDeck-Bridge}"

# IMPORTANT: Use a dedicated subdevice to avoid PipeWire/WirePlumber auto-using subdevice 0.
# Your experiments recommend 7. Keep overrideable.
LOOPBACK_SUBDEVICE="${LOOPBACK_SUBDEVICE:-7}"

log_err() { echo "ERROR: $*" >&2; }
log_info() { echo "INFO: $*" >&2; }

# Detect loopback card number from ALSA
LOOPBACK_CARD="$(awk '$0 ~ /^\s*[0-9]+\s+\[Loopback/ { print $1; exit }' /proc/asound/cards | tr -d ' ')"
if [[ -z "$LOOPBACK_CARD" ]]; then
  log_err "snd-aloop not loaded or no ALSA Loopback card found in /proc/asound/cards"
  exit 1
fi

ALSA_PLAYBACK_DEV="hw:${LOOPBACK_CARD},0,${LOOPBACK_SUBDEVICE}"
# No aplay preflight here: aplay with stdin from /dev/null tries to read a file header and fails
# with "read error" even when the device is fine. If the device is bad, the pipeline below will fail.

# Fail fast if PipeWire/PulseAudio-compat isn't reachable in __BUDDY_USER__'s session
if ! pactl info >/dev/null 2>&1; then
  log_err "cannot talk to PipeWire/PulseAudio as __BUDDY_USER__ (is __BUDDY_USER__'s user session active?)"
  log_err "expected XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-<unset>} and a working pactl"
  exit 1
fi

# Create null-sink if it doesn't exist (exact name match, not substring)
module_id=""
if ! pactl list sinks short | awk '{print $2}' | grep -Fxq "$SINK_NAME"; then
  module_id="$(pactl load-module module-null-sink sink_name="$SINK_NAME" \
    sink_properties=device.description="$SINK_NAME")"
  trap '[[ -n "${module_id}" ]] && pactl unload-module "${module_id}" >/dev/null 2>&1 || true' EXIT
fi

# Validate expected monitor source exists before starting long-running pipeline
if ! pactl list sources short | awk '{print $2}' | grep -Fxq "${SINK_NAME}.monitor"; then
  log_err "expected monitor source '${SINK_NAME}.monitor' not found; null-sink creation failed?"
  exit 1
fi

log_info "Bridging ${SINK_NAME}.monitor -> ALSA ${ALSA_PLAYBACK_DEV} (subdevice=${LOOPBACK_SUBDEVICE})"

exec pw-record --target="${SINK_NAME}.monitor" - | \
  aplay -D "$ALSA_PLAYBACK_DEV" -f S16_LE -r 48000 -c 2 -
