#!/bin/bash
# Experiment: Can we launch TOTK via Eden using the same command/env Sunshine uses?
#
# Hypothesis: The apps.json "TOTK (Eden)" command (sudo -u __BUDDY_USER__, DISPLAY=:99, session env,
# eden -g "<path>") starts Eden with the game. If the process is running after a few
# seconds, the launch path is valid.
#
# Prereq: Display :99 should be active (streamdeck-xorg.service). If not, Eden may
# fail with "cannot open display".
#
# Run: ./experiment-eden-totk.sh   (no sudo; we use sudo only for the inner launch)

set -euo pipefail

EDEN_BINARY="${EDEN_BINARY:-/usr/bin/eden}"
TOTK_GAME_PATH="${TOTK_GAME_PATH:-/home/__BUDDY_USER__/Emulation/roms/switch/The Legend of Zelda: Tears of the Kingdom.xci}"
LAUNCH_WAIT=5

if [[ ! -x "$EDEN_BINARY" ]]; then
  echo "ERROR: Eden not found or not executable: $EDEN_BINARY"
  exit 1
fi
if [[ ! -e "$TOTK_GAME_PATH" ]]; then
  echo "ERROR: TOTK path not found: $TOTK_GAME_PATH"
  exit 1
fi

# Same env and command that Sunshine would run (from apps.json)
export DISPLAY="${DISPLAY:-:99}"

echo "[INFO] Hypothesis: Launching Eden with TOTK via Sunshine-style command succeeds."
echo "[INFO] DISPLAY=$DISPLAY  EDEN_BINARY=$EDEN_BINARY"
echo "[INFO] TOTK_GAME_PATH=$TOTK_GAME_PATH"
echo "[INFO] Starting launch in background; will check for process after ${LAUNCH_WAIT}s then kill."
echo ""

# Run the launch in background; capture stderr to see immediate failures
LAUNCH_LOG=$(mktemp)
trap 'rm -f "$LAUNCH_LOG"' EXIT

sudo -u __BUDDY_USER__ env HOME=/home/__BUDDY_USER__ USER=__BUDDY_USER__ XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus PULSE_SINK=StreamDeck-Bridge DISPLAY="$DISPLAY" "$EDEN_BINARY" -g "$TOTK_GAME_PATH" </dev/null >> "$LAUNCH_LOG" 2>&1 &
disown

# Give Eden time to start (and possibly fail fast)
sleep "$LAUNCH_WAIT"

# Check for Eden process owned by __BUDDY_USER__ (any eden from this launch)
BEN_UID=$(id -u __BUDDY_USER__ 2>/dev/null || true)
if [[ -z "$BEN_UID" ]]; then
  echo "[WARN] User __BUDDY_USER__ not found; checking for any eden process."
  EDEN_PIDS=$(pgrep -f "eden" || true)
else
  EDEN_PIDS=$(pgrep -u __BUDDY_USER__ -f "eden" || true)
fi

if [[ -n "$EDEN_PIDS" ]]; then
  echo "[INFO] Eden process(es) found: $EDEN_PIDS"
  # Delegate kill to a detached process so we exit before Eden is killed (killing it can SIGKILL our process group)
  nohup bash -c "kill $EDEN_PIDS 2>/dev/null; sleep 1; kill -9 $EDEN_PIDS 2>/dev/null" </dev/null >/dev/null 2>&1 &
  disown
  echo "[PASS] Launch validated: Eden was running after ${LAUNCH_WAIT}s."
  exit 0
fi

# No process: either exited early or never started
echo "[FAIL] No Eden process after ${LAUNCH_WAIT}s."
echo "[INFO] Launch log (stderr/stdout):"
cat "$LAUNCH_LOG" || true
echo ""
echo "If DISPLAY=:99 is not active, start streamdeck-xorg.service and retry."
exit 1
