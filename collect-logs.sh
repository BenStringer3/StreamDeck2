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

# Sunshine logs (sudo: /var/log/sunshine often owned by streamdeck)
log_info "Collecting Sunshine logs..."
SUNSHINE_LOG_DIR="/var/log/sunshine"
if [[ -d "$SUNSHINE_LOG_DIR" ]]; then
    sudo cp -r "$SUNSHINE_LOG_DIR" "$LOG_DIR/sunshine-logs" 2>/dev/null || log_warn "Could not copy Sunshine logs"
else
    log_warn "Sunshine log directory not found: $SUNSHINE_LOG_DIR"
fi

# Xorg log
log_info "Collecting Xorg log..."
XORG_LOG="/var/log/streamdeck/Xorg.99.log"
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

# Sunshine config and deployed apps (sudo: streamdeck's config dir is not world-readable)
log_info "Collecting Sunshine config..."
SUNSHINE_CONF="/home/streamdeck/.config/sunshine/sunshine.conf"
SUNSHINE_CONFIG_DIR="/home/streamdeck/.config/sunshine"
if sudo test -f "$SUNSHINE_CONF"; then
    sudo cp "$SUNSHINE_CONF" "$LOG_DIR/sunshine.conf"
else
    log_warn "Sunshine config not found: $SUNSHINE_CONF"
fi
if sudo test -f "$SUNSHINE_CONFIG_DIR/apps.json"; then
    sudo cp "$SUNSHINE_CONFIG_DIR/apps.json" "$LOG_DIR/sunshine-apps.json"
fi
mkdir -p "$LOG_DIR/sunshine-logs"
# App output logs (e.g. eden-totk.log) - Sunshine may write to config or log dir
sudo bash -c "for f in $SUNSHINE_CONFIG_DIR/*.log; do [[ -f \"\$f\" ]] && cp \"\$f\" $LOG_DIR/sunshine-logs/\$(basename \"\$f\"); done" 2>/dev/null || true
for f in /var/log/sunshine/*.log; do [[ -f "$f" ]] && sudo cp "$f" "$LOG_DIR/sunshine-logs/var-$(basename "$f")" 2>/dev/null || true; done
# Ensure collected files are readable by the user who ran this script
RUN_AS_UID="${SUDO_UID:-$(id -u)}"
RUN_AS_GID="${SUDO_GID:-$(id -g)}"
sudo chown -R "$RUN_AS_UID:$RUN_AS_GID" "$LOG_DIR/sunshine-logs" 2>/dev/null || true
[[ -f "$LOG_DIR/sunshine.conf" ]] && sudo chown "$RUN_AS_UID:$RUN_AS_GID" "$LOG_DIR/sunshine.conf" 2>/dev/null || true
[[ -f "$LOG_DIR/sunshine-apps.json" ]] && sudo chown "$RUN_AS_UID:$RUN_AS_GID" "$LOG_DIR/sunshine-apps.json" 2>/dev/null || true

# Sunshine capture/GPU/app diagnostics (black screen, Vulkan, X11 capture, etc.)
log_info "Collecting Sunshine capture/app diagnostics..."
{
    echo "=== Sunshine log tail (last 150 lines) ==="
    if [[ -f "$LOG_DIR/sunshine-logs/sunshine.log" ]]; then
        tail -150 "$LOG_DIR/sunshine-logs/sunshine.log" 2>/dev/null || true
    else
        sudo tail -150 /var/log/sunshine/sunshine.log 2>/dev/null || echo "sunshine.log not found"
    fi
    echo ""
    echo "=== Grep: error, warn, fail, capture, vulkan, opengl, nvidia, x11, black, launch ==="
    ( for f in "$LOG_DIR"/sunshine-logs/*.log; do [[ -f "$f" ]] && cat "$f"; done
      journalctl -u streamdeck-sunshine.service -n 300 --no-pager 2>/dev/null
    ) | grep -iE 'error|warn|fail|capture|vulkan|opengl|nvidia|prime|x11|black|eden|launch|app' || echo "(no matches)"
    echo ""
    echo "=== Grep: configuration, unavailable, shortcut, steam (Steam launch errors) ==="
    ( for f in "$LOG_DIR"/sunshine-logs/*.log; do [[ -f "$f" ]] && cat "$f"; done
      journalctl -u streamdeck-sunshine.service -n 300 --no-pager 2>/dev/null
    ) | grep -iE 'configuration|unavailable|shortcut|steam://|game configuration' || echo "(no matches)"
    echo ""
    echo "=== Grep: audio (capture failure = stream has no audio) ==="
    ( for f in "$LOG_DIR"/sunshine-logs/*.log; do [[ -f "$f" ]] && cat "$f"; done
      journalctl -u streamdeck-sunshine.service -n 300 --no-pager 2>/dev/null
    ) | grep -iE 'audio|pulse|pipewire|Unable to initialize audio' || echo "(no matches)"
} > "$LOG_DIR/sunshine-diagnostics.txt" 2>&1

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
