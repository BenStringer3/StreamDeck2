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
for f in /etc/udev/rules.d/*streamdeck* /etc/udev/rules.d/*sunshine*; do
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
    echo ""
    echo "=== Audio TCP bridge (tcp:127.0.0.1:4713) ==="
    echo "--- port 4713 listener ---"
    ss -tlnp 2>/dev/null | grep ':4713' || echo "(not listening)"
    echo "--- pactl info as $STREAM_USER via TCP ---"
    sudo -u "$STREAM_USER" PULSE_SERVER=tcp:127.0.0.1:4713 pactl info 2>&1 || echo "(connection failed)"
    echo "--- PipeWire-Pulse drop-in ---"
    DROPIN="/home/$BUDDY_USER/.config/pipewire/pipewire-pulse.conf.d/10-tcp-localhost.conf"
    if [[ -f "$DROPIN" ]]; then echo "exists: $DROPIN"; else echo "MISSING: $DROPIN"; fi
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

# Steam client logs (Buddy user) — game launch / MoonDeck "watching AppID" diagnosis (see docs/troubleshooting.md, check-input-pipeline.sh)
log_info "Collecting Steam client logs..."
mkdir -p "$LOG_DIR/steam-logs"
STEAM_CLIENT_LOGS="/home/$BUDDY_USER/.local/share/Steam/logs"
if id "$BUDDY_USER" &>/dev/null && sudo test -d "$STEAM_CLIENT_LOGS"; then
    for f in gameprocess_log.txt content_log.txt webhelper.txt stderr.txt console-linux.txt console_log.txt shader_log.txt; do
        if sudo test -f "$STEAM_CLIENT_LOGS/$f"; then
            sudo cp "$STEAM_CLIENT_LOGS/$f" "$LOG_DIR/steam-logs/$f" 2>/dev/null || true
        fi
    done
    sudo chown -R "$RUN_AS_UID:$RUN_AS_GID" "$LOG_DIR/steam-logs" 2>/dev/null || true
    # Buddy launch URI vs Steam "game running" — docs/troubleshooting.md, moondeck-game-detection-research.md
    log_info "Collecting Steam game-launch diagnostic summary..."
    {
        echo "=== 1. Buddy: steam:// commands, AppID watch, stream boundaries ==="
        if [[ -f "$LOG_DIR/moondeckbuddy.log" ]]; then
            grep -E 'steam://|Started watching AppID|Stopped watching AppID|BigPicture|Stream started\.|Stream is ending|Stream has ended|WITH ENV OVERRIDES.*steam' "$LOG_DIR/moondeckbuddy.log" 2>/dev/null | tail -120 || true
        else
            echo "(moondeckbuddy.log not in bundle)"
        fi
        echo ""
        echo "=== 2. gameprocess_log.txt: running list / gameID ==="
        if [[ -f "$LOG_DIR/steam-logs/gameprocess_log.txt" ]]; then
            grep -E 'running list|gameID|AppID|Updating|Failed|ERROR' "$LOG_DIR/steam-logs/gameprocess_log.txt" 2>/dev/null | tail -80 || true
        else
            echo "(gameprocess_log.txt missing)"
        fi
        echo ""
        echo "=== 3. console-linux.txt: Adding process / rungameid / launch ==="
        if [[ -f "$LOG_DIR/steam-logs/console-linux.txt" ]]; then
            grep -iE 'Adding process.*gameID|rungameid|steam://launch|steam://open|Game Recording.*game' "$LOG_DIR/steam-logs/console-linux.txt" 2>/dev/null | tail -100 || true
        else
            echo "(console-linux.txt missing)"
        fi
        echo ""
        echo "=== 4. webhelper.txt: BPM / GL / compositor (game UI may fail here) ==="
        if [[ -f "$LOG_DIR/steam-logs/webhelper.txt" ]]; then
            grep -iE 'CreateOutputWindow|gl context|steamclient\.so|dlmopen|Failed to create|composer|Assertion Failed' "$LOG_DIR/steam-logs/webhelper.txt" 2>/dev/null | tail -80 || true
        else
            echo "(webhelper.txt missing)"
        fi
        echo ""
        echo "=== 5. console_log.txt: GameAction launch pipeline (shader cache, interstitials) ==="
        if [[ -f "$LOG_DIR/steam-logs/console_log.txt" ]]; then
            grep -iE 'GameAction.*LaunchApp|ExecCommandLine|ExecuteSteamURL' "$LOG_DIR/steam-logs/console_log.txt" 2>/dev/null | tail -80 || true
        else
            echo "(console_log.txt missing)"
        fi
        echo ""
        echo "=== 6. Heuristic (read with latest session in mind) ==="
        echo "If section 1 shows 'Started watching AppID: N' for a run but section 2–3 show no 'Add … to running list' / 'Adding process … gameID N' after that launch, Steam never registered the game — often a stuck steam://launch/…/dialog, shader cache dialog (section 5 'ProcessingShaderCache waiting'), wrong display, or GPU/CEF failure (section 4)."
    } > "$LOG_DIR/steam-game-launch.txt" 2>&1 || true
else
    log_warn "Steam logs directory missing or buddy user unknown: $STEAM_CLIENT_LOGS"
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

# Sunshine virtual input device udev tags (seat/uaccess cause input leakage to desktop)
log_info "Collecting Sunshine input device udev tags..."
{
    for name in "Mouse passthrough" "Mouse passthrough (absolute)" "Keyboard passthrough" \
                "Touch passthrough" "Pen passthrough" "Sunshine X-Box One (virtual) pad"; do
        parent_path=$(grep -rl "^${name}$" /sys/devices/virtual/input/*/name 2>/dev/null | head -1 || true)
        if [[ -n "$parent_path" ]]; then
            parent_dir=$(dirname "$parent_path")
            echo "=== $name ($(basename "$parent_dir")) ==="
            udevadm info -q all "$parent_dir" 2>/dev/null | grep -E '^E: (TAGS|CURRENT_TAGS|ID_INPUT|ID_SEAT)=' || echo "(no relevant properties)"
            event_dev=$(find "$parent_dir" -maxdepth 1 -name 'event*' -printf '%f\n' 2>/dev/null | head -1)
            if [[ -n "$event_dev" ]]; then
                echo "  Event device: /dev/input/$event_dev"
                ls -la "/dev/input/$event_dev" 2>/dev/null || true
                getfacl "/dev/input/$event_dev" 2>/dev/null | grep -v '^#' | grep -v '^$' || true
            fi
        fi
    done
} > "$LOG_DIR/sunshine-input-udev-tags.txt" 2>&1 || true

# When run with sudo, make logs/ and this run owned by invoking user so next run without sudo can create new dirs
if [[ $EUID -eq 0 ]] && [[ -n "${SUDO_UID:-}" ]]; then
    chown -R "${SUDO_UID}:${SUDO_GID}" "$LOG_DIR"
    chown "${SUDO_UID}:${SUDO_GID}" "$REPO_ROOT/logs" 2>/dev/null || true
fi

log_info "Log collection complete: $LOG_DIR"
echo "$LOG_DIR"
