#!/bin/bash
# Collect diagnostic logs and system state for Stream Deck setup

set -euo pipefail

# Source shared library and install config (STREAM_USER, BUDDY_USER, STREAM_DISPLAY)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"
source "$REPO_ROOT/scripts/lib.sh"
# shellcheck source=scripts/load-install-config.sh
source "$REPO_ROOT/scripts/load-install-config.sh"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
# Store in repo so Cursor agents can grep logs for troubleshooting
LOG_DIR="$REPO_ROOT/logs/streamdeck-$TIMESTAMP"

log_info "Collecting diagnostic logs to: $LOG_DIR"
if ! mkdir -p "$LOG_DIR" 2>/dev/null; then
    if [[ -d "$REPO_ROOT/logs" ]] && [[ ! -w "$REPO_ROOT/logs" ]]; then
        log_error "Cannot create $LOG_DIR: $REPO_ROOT/logs is not writable (likely root-owned from a previous sudo run)."
        log_error "Fix: run once with sudo so we can fix ownership: sudo ./collect-logs.sh"
        log_error "Or: sudo chown -R \$(whoami) $REPO_ROOT/logs"
    else
        log_fatal "Cannot create directory: $LOG_DIR"
    fi
    exit 1
fi

# Systemctl status
log_info "Collecting systemctl status..."
collect_systemctl_status streamdeck-xorg.service "$LOG_DIR/systemctl-xorg.status"
collect_systemctl_status streamdeck-sunshine.service "$LOG_DIR/systemctl-sunshine.status"

# Journalctl logs
log_info "Collecting journalctl logs..."
collect_journalctl streamdeck-xorg.service "$LOG_DIR/journalctl-xorg.log" 200
collect_journalctl streamdeck-sunshine.service "$LOG_DIR/journalctl-sunshine.log" 200

# Sunshine logs (sudo: /var/log/sunshine often owned by stream user)
log_info "Collecting Sunshine logs..."
SUNSHINE_LOG_DIR="/var/log/sunshine"
if [[ -d "$SUNSHINE_LOG_DIR" ]]; then
    sudo cp -r "$SUNSHINE_LOG_DIR" "$LOG_DIR/sunshine-logs" 2>/dev/null || log_warn "Could not copy Sunshine logs"
else
    log_warn "Sunshine log directory not found: $SUNSHINE_LOG_DIR"
fi

# Xorg log
log_info "Collecting Xorg log..."
XORG_LOG="/var/log/$STREAM_USER/Xorg.99.log"
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

# Installed udev rules (input isolation: verify GROUP matches stream user)
log_info "Collecting installed udev rules (streamdeck/sunshine)..."
for f in /etc/udev/rules.d/*streamdeck* /etc/udev/rules.d/*sunshine* /etc/udev/rules.d/61-streamdeck*; do
    [[ -f "$f" ]] || continue
    sudo cp "$f" "$LOG_DIR/udev-$(basename "$f")" 2>/dev/null || true
done

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

# Sunshine config and deployed apps (sudo: stream user's config dir is not world-readable)
log_info "Collecting Sunshine config..."
SUNSHINE_CONF="/home/$STREAM_USER/.config/sunshine/sunshine.conf"
SUNSHINE_CONFIG_DIR="/home/$STREAM_USER/.config/sunshine"
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

# MoonDeck Buddy logs and config (host helper for MoonDeck plugin)
log_info "Collecting MoonDeck Buddy logs..."
for f in /tmp/moondeck*.log; do
    [[ -f "$f" ]] && cp "$f" "$LOG_DIR/$(basename "$f")" 2>/dev/null || true
done
[[ -f /tmp/moondeckstream-stderr.log ]] && cp /tmp/moondeckstream-stderr.log "$LOG_DIR/" 2>/dev/null || true
if id "$BUDDY_USER" &>/dev/null; then
    BUDDY_UID=$(id -u "$BUDDY_USER")
    XDG_RUNTIME="/run/user/$BUDDY_UID"
    sudo -u "$BUDDY_USER" XDG_RUNTIME_DIR="$XDG_RUNTIME" journalctl --user -u moondeckbuddy.service -n 300 --no-pager > "$LOG_DIR/journalctl-moondeckbuddy.log" 2>/dev/null || true
    sudo -u "$BUDDY_USER" XDG_RUNTIME_DIR="$XDG_RUNTIME" journalctl --user -u moondeckbuddy-gui-session.service -n 300 --no-pager > "$LOG_DIR/journalctl-moondeckbuddy-gui.log" 2>/dev/null || true
    BUDDY_SETTINGS="/home/$BUDDY_USER/.config/moondeckbuddy/settings.json"
    if [[ -f "$BUDDY_SETTINGS" ]]; then
        sudo cp "$BUDDY_SETTINGS" "$LOG_DIR/moondeckbuddy-settings.json"
        sudo chown "$RUN_AS_UID:$RUN_AS_GID" "$LOG_DIR/moondeckbuddy-settings.json" 2>/dev/null || true
    fi
fi
# Grep summary for Buddy/MoonDeck signal (connection, port, pairing, errors)
{
    echo "=== MoonDeck/Buddy grep: error, warn, fail, port, listen, pair, moonlight, sunshine, stream ==="
    ( for f in "$LOG_DIR"/moondeck*.log; do [[ -f "$f" ]] && cat "$f"; done
      [[ -f "$LOG_DIR/journalctl-moondeckbuddy.log" ]] && cat "$LOG_DIR/journalctl-moondeckbuddy.log"
      [[ -f "$LOG_DIR/journalctl-moondeckbuddy-gui.log" ]] && cat "$LOG_DIR/journalctl-moondeckbuddy-gui.log"
    ) | grep -iE 'error|warn|fail|port|listen|pair|moonlight|sunshine|stream' || echo "(no matches)"
} > "$LOG_DIR/moondeck-diagnostics.txt" 2>&1

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

# Logind inhibitors and session idle (monitors never sleep debugging)
log_info "Collecting logind inhibitors and session state..."
{
    echo "=== loginctl list-inhibitors (any entry can prevent screen blank/sleep) ==="
    if loginctl list-inhibitors 2>/dev/null; then
        :
    else
        echo "(loginctl list-inhibitors not available, trying D-Bus ListInhibitors)"
        busctl call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager ListInhibitors 2>&1 || true
    fi
    echo ""
    echo "=== Session(s) with seat (IdleHint / IdleSinceHint) ==="
    for sid in $(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}'); do
        sseat=$(loginctl show-session "$sid" -p Seat -p Name -p State 2>/dev/null)
        echo "--- Session $sid ---"
        echo "$sseat"
        loginctl show-session "$sid" -p IdleHint -p IdleSinceHint 2>/dev/null || true
        echo ""
    done
} > "$LOG_DIR/loginctl-inhibitors.txt" 2>&1

# Input devices (for concurrency check)
log_info "Collecting input device information..."
ls -la /dev/input/by-id/ > "$LOG_DIR/input-devices.txt" 2>&1 || true

# udevadm diagnostics for Sunshine passthrough devices (why udev rule may not match)
SUNSHINE_NAMES="Mouse passthrough|Mouse passthrough (absolute)|Keyboard passthrough|Touch passthrough|Pen passthrough|Sunshine X-Box One (virtual) pad"
for dev in /sys/class/input/event*; do
    [[ -d "$dev" ]] && [[ -f "$dev/device/name" ]] || continue
    name="$(cat "$dev/device/name" 2>/dev/null)"
    echo "$name" | grep -qE "^($SUNSHINE_NAMES)$" || continue
    ev="/dev/input/$(basename "$dev")"
    {
        echo "=== $ev ($name) ==="
        udevadm info -a -n "$ev" 2>/dev/null || true
        echo "--- udevadm test ---"
        udevadm test "$(udevadm info -q path -n "$ev" 2>/dev/null)" 2>&1 || true
    } >> "$LOG_DIR/udevadm-sunshine-devices.txt" 2>/dev/null || true
done
[[ -f "$LOG_DIR/udevadm-sunshine-devices.txt" ]] && log_info "Collected udevadm info for Sunshine input devices"

# When run with sudo, make logs/ and this run owned by invoking user so next run without sudo can create new dirs
if [[ $EUID -eq 0 ]] && [[ -n "${SUDO_UID:-}" ]]; then
    chown -R "${SUDO_UID}:${SUDO_GID}" "$LOG_DIR"
    chown "${SUDO_UID}:${SUDO_GID}" "$REPO_ROOT/logs" 2>/dev/null || true
fi

log_info "Log collection complete: $LOG_DIR"
echo "$LOG_DIR"
