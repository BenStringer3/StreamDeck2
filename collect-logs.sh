#!/bin/bash
# Collect diagnostic logs and system state for Stream Deck setup

set -euo pipefail

# Source shared library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"
source "$REPO_ROOT/scripts/lib.sh"

# Configuration
STREAM_DISPLAY="${STREAM_DISPLAY:-:99}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
LOG_DIR="/tmp/streamdeck-test-$TIMESTAMP"

log_info "Collecting diagnostic logs to: $LOG_DIR"
mkdir -p "$LOG_DIR"

# Systemctl status
log_info "Collecting systemctl status..."
collect_systemctl_status streamdeck-xorg.service "$LOG_DIR/systemctl-xorg.status"
collect_systemctl_status streamdeck-sunshine.service "$LOG_DIR/systemctl-sunshine.status"

# Journalctl logs
log_info "Collecting journalctl logs..."
collect_journalctl streamdeck-xorg.service "$LOG_DIR/journalctl-xorg.log" 200
collect_journalctl streamdeck-sunshine.service "$LOG_DIR/journalctl-sunshine.log" 200

# Sunshine logs
log_info "Collecting Sunshine logs..."
SUNSHINE_LOG_DIR="/var/log/sunshine"
if [[ -d "$SUNSHINE_LOG_DIR" ]]; then
    cp -r "$SUNSHINE_LOG_DIR" "$LOG_DIR/sunshine-logs" 2>/dev/null || log_warn "Could not copy Sunshine logs"
else
    log_warn "Sunshine log directory not found: $SUNSHINE_LOG_DIR"
fi

# Xorg log
log_info "Collecting Xorg log..."
XORG_LOG="/var/log/Xorg.99.log"
if [[ -f "$XORG_LOG" ]]; then
    cp "$XORG_LOG" "$LOG_DIR/Xorg.99.log"
else
    log_warn "Xorg log not found: $XORG_LOG"
fi

# Xorg config
log_info "Collecting Xorg config..."
XORG_CONF="/etc/X11/xorg.conf.d/99-streamdeck.conf"
if [[ -f "$XORG_CONF" ]]; then
    cp "$XORG_CONF" "$LOG_DIR/xorg.conf"
else
    log_warn "Xorg config not found: $XORG_CONF"
fi

# xrandr output
log_info "Collecting xrandr output..."
if check_xorg_display "$STREAM_DISPLAY"; then
    DISPLAY="$STREAM_DISPLAY" xrandr --verbose > "$LOG_DIR/xrandr-verbose.txt" 2>&1 || true
    DISPLAY="$STREAM_DISPLAY" xrandr --query > "$LOG_DIR/xrandr-query.txt" 2>&1 || true
else
    log_warn "Cannot query xrandr - display $STREAM_DISPLAY not accessible"
fi

# GPU state
log_info "Collecting GPU state..."
if command -v nvidia-smi &>/dev/null; then
    nvidia-smi -L > "$LOG_DIR/nvidia-smi-L.txt" 2>&1 || true
    nvidia-smi --query-gpu=name,driver_version,encoder.stats.session_count --format=csv > "$LOG_DIR/nvidia-smi-query.txt" 2>&1 || true
    nvidia-smi > "$LOG_DIR/nvidia-smi-full.txt" 2>&1 || true
else
    log_warn "nvidia-smi not available"
fi

# Versions
log_info "Collecting version information..."
{
    echo "=== Sunshine Version ==="
    get_sunshine_version
    echo ""
    echo "=== NVIDIA Driver Version ==="
    get_nvidia_driver_version
    echo ""
    echo "=== Kernel Version ==="
    get_kernel_version
    echo ""
    echo "=== System Info ==="
    uname -a
    cat /etc/os-release 2>/dev/null || true
} > "$LOG_DIR/versions.txt"

# Sunshine config
log_info "Collecting Sunshine config..."
SUNSHINE_CONF="/home/streamdeck/.config/sunshine/sunshine.conf"
if [[ -f "$SUNSHINE_CONF" ]]; then
    cp "$SUNSHINE_CONF" "$LOG_DIR/sunshine.conf"
else
    log_warn "Sunshine config not found: $SUNSHINE_CONF"
fi

# Systemd unit files
log_info "Collecting systemd unit files..."
if [[ -f /etc/systemd/system/streamdeck-xorg.service ]]; then
    cp /etc/systemd/system/streamdeck-xorg.service "$LOG_DIR/streamdeck-xorg.service"
fi
if [[ -f /etc/systemd/system/streamdeck-sunshine.service ]]; then
    cp /etc/systemd/system/streamdeck-sunshine.service "$LOG_DIR/streamdeck-sunshine.service"
fi

# Process list
log_info "Collecting process information..."
ps aux | grep -E "(Xorg|sunshine)" | grep -v grep > "$LOG_DIR/processes.txt" 2>&1 || true

# Input devices (for concurrency check)
log_info "Collecting input device information..."
ls -la /dev/input/by-id/ > "$LOG_DIR/input-devices.txt" 2>&1 || true

log_info "Log collection complete: $LOG_DIR"
echo "$LOG_DIR"
