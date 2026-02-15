#!/bin/bash
# End-to-end test script for Stream Deck setup

set -euo pipefail

# Source shared library and install config
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"
source "$REPO_ROOT/scripts/lib.sh"
# shellcheck source=scripts/load-install-config.sh
source "$REPO_ROOT/scripts/load-install-config.sh"

# On interrupt (e.g. Ctrl+C during manual test), collect logs then exit
cleanup_on_interrupt() {
    log_info ""
    log_info "Interrupted. Collecting diagnostic logs..."
    LOG_DIR="$("$SCRIPT_DIR/collect-logs.sh")"
    log_info "Logs collected to: $LOG_DIR"
    exit 130
}
trap cleanup_on_interrupt SIGINT SIGTERM

log_info "=========================================="
log_info "Stream Deck Full Cycle Test"
log_info "=========================================="
log_info ""

# Step 1: Run install.sh
log_info "Step 1: Running install.sh..."
if ! sudo "$SCRIPT_DIR/install.sh"; then
    log_fatal "install.sh failed - aborting test"
fi

log_info ""
log_info "Step 2: Verifying health checks..."
HEALTH_FAILED=0

# Re-run health checks
if ! check_nvidia_smi; then
    HEALTH_FAILED=1
fi
if ! check_nvenc; then
    HEALTH_FAILED=1
fi
if ! check_xorg_display "$STREAM_DISPLAY"; then
    HEALTH_FAILED=1
fi
if ! check_xorg_mode "$STREAM_DISPLAY" "1280x800"; then
    HEALTH_FAILED=1
fi
if ! check_sunshine_service; then
    HEALTH_FAILED=1
fi
if ! check_sunshine_logs; then
    HEALTH_FAILED=1
fi
if ! check_audio_bridge; then
    HEALTH_FAILED=1
fi

if [[ $HEALTH_FAILED -ne 0 ]]; then
    log_error "Health checks failed - collecting logs and exiting"
    LOG_DIR="$("$SCRIPT_DIR/collect-logs.sh")"
    log_error "Logs collected to: $LOG_DIR"
    exit 1
fi

log_info "✓ All health checks passed"
log_info ""

# MoonDeck Buddy and Sunshine app gates (required for MoonDeck workflow)
APPS_JSON="/home/$STREAM_USER/.config/sunshine/apps.json"
if id "$BUDDY_USER" &>/dev/null; then
    BUDDY_UID=$(id -u "$BUDDY_USER")
    if ! sudo -u "$BUDDY_USER" XDG_RUNTIME_DIR="/run/user/$BUDDY_UID" systemctl --user is-active moondeckbuddy.service &>/dev/null; then
        log_error "MoonDeck Buddy is not running under $BUDDY_USER. Start it with: sudo -u $BUDDY_USER systemctl --user start moondeckbuddy.service"
        log_error "If autostart is not configured: sudo -u $BUDDY_USER MoonDeckBuddy --enable-autostart && sudo -u $BUDDY_USER systemctl --user enable --now moondeckbuddy.service"
        exit 1
    fi
    log_info "✓ MoonDeck Buddy (moondeckbuddy.service) is active"
    if [[ ! -f /tmp/moondeckbuddy.log ]]; then
        log_warn "/tmp/moondeckbuddy.log not found (Buddy may have just started)"
    fi
else
    log_warn "User $BUDDY_USER not found; skipping Buddy health gate"
fi
if sudo test -f "$APPS_JSON"; then
    if ! sudo cat "$APPS_JSON" | grep -q '"name"[[:space:]]*:[[:space:]]*"MoonDeckStream"'; then
        log_error "Sunshine apps.json does not contain MoonDeckStream. Re-run install.sh to deploy MoonDeck-first apps."
        exit 1
    fi
    log_info "✓ Sunshine apps include MoonDeckStream"
else
    log_error "Sunshine apps.json not found at $APPS_JSON"
    exit 1
fi
log_info ""

# Step 3: User prompt
log_info "=========================================="
log_info "Step 3: Manual Test"
log_info "=========================================="
log_info ""
log_info "Please perform the following:"
log_info "  1. Open Moonlight on your Steam Deck"
log_info "  2. Connect to this PC"
log_info "  3. Launch MoonDeckStream (or Desktop for a quick test)"
log_info "  4. Wait for the stream to start"
log_info "  5. Test that your local desktop still works (concurrency check)"
log_info ""
read -p "Press Enter after you've done the above (or Ctrl+C to cancel)..."
log_info ""

# Step 4: Collect logs and run input-pipeline check
log_info "Step 4: Collecting diagnostic logs..."
LOG_DIR="$("$SCRIPT_DIR/collect-logs.sh")"
log_info "Logs collected to: $LOG_DIR"
log_info "Running input-pipeline healthcheck..."
if ! "$SCRIPT_DIR/scripts/check-input-pipeline.sh" "$LOG_DIR" >/dev/null 2>&1; then
    log_warn "Input-pipeline check reported failures (see input-pipeline-summary.txt in LOG_DIR)"
fi
log_info ""

# Step 5: Generate summary
log_info "Step 5: Generating summary..."
SUMMARY_FILE="$LOG_DIR/summary.txt"

{
    echo "=========================================="
    echo "Stream Deck Test Summary"
    echo "Generated: $(date)"
    echo "=========================================="
    echo ""
    
    # Health check results
    echo "=== Health Checks ==="
    if check_nvidia_smi; then
        echo "✓ nvidia-smi: PASS"
    else
        echo "✗ nvidia-smi: FAIL"
    fi
    
    if check_nvenc; then
        echo "✓ NVENC encoder: PASS"
    else
        echo "✗ NVENC encoder: FAIL"
    fi
    
    if check_xorg_display "$STREAM_DISPLAY"; then
        echo "✓ Xorg display $STREAM_DISPLAY: PASS"
    else
        echo "✗ Xorg display $STREAM_DISPLAY: FAIL"
    fi
    
    if check_xorg_mode "$STREAM_DISPLAY" "1280x800"; then
        echo "✓ Mode 1280x800: PASS"
    else
        echo "✗ Mode 1280x800: FAIL"
    fi
    
    if check_sunshine_service; then
        echo "✓ Sunshine service: PASS"
    else
        echo "✗ Sunshine service: FAIL"
    fi
    
    if check_sunshine_logs "$LOG_DIR"; then
        echo "✓ Sunshine logs: PASS"
    else
        echo "✗ Sunshine logs: FAIL"
    fi
    
    if check_audio_bridge; then
        echo "✓ Audio bridge: PASS"
    else
        echo "✗ Audio bridge: FAIL"
    fi
    
    echo ""
    echo "=== Service Status ==="
    systemctl status streamdeck-xorg.service --no-pager -l | head -n 10 || echo "Xorg service status unavailable"
    echo ""
    systemctl status streamdeck-sunshine.service --no-pager -l | head -n 10 || echo "Sunshine service status unavailable"
    echo ""
    systemctl status streamdeck-audio-bridge.service --no-pager -l | head -n 5 || echo "Audio bridge status unavailable"
    
    echo ""
    echo "=== Recent Errors (if any) ==="
    journalctl -u streamdeck-xorg.service -n 20 --no-pager | grep -i error || echo "No recent Xorg errors"
    echo ""
    SUNSHINE_ERR=$(journalctl -u streamdeck-sunshine.service -n 30 --no-pager | grep -i error || true)
    if [[ -n "$SUNSHINE_ERR" ]]; then
        echo "$SUNSHINE_ERR"
    else
        echo "No recent Sunshine errors"
    fi
    if echo "$SUNSHINE_ERR" | grep -q "Initial Ping Timeout"; then
        echo ""
        echo "⚠ Initial Ping Timeout: see Post-connection port state below. If UDP 47999 is (none), Sunshine is not binding the control channel — not a firewall issue."
    fi
    
    echo "=== Input pipeline ==="
    if [[ -f "$LOG_DIR/input-pipeline-summary.txt" ]]; then
        cat "$LOG_DIR/input-pipeline-summary.txt"
    else
        echo "Run scripts/check-input-pipeline.sh \"$LOG_DIR\" to generate input-pipeline-summary.txt"
    fi
    
    echo ""
    echo "=== System Info ==="
    echo "Sunshine version: $(get_sunshine_version)"
    echo "NVIDIA driver: $(get_nvidia_driver_version)"
    echo "Kernel: $(uname -r)"
    
    echo ""
    echo "=== Xorg Display Info ==="
    if check_xorg_display "$STREAM_DISPLAY"; then
        DISPLAY="$STREAM_DISPLAY" xrandr --query 2>&1 | head -n 20 || echo "xrandr query failed"
    else
        echo "Display $STREAM_DISPLAY not accessible"
    fi
    
    echo ""
    echo "=== Stream session (MoonDeckStream) ==="
    SUNSHINE_LOG="$LOG_DIR/sunshine-logs/sunshine.log"
    if [[ -f "$SUNSHINE_LOG" ]]; then
        if grep -q "App exited with code \[134\]" "$SUNSHINE_LOG" 2>/dev/null; then
            echo "⚠ App exited with code [134] (SIGABRT) — stream ended immediately after connect."
            echo "  Root cause: run sudo ./experiment.sh to capture stderr (e.g. Qt shared memory permission denied if MoonDeckStream runs as streamdeck instead of Buddy user)."
        fi
        if grep -q "App exited with code \[256\]" "$SUNSHINE_LOG" 2>/dev/null; then
            echo "⚠ App exited with code [256] — MoonDeckStream exited shortly after launch (check MoonDeckStream/Buddy compatibility and env)."
            echo "  Check: moondeckstream-stderr.log (if present), sunshine-logs/moondeckstream.log and moondeck*.log in this log dir; README 'Desktop streams but MoonDeckStream fails'."
        fi
        if grep -q "Initial Ping Timeout" "$SUNSHINE_LOG" 2>/dev/null; then
            echo "⚠ Initial Ping Timeout (Moonlight Error 11) — see Post-connection port state below; if UDP not bound, firewall is not the cause."
            echo "  Isolate cause: try launching Desktop (not MoonDeckStream) from Moonlight; if Desktop streams, the issue is MoonDeckStream/256, not Sunshine UDP."
        fi
        echo "Last MoonDeckStream launch and exit from Sunshine log:"
        grep -E "Executing:.*MoonDeckStream|App exited with code|Process terminated" "$SUNSHINE_LOG" 2>/dev/null | tail -5 || echo "(none)"
    else
        echo "Sunshine log not found in bundle"
    fi
    echo ""
    echo "=== MoonDeck Buddy ==="
    if id "$BUDDY_USER" &>/dev/null; then
        BUDDY_UID=$(id -u "$BUDDY_USER")
        if sudo -u "$BUDDY_USER" XDG_RUNTIME_DIR="/run/user/$BUDDY_UID" systemctl --user is-active moondeckbuddy.service &>/dev/null; then
            echo "✓ moondeckbuddy.service: active"
        else
            echo "✗ moondeckbuddy.service: not active"
        fi
        if [[ -f "$LOG_DIR/moondeck-diagnostics.txt" ]]; then
            echo ""
            echo "MoonDeck/Buddy grep summary (see $LOG_DIR/moondeck-diagnostics.txt for full output):"
            tail -20 "$LOG_DIR/moondeck-diagnostics.txt" 2>/dev/null || true
        fi
    else
        echo "User $BUDDY_USER not found"
    fi
    echo ""
    echo "=== Full logs location ==="
    echo "$LOG_DIR (includes moondeck*.log and moondeck-diagnostics.txt when collect-logs ran)"
    echo ""
    echo "=========================================="
    
} > "$SUMMARY_FILE"

# Display summary
cat "$SUMMARY_FILE"

# Copy to clipboard
log_info ""
log_info "Copying summary to clipboard..."

# Detect display server and use appropriate clipboard tool
CLIPBOARD_COPIED=0

# Get current user ID (handle sudo context)
CURRENT_UID="${SUDO_UID:-$(id -u)}"
RUNTIME_DIR="/run/user/$CURRENT_UID"

# Try Wayland clipboard
if command -v wl-copy &>/dev/null; then
    # Set XDG_RUNTIME_DIR if not set but runtime dir exists
    if [[ -z "${XDG_RUNTIME_DIR:-}" ]] && [[ -d "$RUNTIME_DIR" ]]; then
        export XDG_RUNTIME_DIR="$RUNTIME_DIR"
    fi
    
    # Set WAYLAND_DISPLAY if not set (try common values)
    if [[ -z "${WAYLAND_DISPLAY:-}" ]]; then
        # Check for existing wayland socket in runtime dir
        if [[ -n "${XDG_RUNTIME_DIR:-}" ]] && [[ -d "${XDG_RUNTIME_DIR}" ]]; then
            for socket in "${XDG_RUNTIME_DIR}"/wayland-*; do
                if [[ -S "$socket" ]]; then
                    export WAYLAND_DISPLAY="$(basename "$socket")"
                    break
                fi
            done
        fi
        # Fallback to wayland-0 if no socket found
        export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
    fi
    
    # Try copying via Wayland
    if cat "$SUMMARY_FILE" | wl-copy 2>/dev/null; then
        log_info "✓ Summary copied to clipboard (Wayland)"
        CLIPBOARD_COPIED=1
    fi
fi

# Try X11 clipboard if Wayland didn't work
if [[ $CLIPBOARD_COPIED -eq 0 ]]; then
    # Detect X11 display
    X11_DISPLAY="${DISPLAY:-}"
    if [[ -z "$X11_DISPLAY" ]]; then
        # Try to find X11 socket
        if [[ -S "/tmp/.X11-unix/X0" ]]; then
            X11_DISPLAY=":0"
        fi
    fi
    
    if [[ -n "$X11_DISPLAY" ]]; then
        export DISPLAY="$X11_DISPLAY"
        if command -v xclip &>/dev/null; then
            if cat "$SUMMARY_FILE" | xclip -selection clipboard 2>/dev/null; then
                log_info "✓ Summary copied to clipboard (X11 via xclip)"
                CLIPBOARD_COPIED=1
            fi
        elif command -v xsel &>/dev/null; then
            if cat "$SUMMARY_FILE" | xsel --clipboard --input 2>/dev/null; then
                log_info "✓ Summary copied to clipboard (X11 via xsel)"
                CLIPBOARD_COPIED=1
            fi
        fi
    fi
fi

if [[ $CLIPBOARD_COPIED -eq 0 ]]; then
    log_warn "Clipboard not available - summary saved to: $SUMMARY_FILE"
fi

log_info ""
log_info "=========================================="
log_info "Test cycle complete!"
log_info "=========================================="
log_info ""
log_info "Summary: $SUMMARY_FILE"
log_info "Full logs: $LOG_DIR"
