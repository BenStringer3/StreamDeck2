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
collect_systemctl_status streamdeck-audio-bridge.service "$LOG_DIR/systemctl-audio-bridge.status"
collect_systemctl_status streamdeck-pipewire.service "$LOG_DIR/systemctl-pipewire.status"
collect_systemctl_status streamdeck-audio-capture.service "$LOG_DIR/systemctl-audio-capture.status"

# Journalctl logs
log_info "Collecting journalctl logs..."
collect_journalctl streamdeck-xorg.service "$LOG_DIR/journalctl-xorg.log" 200
collect_journalctl streamdeck-sunshine.service "$LOG_DIR/journalctl-sunshine.log" 200
collect_journalctl streamdeck-audio-bridge.service "$LOG_DIR/journalctl-audio-bridge.log" 100
collect_journalctl streamdeck-pipewire.service "$LOG_DIR/journalctl-pipewire.log" 100
collect_journalctl streamdeck-audio-capture.service "$LOG_DIR/journalctl-audio-capture.log" 100

# --- Audio Bridge Diagnostics ---
log_info "Collecting audio bridge state..."

# ALSA state
log_info "Collecting ALSA state..."
{
    echo "=== ALSA Cards ==="
    cat /proc/asound/cards
    echo ""
    echo "=== snd-aloop module ==="
    lsmod | grep snd_aloop || echo "snd_aloop not loaded"
    echo ""
    echo "=== Loopback Cable State ==="
    for cable in /proc/asound/card*/cable#*; do
        if [[ -f "$cable" ]]; then
            echo "--- $cable ---"
            cat "$cable"
        fi
    done
} > "$LOG_DIR/alsa-state.txt" 2>&1

# PipeWire/PulseAudio state (as __BUDDY_USER__)
log_info "Collecting PipeWire state..."
{
    echo "=== pactl info (__BUDDY_USER__) ==="
    sudo -u __BUDDY_USER__ XDG_RUNTIME_DIR=/run/user/1000 pactl info 2>&1 || echo "Could not run pactl info"
    echo ""
    echo "=== PipeWire Sinks ==="
    sudo -u __BUDDY_USER__ XDG_RUNTIME_DIR=/run/user/1000 pactl list sinks short 2>&1 || echo "Could not list sinks"
    echo ""
    echo "=== PipeWire Sources ==="
    sudo -u __BUDDY_USER__ XDG_RUNTIME_DIR=/run/user/1000 pactl list sources short 2>&1 || echo "Could not list sources"
    echo ""
    echo "=== StreamDeck-Bridge Sink ==="
    sudo -u __BUDDY_USER__ XDG_RUNTIME_DIR=/run/user/1000 pactl list sinks 2>&1 | grep -A30 "StreamDeck-Bridge" || echo "StreamDeck-Bridge sink not found"
} > "$LOG_DIR/pipewire-state.txt" 2>&1

# Streamdeck PipeWire state
log_info "Collecting streamdeck PipeWire state..."
{
    echo "=== pactl info (streamdeck) ==="
    sudo -u streamdeck XDG_RUNTIME_DIR=/run/streamdeck-audio pactl info 2>&1 || echo "Could not run pactl info as streamdeck"
    echo ""
    echo "=== Streamdeck Sinks ==="
    sudo -u streamdeck XDG_RUNTIME_DIR=/run/streamdeck-audio pactl list sinks short 2>&1 || echo "Could not list sinks"
    echo ""
    echo "=== Streamdeck Sources ==="
    sudo -u streamdeck XDG_RUNTIME_DIR=/run/streamdeck-audio pactl list sources short 2>&1 || echo "Could not list sources"
} > "$LOG_DIR/pipewire-streamdeck-state.txt" 2>&1

# Streamdeck PipeWire config (access drop-in for set-default-sink; helps debug no-audio)
log_info "Collecting streamdeck PipeWire config..."
{
    echo "=== /etc/pipewire-streamdeck (listing) ==="
    (ls -la /etc/pipewire-streamdeck 2>/dev/null || sudo ls -la /etc/pipewire-streamdeck 2>/dev/null) || echo "Directory not found"
    echo ""
    echo "=== pipewire/ (listing; pipewire.conf should exist as symlink so drop-in is loaded) ==="
    (ls -la /etc/pipewire-streamdeck/pipewire 2>/dev/null || sudo ls -la /etc/pipewire-streamdeck/pipewire 2>/dev/null) || echo "Directory not found"
    echo ""
    echo "=== pipewire/pipewire.conf.d (listing + contents) ==="
    (ls -la /etc/pipewire-streamdeck/pipewire/pipewire.conf.d 2>/dev/null || sudo ls -la /etc/pipewire-streamdeck/pipewire/pipewire.conf.d 2>/dev/null) || echo "Directory not found"
    echo ""
    for f in /etc/pipewire-streamdeck/pipewire/pipewire.conf.d/*.conf; do
        [[ -e "$f" ]] || continue
        echo "=== $f ==="
        (cat "$f" 2>/dev/null || sudo cat "$f" 2>/dev/null)
        echo ""
    done
} > "$LOG_DIR/pipewire-streamdeck-config.txt" 2>&1

# Sunshine audio config (sudo: streamdeck's config is not world-readable)
log_info "Collecting Sunshine audio config..."
if sudo test -f /home/streamdeck/.config/sunshine/sunshine.conf; then
    sudo grep -iE 'audio|sink|stream' /home/streamdeck/.config/sunshine/sunshine.conf > "$LOG_DIR/sunshine-audio-config.txt" 2>&1 || true
fi

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
if [[ -f /etc/systemd/system/streamdeck-audio-bridge.service ]]; then
    cp /etc/systemd/system/streamdeck-audio-bridge.service "$LOG_DIR/streamdeck-audio-bridge.service"
fi
if [[ -f /etc/systemd/system/streamdeck-pipewire.service ]]; then
    cp /etc/systemd/system/streamdeck-pipewire.service "$LOG_DIR/streamdeck-pipewire.service"
fi
if [[ -f /etc/systemd/system/streamdeck-audio-capture.service ]]; then
    cp /etc/systemd/system/streamdeck-audio-capture.service "$LOG_DIR/streamdeck-audio-capture.service"
fi

# Process list
log_info "Collecting process information..."
ps aux | grep -E "(Xorg|sunshine)" | grep -v grep > "$LOG_DIR/processes.txt" 2>&1 || true

# Input devices (for concurrency check)
log_info "Collecting input device information..."
ls -la /dev/input/by-id/ > "$LOG_DIR/input-devices.txt" 2>&1 || true

# When run with sudo, make logs/ and this run owned by invoking user so next run without sudo can create new dirs
if [[ $EUID -eq 0 ]] && [[ -n "${SUDO_UID:-}" ]]; then
    chown -R "${SUDO_UID}:${SUDO_GID}" "$LOG_DIR"
    chown "${SUDO_UID}:${SUDO_GID}" "$REPO_ROOT/logs" 2>/dev/null || true
fi

log_info "Log collection complete: $LOG_DIR"
echo "$LOG_DIR"
