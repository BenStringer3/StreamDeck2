#!/bin/bash
# Experiment: Prove an ALSA loopback "narrow bridge" works cross-user.
#
# Goal
# - Keep Sunshine as `streamdeck` and Steam as `__BUDDY_USER__`
# - Avoid any cross-user access to __BUDDY_USER__'s PipeWire/Pulse runtime sockets
# - Instead, bridge audio via a kernel device: `snd-aloop` (ALSA loopback)
#
# Hypothesis
# - If __BUDDY_USER__ can play audio INTO an ALSA loopback playback device and streamdeck can
#   record FROM the paired capture device, then we have a viable "narrow bridge".
# - Next step (not done here): route Steam's output to the loopback sink node.
#
# What this experiment does
# - Loads `snd-aloop` (non-persistent) if not already loaded
# - Records from ALSA loopback as `streamdeck`
# - Plays a known WAV as `__BUDDY_USER__` using:
#   - Test A: Pulse/PipeWire (`paplay`) routed to the loopback sink (preferred)
#   - Test B: Direct ALSA (`aplay`) to loopback playback device (control)
# - Verifies the recording is not silent using ffmpeg's `volumedetect`
#
# Safety / invariants
# - No permanent system config changes are made.
# - Does not change default sinks/sources.
#
# Run:
#   sudo ./experiment-audio-alsa-loopback-bridge.sh
#
# Expected outcomes
# - PASS Test A: proves __BUDDY_USER__'s Pulse/PipeWire can feed loopback and streamdeck can capture.
# - PASS Test B only: proves device-level bridge works, but Pulse routing to loopback needs work.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"
source "$REPO_ROOT/scripts/lib.sh"

STREAMDECK_USER="streamdeck"
BEN_USER="__BUDDY_USER__"

BEN_UID="$(id -u "$BEN_USER")"
STREAMDECK_UID="$(id -u "$STREAMDECK_USER")"

BEN_XDG_RUNTIME_DIR="/run/user/${BEN_UID}"

ALSA_LOOPBACK_CARD_INDEX=""
ALSA_LOOPBACK_PLAYBACK_DEVICE_INDEX="0"
ALSA_LOOPBACK_CAPTURE_DEVICE_INDEX="1"
ALSA_LOOPBACK_SUBDEVICE_COUNT="8"

RECORD_SECONDS="${RECORD_SECONDS:-6}"
SAMPLE_WAV=""

assert_root
assert_command sudo
assert_command modprobe
assert_command arecord
assert_command aplay
assert_command pactl
assert_command paplay
assert_command python3
assert_command ffmpeg

log_info "=== Experiment: ALSA Loopback Narrow Bridge ==="

KERNEL_RELEASE="$(uname -r)"
KERNEL_MODULE_DIR="/usr/lib/modules/${KERNEL_RELEASE}"
if [[ ! -d "$KERNEL_MODULE_DIR" ]]; then
  log_error "Kernel/module mismatch: running kernel is '$KERNEL_RELEASE' but '$KERNEL_MODULE_DIR' does not exist."
  log_error "Installed module trees under /usr/lib/modules are:"
  # shellcheck disable=SC2012
  ls -1 /usr/lib/modules 2>/dev/null || true
  log_fatal "Reboot into the installed kernel (or install matching modules for the running kernel), then rerun this experiment."
fi

if ! id "$STREAMDECK_USER" &>/dev/null; then
  log_fatal "User '$STREAMDECK_USER' does not exist"
fi
if ! id "$BEN_USER" &>/dev/null; then
  log_fatal "User '$BEN_USER' does not exist"
fi

log_info "Selecting a test WAV file..."
if [[ -f "/usr/share/sounds/alsa/Front_Center.wav" ]]; then
  SAMPLE_WAV="/usr/share/sounds/alsa/Front_Center.wav"
elif [[ -f "/usr/share/sounds/alsa/Noise.wav" ]]; then
  SAMPLE_WAV="/usr/share/sounds/alsa/Noise.wav"
else
  log_fatal "No known ALSA sample WAV found under /usr/share/sounds/alsa/. Install 'alsa-utils' samples or provide SAMPLE_WAV."
fi
log_info "✓ Using sample WAV: $SAMPLE_WAV"

log_info "Checking/Loading snd-aloop..."
if lsmod | awk '{print $1}' | grep -qx "snd_aloop"; then
  log_info "✓ snd_aloop already loaded"
  LOADED_BY_SCRIPT="no"
else
  modprobe snd-aloop
  log_info "✓ Loaded snd_aloop"
  LOADED_BY_SCRIPT="yes"
fi

log_info "Detecting ALSA Loopback card index..."
ALSA_LOOPBACK_CARD_INDEX="$(
  awk '
    $0 ~ /^\s*[0-9]+\s+\[Loopback/ { print $1; exit }
  ' /proc/asound/cards | tr -d ' '
)" || true
if [[ -z "${ALSA_LOOPBACK_CARD_INDEX:-}" ]]; then
  log_error "Could not find Loopback card in /proc/asound/cards."
  log_error "Current /proc/asound/cards:"
  sed -n '1,120p' /proc/asound/cards >&2 || true
  log_fatal "snd_aloop is loaded but ALSA Loopback card is not present."
fi
log_info "✓ Loopback card index is: $ALSA_LOOPBACK_CARD_INDEX"

# Fail-fast: the loopback devices are root:audio 0660 on Arch by default.
# If streamdeck is not in the 'audio' group, arecord/aplay will fail (often with misleading "No such file" errors).
if ! id -nG "$STREAMDECK_USER" | tr ' ' '\n' | grep -qx "audio"; then
  log_error "User '$STREAMDECK_USER' is not in the 'audio' group, so it cannot access /dev/snd/*."
  log_error "Fix:"
  log_error "  sudo usermod -aG audio $STREAMDECK_USER"
  log_error "Then restart Sunshine (so it picks up new groups):"
  log_error "  sudo systemctl restart streamdeck-sunshine.service"
  log_fatal "Rerun this experiment after applying the fix."
fi

# snd-aloop exposes two PCM devices on that card: device 0 and device 1.
# Conventionally, to loop audio you play to device 0 and record from device 1.
#
# Use plughw to allow format/rate conversion. Raw hw devices can be finicky and often
# produce misleading I/O errors if parameters don't match what the other side negotiated.
ALSA_LOOPBACK_PLAYBACK_DEV="plughw:${ALSA_LOOPBACK_CARD_INDEX},0,0"
ALSA_LOOPBACK_CAPTURE_DEV="plughw:${ALSA_LOOPBACK_CARD_INDEX},1,0"
log_info "Using loopback ALSA card index: $ALSA_LOOPBACK_CARD_INDEX"

LOOPBACK_CTL_NODE="/dev/snd/controlC${ALSA_LOOPBACK_CARD_INDEX}"
if [[ -e "$LOOPBACK_CTL_NODE" ]]; then
  if ! sudo -u "$STREAMDECK_USER" test -r "$LOOPBACK_CTL_NODE"; then
    log_error "User '$STREAMDECK_USER' still cannot read '$LOOPBACK_CTL_NODE'."
    log_error "Check /dev/snd permissions and group membership."
    ls -la "$LOOPBACK_CTL_NODE" >&2 || true
    log_fatal "Cannot proceed with loopback capture test."
  fi
else
  log_warn "Expected loopback control node not found: $LOOPBACK_CTL_NODE"
fi

log_info "Verifying Loopback appears in ALSA device list (as streamdeck)..."
if ! sudo -u "$STREAMDECK_USER" aplay -l 2>/dev/null | grep -q "card ${ALSA_LOOPBACK_CARD_INDEX}:"; then
  log_warn "Loopback card did not appear in 'aplay -l' output for $STREAMDECK_USER."
  log_warn "Continuing anyway; numeric hw: devices may still work."
fi

log_info "Checking streamdeck can access ALSA devices..."
if ! sudo -u "$STREAMDECK_USER" aplay -l &>/dev/null; then
  log_error "streamdeck cannot access ALSA devices (likely missing permissions)."
  log_error "Check: is streamdeck in 'audio' group? Do /dev/snd/* permissions allow access?"
  log_fatal "Cannot proceed with loopback capture test."
fi
log_info "✓ streamdeck can enumerate ALSA devices"

log_info "Finding Pulse/PipeWire sink corresponding to ALSA Loopback (as __BUDDY_USER__)..."
if ! sudo -u "$BEN_USER" env XDG_RUNTIME_DIR="$BEN_XDG_RUNTIME_DIR" pactl info &>/dev/null; then
  log_warn "Cannot connect to __BUDDY_USER__'s Pulse/PipeWire via pactl (likely no active per-user audio server in this session)."
  log_warn "Test A (paplay -> loopback sink) will be SKIPPED."
  TEST_A="SKIP"
else
LOOPBACK_PULSE_SINK="$(
  sudo -u "$BEN_USER" env XDG_RUNTIME_DIR="$BEN_XDG_RUNTIME_DIR" python3 - <<'PY'
import json, subprocess, sys

def run(cmd):
    return subprocess.check_output(cmd, text=True)

data = json.loads(run(["pactl", "-f", "json", "list", "sinks"]))

def sink_matches(s):
    props = s.get("properties") or {}
    # PipeWire tends to expose ALSA device strings and/or ALSA card names.
    ds = str(props.get("device.string", ""))
    cn = str(props.get("alsa.card_name", ""))
    dn = str(props.get("device.description", ""))
    name = str(s.get("name", ""))
    hay = " | ".join([ds, cn, dn, name]).lower()
    return "loopback" in hay or "snd_aloop" in hay

for s in data:
    if sink_matches(s) and s.get("name"):
        print(s["name"])
        sys.exit(0)

sys.exit(2)
PY
)" || true

if [[ -z "${LOOPBACK_PULSE_SINK:-}" ]]; then
  log_warn "Could not auto-detect a Pulse/PipeWire sink for ALSA Loopback."
  log_warn "Test A (paplay -> loopback sink) will be SKIPPED."
  TEST_A="SKIP"
else
  log_info "✓ Detected loopback sink: $LOOPBACK_PULSE_SINK"
  TEST_A="PENDING"

  # The sink name typically encodes the ALSA device index for snd_aloop (e.g. snd_aloop.0).
  # We'll try to extract it so our capture uses the matching ALSA PCM device.
  if [[ "$LOOPBACK_PULSE_SINK" =~ snd_aloop\.([0-9]+)\. ]]; then
    ALSA_LOOPBACK_PLAYBACK_DEVICE_INDEX="${BASH_REMATCH[1]}"
  else
    ALSA_LOOPBACK_PLAYBACK_DEVICE_INDEX="0"
  fi
  # snd-aloop wiring (typical): playback on device 0 -> capture on device 1, and vice-versa.
  # We infer which device PipeWire is PLAYING into, then record from the opposite device's CAPTURE.
  if [[ "$ALSA_LOOPBACK_PLAYBACK_DEVICE_INDEX" == "0" ]]; then
    ALSA_LOOPBACK_CAPTURE_DEVICE_INDEX="1"
  elif [[ "$ALSA_LOOPBACK_PLAYBACK_DEVICE_INDEX" == "1" ]]; then
    ALSA_LOOPBACK_CAPTURE_DEVICE_INDEX="0"
  else
    ALSA_LOOPBACK_CAPTURE_DEVICE_INDEX="1"
  fi

  log_info "✓ Inferred loopback ALSA playback device index: $ALSA_LOOPBACK_PLAYBACK_DEVICE_INDEX"
  log_info "✓ Using loopback ALSA capture device index:    $ALSA_LOOPBACK_CAPTURE_DEVICE_INDEX"
fi
fi

WORK_DIR="/tmp/streamdeck-audio-loopback-experiment"
mkdir -p "$WORK_DIR"
chmod 1777 "$WORK_DIR" || true

analyze_wav_or_fail() {
  local test_name="$1"
  local out_wav="$2"
  local ffmpeg_log="$3"

  log_info "[$test_name] Analyzing recorded audio (ffmpeg volumedetect)..."
  # volumedetect prints to stderr.
  if ! ffmpeg -hide_banner -nostdin -i "$out_wav" -af volumedetect -f null - 2>"$ffmpeg_log" >/dev/null; then
    log_error "[$test_name] ffmpeg analysis failed"
    return 2
  fi

  local mean_volume
  local max_volume
  mean_volume="$(awk -F': ' '/mean_volume:/ {print $2}' "$ffmpeg_log" | tail -n1 || true)"
  max_volume="$(awk -F': ' '/max_volume:/ {print $2}' "$ffmpeg_log" | tail -n1 || true)"
  if [[ -z "$max_volume" ]]; then
    log_error "[$test_name] Could not parse max_volume from volumedetect output"
    return 2
  fi

  if [[ "$max_volume" == "-inf dB" ]]; then
    log_error "[$test_name] Recording appears silent (max_volume = -inf dB)"
    return 1
  fi

  # Guardrail: treat extremely low levels as failure. The bundled ALSA sample WAV should
  # produce peaks far above -60 dB if the bridge is actually carrying the signal.
  local max_db
  max_db="$(printf '%s' "$max_volume" | awk '{print $1}')"
  if awk -v v="$max_db" 'BEGIN { exit !(v <= -60.0) }'; then
    log_error "[$test_name] Recording level is implausibly low (max_volume = $max_volume, mean_volume = ${mean_volume:-unknown})"
    log_error "[$test_name] This usually means the bridge is not actually carrying the played audio."
    return 1
  fi

  log_info "[$test_name] ✓ Recording has signal (max_volume = $max_volume, mean_volume = ${mean_volume:-unknown})"
  return 0
}

record_and_analyze() {
  local test_name="$1"
  local alsa_capture_dev="$2"
  local play_cmd_desc="$3"
  shift 3

  local out_wav="$WORK_DIR/${test_name}.wav"
  local ffmpeg_log="$WORK_DIR/${test_name}.volumedetect.log"

  log_info ""
  log_info "[$test_name] Recording from $alsa_capture_dev as $STREAMDECK_USER..."

  rm -f "$out_wav" "$ffmpeg_log"

  # Start capture first, then play into loopback during the capture window.
  sudo -u "$STREAMDECK_USER" arecord -q -D "$alsa_capture_dev" -f S16_LE -r 48000 -c 2 -d "$RECORD_SECONDS" "$out_wav" &
  local rec_pid=$!

  # Give arecord a moment to open the device.
  sleep 0.4

  log_info "[$test_name] Playing ($play_cmd_desc)..."
  set +e
  "$@"
  local play_rc=$?
  set -e

  wait "$rec_pid" || true

  if [[ $play_rc -ne 0 ]]; then
    log_error "[$test_name] Play command failed with exit code $play_rc"
    return 2
  fi

  if [[ ! -f "$out_wav" ]]; then
    log_error "[$test_name] Recording was not created: $out_wav"
    return 2
  fi

  analyze_wav_or_fail "$test_name" "$out_wav" "$ffmpeg_log"
}

# Test A: Pulse/PipeWire -> ALSA Loopback sink node (preferred because Steam uses Pulse/PipeWire)
if [[ "$TEST_A" == "PENDING" ]]; then
  TEST_A="FAIL"

  log_info ""
  log_info "[test-a] Verifying loopback sink exists in pactl..."
  if ! sudo -u "$BEN_USER" env XDG_RUNTIME_DIR="$BEN_XDG_RUNTIME_DIR" pactl list sinks short 2>/dev/null | awk '{print $2}' | grep -qx "$LOOPBACK_PULSE_SINK"; then
    log_error "[test-a] Expected sink not present: $LOOPBACK_PULSE_SINK"
    log_error "[test-a] pactl list sinks short:"
    sudo -u "$BEN_USER" env XDG_RUNTIME_DIR="$BEN_XDG_RUNTIME_DIR" pactl list sinks short 2>/dev/null >&2 || true
    TEST_A="FAIL"
  else
    log_info "[test-a] ✓ Sink exists: $LOOPBACK_PULSE_SINK"
  fi

  # Try subdevices 0..7; PipeWire may keep one substream reserved, and aloop wiring can be
  # sensitive to substream pairing. We'll accept the first subdevice that yields a real signal.
  for subdev in $(seq 0 7); do
    ALSA_CAPTURE_DEV="plughw:${ALSA_LOOPBACK_CARD_INDEX},${ALSA_LOOPBACK_CAPTURE_DEVICE_INDEX},${subdev}"
    log_info ""
    log_info "[test-a] Trying capture subdevice $subdev: $ALSA_CAPTURE_DEV"
    if record_and_analyze \
      "test-a_pulse_to_loopback_sub${subdev}" \
      "$ALSA_CAPTURE_DEV" \
      "paplay (__BUDDY_USER__) routed to $LOOPBACK_PULSE_SINK" \
      sudo -u "$BEN_USER" env XDG_RUNTIME_DIR="$BEN_XDG_RUNTIME_DIR" paplay --device="$LOOPBACK_PULSE_SINK" "$SAMPLE_WAV"
    then
      TEST_A="PASS"
      TEST_A_SUBDEV="$subdev"
      break
    else
      rc=$?
      if [[ $rc -eq 1 ]]; then
        TEST_A="SILENT"
      else
        TEST_A="FAIL"
      fi
    fi
  done
fi

# Test B: Direct ALSA -> ALSA Loopback (control path, bypasses Pulse/PipeWire entirely)
TEST_B="FAIL"
TEST_B_SUBDEV="7"
ALSA_PLAYBACK_DEV="plughw:${ALSA_LOOPBACK_CARD_INDEX},0,${TEST_B_SUBDEV}"
ALSA_CAPTURE_DEV="plughw:${ALSA_LOOPBACK_CARD_INDEX},1,${TEST_B_SUBDEV}"

# For direct ALSA, PipeWire may already have subdev 0 in use. Use a high subdevice to reduce collisions.
log_info ""
log_info "[test-b] Using subdevice $TEST_B_SUBDEV for both play/capture:"
log_info "[test-b]  playback: $ALSA_PLAYBACK_DEV"
log_info "[test-b]  capture:  $ALSA_CAPTURE_DEV"

if record_and_analyze \
  "test-b_direct_alsa_to_loopback" \
  "$ALSA_CAPTURE_DEV" \
  "aplay (__BUDDY_USER__) to $ALSA_PLAYBACK_DEV" \
  sudo -u "$BEN_USER" aplay -q -D "$ALSA_PLAYBACK_DEV" "$SAMPLE_WAV"
then
  TEST_B="PASS"
else
  rc=$?
  if [[ $rc -eq 1 ]]; then
    TEST_B="SILENT"
  else
    TEST_B="FAIL"
  fi
fi

log_info ""
log_info "=== SUMMARY ==="
log_info "Test A (Pulse/PipeWire -> Loopback -> streamdeck capture): ${TEST_A:-SKIP}"
if [[ "${TEST_A:-SKIP}" == "PASS" ]]; then
  log_info "Test A capture subdevice: ${TEST_A_SUBDEV:-unknown}"
fi
log_info "Test B (Direct ALSA -> Loopback -> streamdeck capture): $TEST_B"
log_info ""

if [[ "${TEST_A:-SKIP}" == "PASS" ]]; then
  log_info "Conclusion: Narrow bridge is viable for Steam: __BUDDY_USER__ can feed loopback via Pulse/PipeWire and streamdeck can capture via ALSA."
  log_info "Next: route Steam/game audio to the loopback sink node (set default sink before launching Steam or move the Steam sink-input)."
elif [[ "$TEST_B" == "PASS" && "${TEST_A:-SKIP}" != "PASS" ]]; then
  log_warn "Conclusion: Device-level bridge works, but Pulse/PipeWire routing into loopback didn't pass."
  log_warn "Next: ensure PipeWire sees snd_aloop as an output sink for __BUDDY_USER__ and that PULSE_SINK points at it."
else
  log_error "Conclusion: Loopback bridge not proven. Fix ALSA permissions and/or snd_aloop visibility first."
fi

