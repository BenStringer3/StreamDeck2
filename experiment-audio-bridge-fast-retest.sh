#!/usr/bin/env bash
# Fast audio bridge retest: verifies __BUDDY_USER__->aloop->streamdeck->sunshine chain with high-signal checks
set -euo pipefail

# ---- config (override via env) ----
BEN_USER="${BEN_USER:-__BUDDY_USER__}"
STREAM_USER="${STREAM_USER:-streamdeck}"

SVC_PIPEWIRE="${SVC_PIPEWIRE:-streamdeck-pipewire.service}"
SVC_CAPTURE="${SVC_CAPTURE:-streamdeck-audio-capture.service}"
SVC_SUNSHINE="${SVC_SUNSHINE:-streamdeck-sunshine.service}"
SVC_BRIDGE="${SVC_BRIDGE:-streamdeck-audio-bridge.service}"

SINK_BRIDGE="${SINK_BRIDGE:-StreamDeck-Bridge}"
SINK_CAPTURE="${SINK_CAPTURE:-StreamDeck-Capture}"

# should match your patched scripts (default 7)
LOOPBACK_SUBDEVICE="${LOOPBACK_SUBDEVICE:-7}"

JOURNAL_TAIL_LINES="${JOURNAL_TAIL_LINES:-200}"

# ---- helpers ----
bold() { printf "\033[1m%s\033[0m\n" "$*"; }
ok()   { printf "✅ %s\n" "$*"; }
warn() { printf "⚠️  %s\n" "$*" >&2; }
die()  { printf "❌ %s\n" "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

run() {
  # shellcheck disable=SC2068
  "$@"
}

as_user() {
  local user="$1"; shift
  run sudo -u "$user" -- "$@"
}

as_user_sh() {
  local user="$1"; shift
  local cmd="$*"
  run sudo -u "$user" -- bash -lc "$cmd"
}

section() { echo; bold "== $*"; }

# ---- args ----
RESTART=1
SHOW_JOURNAL=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-restart) RESTART=0 ;;
    --no-journal) SHOW_JOURNAL=0 ;;
    --help|-h)
      cat <<EOF
Usage: $0 [--no-restart] [--no-journal]

Env overrides:
  BEN_USER, STREAM_USER
  SVC_PIPEWIRE, SVC_CAPTURE, SVC_SUNSHINE, SVC_BRIDGE
  SINK_BRIDGE, SINK_CAPTURE
  LOOPBACK_SUBDEVICE (default: 7)
  JOURNAL_TAIL_LINES (default: 200)
EOF
      exit 0
      ;;
    *) die "unknown arg: $1" ;;
  esac
  shift
done

# ---- requirements ----
need systemctl
need journalctl
need awk
need grep
need sed
need rg || true
need aplay
need arecord

# ---- main ----
section "0) Sanity: users + services"
id "$BEN_USER" >/dev/null 2>&1 || die "user not found: $BEN_USER"
id "$STREAM_USER" >/dev/null 2>&1 || die "user not found: $STREAM_USER"
ok "users exist: $BEN_USER, $STREAM_USER"

section "1) Kernel: snd-aloop present + expected subdevice available"
if ! lsmod | grep -qE '^snd_aloop\b'; then
  die "snd_aloop not loaded. Try: sudo modprobe snd-aloop"
fi
ok "snd_aloop module loaded"

# detect loopback card num
LOOPBACK_CARD="$(awk '$0 ~ /^\s*[0-9]+\s+\[Loopback/ { print $1; exit }' /proc/asound/cards | tr -d ' ')"
[[ -n "$LOOPBACK_CARD" ]] || die "Loopback card not found in /proc/asound/cards"
ok "Loopback card index: $LOOPBACK_CARD"

PLAY_DEV="hw:${LOOPBACK_CARD},0,${LOOPBACK_SUBDEVICE}"
CAPT_DEV="hw:${LOOPBACK_CARD},1,${LOOPBACK_SUBDEVICE}"

# fast hw-param probes (fail-fast)
if ! aplay -D "$PLAY_DEV" --dump-hw-params -f S16_LE -r 48000 -c 2 </dev/null >/dev/null 2>&1; then
  die "ALSA playback device not usable: $PLAY_DEV"
fi
ok "ALSA playback device usable: $PLAY_DEV"

if ! arecord -D "$CAPT_DEV" --dump-hw-params -f S16_LE -r 48000 -c 2 </dev/null >/dev/null 2>&1; then
  die "ALSA capture device not usable: $CAPT_DEV"
fi
ok "ALSA capture device usable: $CAPT_DEV"

section "2) Restart services (ordered) (optional)"
if [[ "$RESTART" -eq 1 ]]; then
  run sudo systemctl daemon-reload

  # stop sunshine first so it doesn't spam while audio is re-plumbed
  run sudo systemctl stop "$SVC_SUNSHINE" >/dev/null 2>&1 || true

  # restart streamdeck audio stack first
  run sudo systemctl restart "$SVC_PIPEWIRE"
  ok "restarted: $SVC_PIPEWIRE"

  run sudo systemctl restart "$SVC_CAPTURE"
  ok "restarted: $SVC_CAPTURE"

  # restart __BUDDY_USER__-side bridge last (depends on __BUDDY_USER__ session + sink monitor existing)
  run sudo systemctl restart "$SVC_BRIDGE"
  ok "restarted: $SVC_BRIDGE"

  # sunshine last
  run sudo systemctl restart "$SVC_SUNSHINE"
  ok "restarted: $SVC_SUNSHINE"
else
  warn "skipping restarts (--no-restart)"
fi

section "3) Checkpoint: __BUDDY_USER__ sink + monitor exist"
# This verifies: PipeWire-Pulse in __BUDDY_USER__ session, null-sink present, monitor source present.
if ! as_user_sh "$BEN_USER" "pactl info >/dev/null"; then
  die "__BUDDY_USER__ cannot talk to pactl (is __BUDDY_USER__ user session active? XDG_RUNTIME_DIR set?)"
fi
ok "__BUDDY_USER__ pactl reachable"

as_user_sh "$BEN_USER" "pactl list sinks short | sed -n '1,200p'" | sed 's/^/  /'
if ! as_user_sh "$BEN_USER" "pactl list sinks short | awk '{print \$2}' | grep -Fxq '$SINK_BRIDGE'"; then
  die "__BUDDY_USER__ missing sink: $SINK_BRIDGE"
fi
ok "__BUDDY_USER__ sink exists: $SINK_BRIDGE"

as_user_sh "$BEN_USER" "pactl list sources short | sed -n '1,200p'" | sed 's/^/  /'
if ! as_user_sh "$BEN_USER" "pactl list sources short | awk '{print \$2}' | grep -Fxq '${SINK_BRIDGE}.monitor'"; then
  die "__BUDDY_USER__ missing monitor source: ${SINK_BRIDGE}.monitor"
fi
ok "__BUDDY_USER__ monitor exists: ${SINK_BRIDGE}.monitor"

section "4) Checkpoint: streamdeck capture sink exists"
# This verifies: streamdeck headless PipeWire-Pulse is up and sink exists.
if ! as_user_sh "$STREAM_USER" "pactl info >/dev/null"; then
  die "streamdeck cannot talk to pactl (pipewire-pulse not ready / env wrong?)"
fi
ok "streamdeck pactl reachable"

as_user_sh "$STREAM_USER" "pactl list sinks short | sed -n '1,200p'" | sed 's/^/  /'
if ! as_user_sh "$STREAM_USER" "pactl list sinks short | awk '{print \$2}' | grep -Fxq '$SINK_CAPTURE'"; then
  die "streamdeck missing sink: $SINK_CAPTURE"
fi
ok "streamdeck sink exists: $SINK_CAPTURE"

section "5) Sunshine audio quick check (config + recent log signal)"
# High-signal: confirm sunshine isn't still complaining about pulseaudio access.
run sudo systemctl status "$SVC_SUNSHINE" --no-pager | sed -n '1,25p'

if run sudo journalctl -u "$SVC_SUNSHINE" -b --no-pager | tail -n 300 | grep -q "Unable to initialize audio capture"; then
  warn "Sunshine still logged: 'Unable to initialize audio capture' (check streamdeck Pulse env + audio_sink name)"
else
  ok "No recent 'Unable to initialize audio capture' in Sunshine logs (last 300 lines)"
fi

section "6) Journals (tail) (optional)"
if [[ "$SHOW_JOURNAL" -eq 1 ]]; then
  for svc in "$SVC_PIPEWIRE" "$SVC_CAPTURE" "$SVC_BRIDGE" "$SVC_SUNSHINE"; do
    echo
    bold "-- journal: $svc (tail $JOURNAL_TAIL_LINES) --"
    run sudo journalctl -u "$svc" -b --no-pager | tail -n "$JOURNAL_TAIL_LINES"
  done
else
  warn "skipping journals (--no-journal)"
fi

section "DONE"
ok "Fast audio bridge retest completed"
echo "If audio is still silent: next suspects are WirePlumber auto-managing snd-aloop or wrong PULSE_SINK/audio_sink wiring."
