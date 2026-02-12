#!/bin/bash
# End-to-end test script for Stream Deck setup

set -euo pipefail

# Source shared library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"
source "$REPO_ROOT/scripts/lib.sh"

STREAM_DISPLAY="${STREAM_DISPLAY:-:99}"

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

if [[ $HEALTH_FAILED -ne 0 ]]; then
    log_error "Health checks failed - collecting logs and exiting"
    LOG_DIR="$("$SCRIPT_DIR/collect-logs.sh")"
    log_error "Logs collected to: $LOG_DIR"
    exit 1
fi

log_info "✓ All health checks passed"
log_info ""

# Step 3: User prompt
log_info "=========================================="
log_info "Step 3: Manual Test"
log_info "=========================================="
log_info ""
log_info "Please perform the following:"
log_info "  1. Open Moonlight on your Steam Deck"
log_info "  2. Connect to this PC"
log_info "  3. Launch an app (e.g., 'Desktop')"
log_info "  4. Wait for the stream to start"
log_info "  5. Test that your local desktop still works (concurrency check)"
log_info ""
read -p "Press Enter after you've completed the above steps (or Ctrl+C to cancel)..."
log_info ""

# Step 4: Collect logs
log_info "Step 4: Collecting diagnostic logs..."
LOG_DIR="$("$SCRIPT_DIR/collect-logs.sh")"
log_info "Logs collected to: $LOG_DIR"
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
    
    if check_sunshine_logs; then
        echo "✓ Sunshine logs: PASS"
    else
        echo "✗ Sunshine logs: FAIL"
    fi
    
    echo ""
    echo "=== Service Status ==="
    systemctl status streamdeck-xorg.service --no-pager -l | head -n 10 || echo "Xorg service status unavailable"
    echo ""
    systemctl status streamdeck-sunshine.service --no-pager -l | head -n 10 || echo "Sunshine service status unavailable"
    
    echo ""
    echo "=== Recent Errors (if any) ==="
    journalctl -u streamdeck-xorg.service -n 20 --no-pager | grep -i error || echo "No recent Xorg errors"
    echo ""
    journalctl -u streamdeck-sunshine.service -n 20 --no-pager | grep -i error || echo "No recent Sunshine errors"
    
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
    echo "=== Full logs location ==="
    echo "$LOG_DIR"
    echo ""
    echo "=========================================="
    
} > "$SUMMARY_FILE"

# Display summary
cat "$SUMMARY_FILE"

# Copy to clipboard
log_info ""
log_info "Copying summary to clipboard..."
if command -v wl-copy &>/dev/null; then
    cat "$SUMMARY_FILE" | wl-copy
    log_info "✓ Summary copied to clipboard"
else
    log_warn "wl-copy not available - summary saved to: $SUMMARY_FILE"
fi

log_info ""
log_info "=========================================="
log_info "Test cycle complete!"
log_info "=========================================="
log_info ""
log_info "Summary: $SUMMARY_FILE"
log_info "Full logs: $LOG_DIR"
