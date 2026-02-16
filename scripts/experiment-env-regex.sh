#!/bin/bash
# Experiment: ENV regex shared-memory — does MoonDeckStream read Buddy's ENV regex
# when run on DISPLAY=:99 (Sunshine) vs same user's desktop DISPLAY?
#
# Hypothesis: Buddy (desktop session) and MoonDeckStream (Sunshine on :99) use
# shared memory keyed by something that differs by session/display, so MoonDeckStream
# on :99 cannot read the segment Buddy wrote → "Failed to read ENV regex from shared memory!"
#
# Steps:
#   1. Ensure Buddy is running; kill any MoonDeckStream.
#   2. Phase A: Run MoonDeckStream with DISPLAY=:99 (Sunshine env), ~5s, SIGTERM.
#      Capture /tmp/moondeckstream.log excerpt; grep for "ENV regex" / "Failed to read".
#   3. Phase B: Run MoonDeckStream with DISPLAY=<desktop> (e.g. :0), same env otherwise, ~5s, SIGTERM.
#      Capture log excerpt; grep for ENV regex.
#   4. Compare: which phase (if any) shows "Got the following ENV regex from Buddy"?
#
# Requires: sudo (to run as Buddy user with controlled env). Buddy must be active.
# Output: logs/experiment-env-regex-<timestamp>/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$REPO_ROOT/scripts/lib.sh"
# shellcheck source=scripts/load-install-config.sh
source "$REPO_ROOT/scripts/load-install-config.sh"

if [[ $EUID -ne 0 ]]; then
    log_fatal "Run with sudo: sudo $REPO_ROOT/scripts/experiment-env-regex.sh [DESKTOP_DISPLAY]"
fi
if ! id "$BUDDY_USER" &>/dev/null; then
    log_fatal "Buddy user $BUDDY_USER not found. Set BUDDY_USER or create the user."
fi
BUDDY_UID=$(id -u "$BUDDY_USER")
# Optional: desktop DISPLAY for Phase B (default :0; use "" to skip Phase B)
DESKTOP_DISPLAY="${1:-:0}"
OUTPUT_DIR="${REPO_ROOT}/logs/experiment-env-regex-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUTPUT_DIR"

MOONDECK_LOG="/tmp/moondeckstream.log"
RUN_DURATION=5

log_info "=========================================="
log_info "Experiment: ENV regex (DISPLAY :99 vs desktop)"
log_info "=========================================="
log_info "Hypothesis: MoonDeckStream on DISPLAY=:99 cannot read Buddy's ENV regex shm (session/display key mismatch)."
log_info "Output dir: $OUTPUT_DIR"
log_info "Buddy user: $BUDDY_USER (UID $BUDDY_UID)"
log_info "Phase B DISPLAY: ${DESKTOP_DISPLAY:-<skip>}"
log_info ""

# -----------------------------------------------------------------------------
# Prereqs: Buddy running, no MoonDeckStream
# -----------------------------------------------------------------------------
log_info "Prereqs: Checking Buddy and stopping any MoonDeckStream..."
if ! sudo -u "$BUDDY_USER" XDG_RUNTIME_DIR="/run/user/$BUDDY_UID" systemctl --user is-active moondeckbuddy.service &>/dev/null; then
    log_fatal "MoonDeck Buddy is not running. Start it: sudo -u $BUDDY_USER systemctl --user start moondeckbuddy.service"
fi
log_info "Buddy is active."
pkill -u "$BUDDY_USER" -x MoonDeckStream 2>/dev/null || true
sleep 2
log_info "Any stale MoonDeckStream stopped."
log_info ""

# Helper: run MoonDeckStream with given DISPLAY, capture log excerpt
# Usage: run_phase <phase_name> <DISPLAY_value>
run_phase() {
    local phase_name="$1"
    local display_val="$2"
    local log_before lines_before
    if [[ -f "$MOONDECK_LOG" ]]; then
        lines_before=$(wc -l < "$MOONDECK_LOG")
    else
        lines_before=0
    fi

    log_info "Phase $phase_name: Running MoonDeckStream with DISPLAY=$display_val for ${RUN_DURATION}s..."
    sudo -u "$BUDDY_USER" \
        HOME="/home/$BUDDY_USER" \
        USER="$BUDDY_USER" \
        XDG_RUNTIME_DIR="/run/user/$BUDDY_UID" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$BUDDY_UID/bus" \
        DISPLAY="$display_val" \
        SUNSHINE_LAUNCHED=1 \
        __NV_PRIME_RENDER_OFFLOAD=1 \
        __GLX_VENDOR_LIBRARY_NAME=nvidia \
        __VK_LAYER_NV_optimus=NVIDIA_only \
        /usr/local/bin/MoonDeckStream \
        >> "$OUTPUT_DIR/${phase_name}-stdout.txt" 2>> "$OUTPUT_DIR/${phase_name}-stderr.txt" &
    local pid=$!
    sleep "$RUN_DURATION"
    kill -TERM "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    sleep 1

    # Capture new lines from MoonDeckStream's log (it appends)
    if [[ -f "$MOONDECK_LOG" ]]; then
        local lines_after
        lines_after=$(wc -l < "$MOONDECK_LOG")
        if [[ "$lines_after" -gt "$lines_before" ]]; then
            tail -n "+$((lines_before + 1))" "$MOONDECK_LOG" > "$OUTPUT_DIR/${phase_name}-moondeckstream-log-excerpt.txt"
        else
            echo "(no new lines in $MOONDECK_LOG)" > "$OUTPUT_DIR/${phase_name}-moondeckstream-log-excerpt.txt"
        fi
    else
        echo "(log file $MOONDECK_LOG not present)" > "$OUTPUT_DIR/${phase_name}-moondeckstream-log-excerpt.txt"
    fi
    log_info "Phase $phase_name done."
}

# -----------------------------------------------------------------------------
# Phase A: DISPLAY=:99 (Sunshine-like)
# -----------------------------------------------------------------------------
run_phase "A" ":99"
log_info ""

# -----------------------------------------------------------------------------
# Phase B: DISPLAY=desktop (:0 or user-provided)
# -----------------------------------------------------------------------------
if [[ -n "$DESKTOP_DISPLAY" ]]; then
    run_phase "B" "$DESKTOP_DISPLAY"
    log_info ""
fi

# -----------------------------------------------------------------------------
# Findings: grep ENV regex in each excerpt
# -----------------------------------------------------------------------------
log_info "Analyzing ENV regex lines..."
{
    echo "=========================================="
    echo "ENV regex experiment — findings"
    echo "=========================================="
    echo "Output dir: $OUTPUT_DIR"
    echo "Buddy user: $BUDDY_USER (UID $BUDDY_UID)"
    echo "Phase B DISPLAY: ${DESKTOP_DISPLAY:-<skipped>}"
    echo ""
    echo "=== Phase A (DISPLAY=:99) — ENV regex result ==="
    if grep -q "Failed to read ENV regex" "$OUTPUT_DIR/A-moondeckstream-log-excerpt.txt" 2>/dev/null; then
        echo "  Result: FAILED TO READ ENV regex (expected for Sunshine/:99)"
        grep "ENV regex" "$OUTPUT_DIR/A-moondeckstream-log-excerpt.txt" 2>/dev/null || true
    elif grep -q "Got the following ENV regex" "$OUTPUT_DIR/A-moondeckstream-log-excerpt.txt" 2>/dev/null; then
        echo "  Result: GOT ENV regex from Buddy (unexpected on :99)"
        grep "ENV regex" "$OUTPUT_DIR/A-moondeckstream-log-excerpt.txt" 2>/dev/null || true
    else
        echo "  Result: no ENV regex line in excerpt (check A-moondeckstream-log-excerpt.txt)"
        cat "$OUTPUT_DIR/A-moondeckstream-log-excerpt.txt" 2>/dev/null || true
    fi
    echo ""

    if [[ -n "$DESKTOP_DISPLAY" ]] && [[ -f "$OUTPUT_DIR/B-moondeckstream-log-excerpt.txt" ]]; then
        echo "=== Phase B (DISPLAY=$DESKTOP_DISPLAY) — ENV regex result ==="
        if grep -q "Failed to read ENV regex" "$OUTPUT_DIR/B-moondeckstream-log-excerpt.txt" 2>/dev/null; then
            echo "  Result: FAILED TO READ ENV regex"
            grep "ENV regex" "$OUTPUT_DIR/B-moondeckstream-log-excerpt.txt" 2>/dev/null || true
        elif grep -q "Got the following ENV regex" "$OUTPUT_DIR/B-moondeckstream-log-excerpt.txt" 2>/dev/null; then
            echo "  Result: GOT ENV regex from Buddy"
            grep "ENV regex" "$OUTPUT_DIR/B-moondeckstream-log-excerpt.txt" 2>/dev/null || true
        else
            echo "  Result: no ENV regex line in excerpt (check B-moondeckstream-log-excerpt.txt)"
            cat "$OUTPUT_DIR/B-moondeckstream-log-excerpt.txt" 2>/dev/null || true
        fi
        echo ""
    fi

    echo "=== Conclusion ==="
    if grep -q "Failed to read ENV regex" "$OUTPUT_DIR/A-moondeckstream-log-excerpt.txt" 2>/dev/null; then
        A_FAIL=1
    else
        A_FAIL=0
    fi
    if [[ -n "$DESKTOP_DISPLAY" ]] && [[ -f "$OUTPUT_DIR/B-moondeckstream-log-excerpt.txt" ]]; then
        if grep -q "Got the following ENV regex" "$OUTPUT_DIR/B-moondeckstream-log-excerpt.txt" 2>/dev/null; then
            B_OK=1
        else
            B_OK=0
        fi
        if [[ "$A_FAIL" -eq 1 ]] && [[ "$B_OK" -eq 1 ]]; then
            echo "  Hypothesis SUPPORTED: :99 fails to read ENV regex, desktop DISPLAY succeeds. Buddy↔MoonDeckStream shm likely keyed by display/session."
        elif [[ "$A_FAIL" -eq 0 ]]; then
            echo "  Hypothesis NOT SUPPORTED: :99 read ENV regex (check if Buddy/keys are session-independent)."
        else
            echo "  Inconclusive or both failed (Buddy may not write ENV regex until stream starts, or DISPLAY=$DESKTOP_DISPLAY is wrong for your desktop)."
        fi
    else
        if [[ "$A_FAIL" -eq 1 ]]; then
            echo "  Phase A failed to read ENV regex (consistent with black screen / no Steam). Run with desktop DISPLAY as first arg to compare, e.g.: sudo $REPO_ROOT/scripts/experiment-env-regex.sh :0"
        fi
    fi
    echo ""
    echo "Full excerpts and stderr in $OUTPUT_DIR (A-*, B-*)."
    echo "=========================================="
} > "$OUTPUT_DIR/findings.txt"

cat "$OUTPUT_DIR/findings.txt"
log_info ""
log_info "Findings written to: $OUTPUT_DIR/findings.txt"
log_info "Optional: run with your desktop DISPLAY if Phase B used :0 but you use Wayland, e.g.: sudo $REPO_ROOT/scripts/experiment-env-regex.sh ''  # skip Phase B"
