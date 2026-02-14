#!/bin/bash
# Capture bridge: ALSA loopback -> PulseAudio sink for Sunshine
set -euo pipefail

SINK_NAME="${SINK_NAME:-StreamDeck-Capture}"

# IMPORTANT: Must match audio-bridge.sh. Use dedicated subdevice (7).
LOOPBACK_SUBDEVICE="${LOOPBACK_SUBDEVICE:-7}"

log_info() { echo "INFO: $*" >&2; }
log_warn() { echo "WARN: $*" >&2; }
log_err()  { echo "ERROR: $*" >&2; }

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-}"
export PULSE_SERVER="${PULSE_SERVER:-}"
export PULSE_RUNTIME_PATH="${PULSE_RUNTIME_PATH:-}"

if [[ -z "$PULSE_SERVER" || -z "$XDG_RUNTIME_DIR" ]]; then
  log_err "PULSE_SERVER and XDG_RUNTIME_DIR must be set (by systemd unit)"
  exit 1
fi

PULSE_SOCKET="${XDG_RUNTIME_DIR}/pulse/native"
if [[ ! -S "$PULSE_SOCKET" ]]; then
  log_err "Pulse socket not found: $PULSE_SOCKET"
  exit 1
fi

log_info "XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR PULSE_SERVER=$PULSE_SERVER"

# Clean broken runtime symlinks
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

ALSA_CAPTURE_DEV="hw:${LOOPBACK_CARD},1,${LOOPBACK_SUBDEVICE}"

# Fail fast if ALSA device is not usable
if ! arecord -D "$ALSA_CAPTURE_DEV" --dump-hw-params -f S16_LE -r 48000 -c 2 </dev/null >/dev/null 2>&1; then
  log_err "ALSA capture device not usable: $ALSA_CAPTURE_DEV"
  log_err "Try: arecord -l ; cat /proc/asound/cards ; ls -la /dev/snd"
  exit 1
fi

# Wait for PipeWire-Pulse to be ready
for i in $(seq 1 30); do
  if pactl info >/dev/null 2>&1; then
    log_info "PipeWire-Pulse ready (attempt $i)"
    break
  fi
  [[ $i -eq 30 ]] && { log_err "PipeWire-Pulse did not become ready in time"; exit 1; }
  sleep 0.5
done

log_info "Current sinks:"
pactl list sinks short >&2 || true

# Create null-sink if needed
if ! pactl list sinks short | awk '{print $2}' | grep -Fxq "$SINK_NAME"; then
  log_info "Creating null-sink: $SINK_NAME"
  pactl load-module module-null-sink sink_name="$SINK_NAME" \
    sink_properties=device.description="$SINK_NAME" >/dev/null
fi

if ! pactl list sinks short | awk '{print $2}' | grep -Fxq "$SINK_NAME"; then
  log_err "Sink $SINK_NAME not found after creation"
  exit 1
fi

log_info "Piping ALSA ${ALSA_CAPTURE_DEV} -> PipeWire sink ${SINK_NAME} (subdevice=${LOOPBACK_SUBDEVICE})"

# Resolve PipeWire Node id for the sink more robustly
SINK_NODE_ID="$(
  pw-cli list-objects Node 2>/dev/null | \
    awk -v name="$SINK_NAME" '
      $0 ~ /^id [0-9]+,/ { gsub(/,/, "", $2); id=$2 }
      $0 ~ "node.name = \""name"\"" { print id; exit }
    ' || true
)"

if [[ -n "$SINK_NODE_ID" ]]; then
  log_info "Found PipeWire node id for $SINK_NAME: $SINK_NODE_ID"
  exec arecord -q -D "$ALSA_CAPTURE_DEV" -f S16_LE -r 48000 -c 2 -t raw - | \
    pw-cat --playback --target="$SINK_NODE_ID" --rate=48000 --channels=2 --format=s16 -
else
  log_warn "Could not find PipeWire node id for sink $SINK_NAME; trying by name"
  exec arecord -q -D "$ALSA_CAPTURE_DEV" -f S16_LE -r 48000 -c 2 -t raw - | \
    pw-cat --playback --target="$SINK_NAME" --rate=48000 --channels=2 --format=s16 -
fi
