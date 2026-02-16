#!/usr/bin/env bash
# Input-pipeline healthcheck: strict PASS/FAIL invariants, no guesswork.
# Usage: check-input-pipeline.sh [LOG_DIR]
#   LOG_DIR optional. If absent: write to /tmp/streamdeck-input-$TIMESTAMP.
#   If present: write input-pipeline-summary.txt and input-pipeline-detail.txt into LOG_DIR.
# Exit: 0 if all strict invariants PASS; non-zero if any FAIL.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$REPO_ROOT/scripts/lib.sh"
# shellcheck source=scripts/load-install-config.sh
source "$REPO_ROOT/scripts/load-install-config.sh"

LOG_DIR="${1:-}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
if [[ -n "$LOG_DIR" ]]; then
    OUT_DIR="$LOG_DIR"
    mkdir -p "$OUT_DIR"
else
    OUT_DIR="/tmp/streamdeck-input-$TIMESTAMP"
    mkdir -p "$OUT_DIR"
fi

DETAIL="$OUT_DIR/input-pipeline-detail.txt"
SUMMARY="$OUT_DIR/input-pipeline-summary.txt"

# Accumulate summary lines and exit codewdwd
SUMMARY_LINES=()
EXIT_CODE=0

section() { echo ""; echo "=== $* ==="; }
append_detail() { echo "$*" >> "$DETAIL"; }
append_summary() { SUMMARY_LINES+=("$1"); }
fail() { append_summary "❌ FAIL: $*"; EXIT_CODE=1; }
pass() { append_summary "✅ PASS: $*"; }
skip() { append_summary "⏭️ SKIP: $*"; }

# Clear detail file and start
: > "$DETAIL"

# Ensure summary is written and printed on exit (including from set -e)
finish() {
    local code=${1:-$EXIT_CODE}
    section "SUMMARY" >> "$DETAIL"
    for line in "${SUMMARY_LINES[@]}"; do
        echo "$line" >> "$DETAIL"
        echo "$line" >> "$SUMMARY"
    done
    cat "$SUMMARY" 2>/dev/null || true
    exit "$code"
}
trap 'finish ${EXIT_CODE:-1}' EXIT

# --- ENV ---
section "ENV" >> "$DETAIL"
{
    echo "OUT_DIR=$OUT_DIR"
    echo "LOG_DIR=${LOG_DIR:-（none）}"
    env | sort
    echo "---"
    whoami
    id
    echo "DISPLAY=${DISPLAY:-（unset）}"
} >> "$DETAIL"

# --- SUNSHINE APP CONFIG DISCOVERY ---
section "SUNSHINE APP CONFIG DISCOVERY" >> "$DETAIL"
APPS_JSON=""
# 1) From systemd unit (SUNSHINE_CONFIG_DIR or --config in ExecStart)
SUNSHINE_UNIT="streamdeck-sunshine.service"
if systemctl cat "$SUNSHINE_UNIT" &>/dev/null; then
    CONFIG_DIR=""
    while IFS= read -r line; do
        if [[ "$line" =~ SUNSHINE_CONFIG_DIR=(.+) ]]; then
            CONFIG_DIR="${BASH_REMATCH[1]}"
            CONFIG_DIR="${CONFIG_DIR%\"}"
            CONFIG_DIR="${CONFIG_DIR#\"}"
            break
        fi
        if [[ "$line" =~ --config[=[:space:]]*([^[:space:]]+) ]]; then
            CONFIG_DIR="${BASH_REMATCH[1]}"
            break
        fi
    done < <(systemctl cat "$SUNSHINE_UNIT" 2>/dev/null)
    if [[ -n "$CONFIG_DIR" ]] && [[ -f "$CONFIG_DIR/apps.json" ]]; then
        APPS_JSON="$CONFIG_DIR/apps.json"
    fi
fi
echo "Checked systemd $SUNSHINE_UNIT for SUNSHINE_CONFIG_DIR/--config" >> "$DETAIL"
# 2) Known paths (stream user and buddy user from install config)
KNOWN_APPS=(
    "/home/$STREAM_USER/.config/sunshine/apps.json"
    "/etc/sunshine/apps.json"
    "/var/lib/sunshine/apps.json"
    "/home/$BUDDY_USER/.config/sunshine/apps.json"
)
for p in "${KNOWN_APPS[@]}"; do
    echo "Checked: $p" >> "$DETAIL"
    if [[ -z "$APPS_JSON" ]] && [[ -f "$p" ]]; then
        APPS_JSON="$p"
    fi
done
if [[ -z "$APPS_JSON" ]]; then
    echo "No apps.json found. Paths checked: systemd unit, ${KNOWN_APPS[*]}" >> "$DETAIL"
    fail "Sunshine apps.json not found"
    exit 1
fi
echo "Using: $APPS_JSON" >> "$DETAIL"
pass "Sunshine apps.json found: $APPS_JSON"

# Read apps.json (may need sudo for stream user's file)
APPS_CONTENT=""
if [[ -r "$APPS_JSON" ]]; then
    APPS_CONTENT="$(cat "$APPS_JSON")"
else
    APPS_CONTENT="$(sudo cat "$APPS_JSON")"
fi
echo "apps.json (first 2k):" >> "$DETAIL"
echo "$APPS_CONTENT" | head -c 2048 >> "$DETAIL"
echo "" >> "$DETAIL"

# --- DEVICE DISCOVERY (Sunshine virtual gamepad) ---
section "DEVICE DISCOVERY" >> "$DETAIL"
SUNSHINE_DEV=""
SUNSHINE_EVENT=""
PRIMARY_MATCH="Sunshine X-Box One (virtual) pad"
for dev in /sys/class/input/event*; do
    [[ -d "$dev" ]] || continue
    name=""
    [[ -f "$dev/device/name" ]] && name="$(cat "$dev/device/name")"
    echo "  $(basename "$dev"): $name" >> "$DETAIL"
    if [[ "$name" == "$PRIMARY_MATCH" ]]; then
        SUNSHINE_DEV="$dev"
        SUNSHINE_EVENT="/dev/input/$(basename "$dev")"
        break
    fi
    if [[ -z "$SUNSHINE_DEV" ]] && echo "$name" | grep -qiE 'sunshine.*(x-?box|virtual|controller)|(x-?box|virtual|controller).*sunshine'; then
        SUNSHINE_DEV="$dev"
        SUNSHINE_EVENT="/dev/input/$(basename "$dev")"
    fi
done
if [[ -z "$SUNSHINE_EVENT" ]]; then
    echo "FAIL: Sunshine virtual gamepad not present; run while Moonlight is connected so Sunshine creates the device" >> "$DETAIL"
    fail "Sunshine virtual gamepad not present; run while Moonlight is connected"
    # Continue to collect xinput, rungameid, steam evidence
else
    echo "Found: $SUNSHINE_EVENT" >> "$DETAIL"
    pass "Sunshine virtual gamepad present: $SUNSHINE_EVENT"
fi

# --- UDEV + PERMS ---
section "UDEV + PERMS" >> "$DETAIL"
UDEV_FAIL=0
if [[ -n "$SUNSHINE_EVENT" ]]; then
    ls -l "$SUNSHINE_EVENT" >> "$DETAIL"
    stat "$SUNSHINE_EVENT" >> "$DETAIL"
    udevadm info -q property -n "$SUNSHINE_EVENT" >> "$DETAIL"
    # GROUP from device node (udev rule sets it; udevadm property may not list GROUP)
    UDEV_GROUP="$(ls -l "$SUNSHINE_EVENT" 2>/dev/null | awk '{print $4}')" || true
    UDEV_TAGS=""
    while IFS= read -r line; do
        if [[ "$line" == TAGS=* ]]; then UDEV_TAGS="${line#TAGS=}"; fi
    done < <(udevadm info -q property -n "$SUNSHINE_EVENT" 2>/dev/null)
    echo "GROUP=$UDEV_GROUP" >> "$DETAIL"
    echo "TAGS=$UDEV_TAGS" >> "$DETAIL"
    if [[ "$UDEV_GROUP" != "$STREAM_GROUP" ]]; then
        echo "Invariant violated: GROUP must be $STREAM_GROUP" >> "$DETAIL"
        fail "udev GROUP is '$UDEV_GROUP', expected $STREAM_GROUP"
        UDEV_FAIL=1
    else
        pass "udev GROUP=$STREAM_GROUP"
    fi
    if echo ",$UDEV_TAGS," | grep -q ',uaccess,'; then
        echo "Invariant violated: uaccess tag must be absent" >> "$DETAIL"
        fail "udev TAGS contain uaccess (desktop could grab device)"
        UDEV_FAIL=1
    else
        pass "udev no uaccess tag"
    fi
else
    echo "No Sunshine device; skipping udev checks" >> "$DETAIL"
    skip "udev (no Sunshine device)"
fi

# --- OPEN HANDLES ---
section "OPEN HANDLES" >> "$DETAIL"
OPEN_FAIL=0
if [[ -n "$SUNSHINE_EVENT" ]]; then
    if command -v lsof &>/dev/null; then
        LSOF_OUT="$(sudo lsof "$SUNSHINE_EVENT" 2>&1)" || true
        echo "$LSOF_OUT" >> "$DETAIL"
        X99_PIDS="$(pgrep -u "$STREAM_USER" -x Xorg 2>/dev/null || true)"
        DESKTOP_HAS_IT=0
        X99_HAS_IT=0
        while IFS= read -r line; do
            [[ -z "$line" ]] || [[ "$line" =~ ^COMMAND ]] || [[ "$line" =~ ^lsof ]] || continue
            pid="$(echo "$line" | awk '{print $2}')"
            [[ -z "$pid" ]] || [[ ! "$pid" =~ ^[0-9]+$ ]] && continue
            comm="$(ps -o comm= -p "$pid" 2>/dev/null || echo "?")"
            echo "  PID $pid ($comm)" >> "$DETAIL"
            if echo "$X99_PIDS" | grep -q "^${pid}$"; then
                X99_HAS_IT=1
            else
                DESKTOP_HAS_IT=1
            fi
        done <<< "$LSOF_OUT"
        if [[ $DESKTOP_HAS_IT -ne 0 ]]; then
            fail "Desktop/compositor has Sunshine device open (leakage)"
            OPEN_FAIL=1
        else
            pass "Desktop does not have Sunshine device open"
        fi
        if [[ $X99_HAS_IT -eq 0 ]] && [[ -n "$X99_PIDS" ]]; then
            fail "Xorg :99 ($STREAM_USER) does not have Sunshine device open"
            OPEN_FAIL=1
        elif [[ $X99_HAS_IT -eq 1 ]]; then
            pass "Xorg :99 has Sunshine device open"
        else
            skip "Xorg :99 not running or no PIDs"
        fi
    elif command -v fuser &>/dev/null; then
        FUSER_OUT="$(sudo fuser -v "$SUNSHINE_EVENT" 2>&1)" || true
        echo "$FUSER_OUT" >> "$DETAIL"
        pass "fuser used (lsof not installed)"
        # Still check who has it
        if echo "$FUSER_OUT" | grep -q "$STREAM_USER"; then
            pass "$STREAM_USER has device (from fuser)"
        else
            fail "$STREAM_USER may not have device; fuser output above"
        fi
    else
        echo "ERROR: neither lsof nor fuser available" >> "$DETAIL"
        fail "lsof and fuser missing; cannot check open handles"
        OPEN_FAIL=1
    fi
else
    echo "No Sunshine device" >> "$DETAIL"
    skip "open handles (no Sunshine device)"
fi

# --- OPEN HANDLES (all Sunshine devices: mouse, keyboard, gamepad, etc.) ---
# Who has each device matters for "cursor not moving in game" vs "linked cursor on desktop"
section "OPEN HANDLES (all Sunshine devices)" >> "$DETAIL"
SUNSHINE_NAMES=(
    "Mouse passthrough"
    "Mouse passthrough (absolute)"
    "Keyboard passthrough"
    "Touch passthrough"
    "Pen passthrough"
    "Sunshine X-Box One (virtual) pad"
)
X99_PIDS_ALL="$(pgrep -u "$STREAM_USER" -x Xorg 2>/dev/null || true)"
DESKTOP_HAS_SUNSHINE=0
FOUND_SUNSHINE_DEVICE=0
for dev in /sys/class/input/event*; do
    [[ -d "$dev" ]] || continue
    [[ -f "$dev/device/name" ]] || continue
    name="$(cat "$dev/device/name")"
    for want in "${SUNSHINE_NAMES[@]}"; do
        if [[ "$name" == "$want" ]]; then
            FOUND_SUNSHINE_DEVICE=1
            ev="/dev/input/$(basename "$dev")"
            echo "--- $ev ($name) ---" >> "$DETAIL"
            # Record device node perms (GROUP=STREAM_GROUP from udev expected)
            ls -l "$ev" >> "$DETAIL" 2>/dev/null || true
            if command -v lsof &>/dev/null; then
                LSOF_ALL="$(sudo lsof "$ev" 2>&1)" || true
                echo "$LSOF_ALL" >> "$DETAIL"
                while IFS= read -r line; do
                    [[ "$line" =~ ^(COMMAND|[[:space:]]*$) ]] && continue
                    pid="$(echo "$line" | awk '{print $2}')"
                    [[ "$pid" =~ ^[0-9]+$ ]] || continue
                    comm="$(ps -o comm= -p "$pid" 2>/dev/null || echo "?")"
                    user="$(ps -o user= -p "$pid" 2>/dev/null || echo "?")"
                    if echo "$X99_PIDS_ALL" | grep -q "^${pid}$"; then
                        echo "  -> PID $pid ($comm) user=$user [Xorg :99]" >> "$DETAIL"
                    else
                        echo "  -> PID $pid ($comm) user=$user" >> "$DETAIL"
                        # Desktop leakage: non-root, non-stream process has Sunshine device open
                        if [[ "$user" != "root" ]] && [[ "$user" != "$STREAM_USER" ]]; then
                            DESKTOP_HAS_SUNSHINE=1
                        fi
                    fi
                done <<< "$LSOF_ALL"
            fi
            break
        fi
    done
done
if [[ $DESKTOP_HAS_SUNSHINE -ne 0 ]]; then
    fail "Desktop has Sunshine input devices open (trackpad moves PC cursor)"
elif [[ $FOUND_SUNSHINE_DEVICE -ne 0 ]]; then
    pass "Desktop does not have Sunshine input devices open"
fi

# --- XORG :99 (XINPUT) ---
section "XORG :99 (XINPUT)" >> "$DETAIL"
XAUTHORITY_PATH=""
for pid in $(pgrep -x Xorg 2>/dev/null); do
    cmd="$(ps eww -p "$pid" 2>/dev/null | tr '\0' '\n' | grep -E '^-auth|Xorg.*:99' || true)"
    if ps -o args= -p "$pid" 2>/dev/null | grep -q ':99'; then
        if echo "$cmd" | grep -qE '\-auth'; then
            XAUTHORITY_PATH="$(ps eww -p "$pid" 2>/dev/null | tr '\0' '\n' | grep -oE '\-auth[[:space:]]+[^[:space:]]+' | head -1 | awk '{print $2}')"
        fi
        break
    fi
done
[[ -z "$XAUTHORITY_PATH" ]] && XAUTHORITY_PATH="/home/$STREAM_USER/.Xauthority"
echo "XAUTHORITY_PATH=$XAUTHORITY_PATH" >> "$DETAIL"
if ! command -v xinput &>/dev/null; then
    echo "xinput not installed" >> "$DETAIL"
    skip "xinput not installed"
else
    XINPUT_OUT="$OUT_DIR/xinput-list.txt"
    if sudo -u "$STREAM_USER" env DISPLAY=:99 XAUTHORITY="$XAUTHORITY_PATH" xinput list &> "$XINPUT_OUT"; then
        cat "$XINPUT_OUT" >> "$DETAIL"
        pass "xinput list (Xorg :99) succeeded"
    else
        cat "$XINPUT_OUT" >> "$DETAIL"
        fail "xinput list failed (see detail)"
    fi
fi

# --- STEAM LAUNCH EVIDENCE (LOG_DIR) ---
section "STEAM LAUNCH EVIDENCE (LOG_DIR)" >> "$DETAIL"
if [[ -z "$LOG_DIR" ]]; then
    echo "LOG_DIR not provided" >> "$DETAIL"
    skip "LOG_DIR not provided; no Steam logs to read"
else
    STEAM_LOGS_DIR="$LOG_DIR/steam-logs"
    if [[ ! -d "$STEAM_LOGS_DIR" ]]; then
        echo "ERROR: Steam logs not found in LOG_DIR; collect-logs.sh did not capture them" >> "$DETAIL"
        echo "ERROR: Steam logs not found in LOG_DIR; collect-logs.sh did not capture them" >&2
        fail "Steam logs not in LOG_DIR"
        exit 1
    fi
    STEAM_EVIDENCE=""
    for f in "$STEAM_LOGS_DIR"/*.txt "$STEAM_LOGS_DIR"/*.log; do
        [[ -f "$f" ]] || continue
        STEAM_EVIDENCE="${STEAM_EVIDENCE}$(grep -iE 'rungameid|GameAction|Running AppID|Launching' "$f" 2>/dev/null || true)"
    done
    echo "Steam log files: $(ls "$STEAM_LOGS_DIR" 2>/dev/null)" >> "$DETAIL"
    echo "Evidence (grep rungameid|GameAction|Running AppID|Launching):" >> "$DETAIL"
    echo "$STEAM_EVIDENCE" >> "$DETAIL"
    if [[ -z "$STEAM_EVIDENCE" ]]; then
        fail "No Steam launch evidence in LOG_DIR steam-logs"
    else
        pass "Steam launch evidence found in LOG_DIR"
    fi
fi

# --- EVTEST (optional) ---
section "EVTEST (optional)" >> "$DETAIL"
if ! command -v evtest &>/dev/null; then
    echo "evtest not installed" >> "$DETAIL"
    skip "evtest not installed"
else
    if [[ -n "$SUNSHINE_EVENT" ]]; then
        echo "Press A now (2 seconds)..." >> "$DETAIL"
        echo "Press A now (2 seconds)..." >&2
        timeout 2 sudo evtest "$SUNSHINE_EVENT" 2>> "$DETAIL" >> "$DETAIL" || true
        pass "evtest 2s sample captured"
    else
        skip "evtest (no Sunshine device)"
    fi
fi

# Normal exit: trap will write SUMMARY and exit with EXIT_CODE
exit $EXIT_CODE
