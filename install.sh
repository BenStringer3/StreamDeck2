#!/bin/bash
# Idempotent installation script for Stream Deck → Moonlight → Sunshine setup

set -euo pipefail

# Source shared library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"
source "$REPO_ROOT/scripts/lib.sh"

# Configuration (BUDDY_USER defaults to user who ran sudo; see docs/installing.md)
STREAM_USER="${STREAM_USER:-streamdeck}"
STREAM_DISPLAY="${STREAM_DISPLAY:-:99}"
BUDDY_USER="${BUDDY_USER:-$SUDO_USER}"
BUDDY_USER="${BUDDY_USER:-$(logname 2>/dev/null)}"
BUDDY_USER="${BUDDY_USER:-__BUDDY_USER__}"
STREAM_GROUP="${STREAM_GROUP:-$STREAM_USER}"
STREAM_HOME="/home/$STREAM_USER"

# Install MoonDeckStream wrapper from scripts/moondeckstream-wrapper.sh (substitutes __REAL_BIN__ and __PRE_ARGS__)
install_moondeckstream_wrapper() {
    local real_bin="$1"
    local pre_args="$2"
    local wrapper_src="$REPO_ROOT/scripts/moondeckstream-wrapper.sh"
    local wrapper_dest="/usr/local/bin/MoonDeckStream"
    [[ -f "$wrapper_src" ]] || log_fatal "Wrapper script not found: $wrapper_src"
    local tmp="${wrapper_dest}.new.$$"
    sed -e "s|__REAL_BIN__|$real_bin|g" -e "s|__PRE_ARGS__|$pre_args|g" "$wrapper_src" > "$tmp"
    chmod +x "$tmp"
    mv "$tmp" "$wrapper_dest"
    log_info "Installed MoonDeckStream wrapper (real_bin=$real_bin)"
}

log_info "Starting Stream Deck setup (Option B: separate Xorg session)"

# Check if running as root
assert_root

# Write install config so other scripts (collect-logs, check-input-pipeline, etc.) can read it
mkdir -p /etc/streamdeck
cat > /etc/streamdeck/install.conf << CONFIG
STREAM_USER=$STREAM_USER
BUDDY_USER=$BUDDY_USER
STREAM_DISPLAY=$STREAM_DISPLAY
STREAM_GROUP=$STREAM_GROUP
CONFIG
chmod 644 /etc/streamdeck/install.conf
log_info "Wrote /etc/streamdeck/install.conf (STREAM_USER=$STREAM_USER BUDDY_USER=$BUDDY_USER)"

# Detect system state
log_info "Probing system state..."

# Check for existing EDID file (override with EDID_PATH env; see docs/installing.md)
EDID_PATH="${EDID_PATH:-/etc/X11/edid/steamdeck-edid.bin}"
if [[ -f "$EDID_PATH" ]]; then
    log_info "Found existing EDID file: $EDID_PATH"
else
    log_warn "EDID file not found at $EDID_PATH (will use AllowEmptyInitialConfiguration)"
fi

# Disable system sunshine.service so streamdeck-sunshine is the only instance (avoids port/binding conflicts)
if systemctl list-unit-files --type=service 2>/dev/null | grep -q '^sunshine.service'; then
    log_info "Disabling and stopping system sunshine.service (we use streamdeck-sunshine only)"
    systemctl disable sunshine.service 2>/dev/null || true
    systemctl stop sunshine.service 2>/dev/null || true
fi

# Detect NVIDIA driver
log_info "Detecting NVIDIA driver..."
INSTALLED_NVIDIA_DRIVER=""
if INSTALLED_NVIDIA_DRIVER=$(detect_nvidia_driver); then
    log_info "Found installed NVIDIA driver: $INSTALLED_NVIDIA_DRIVER"
else
    log_fatal "No NVIDIA driver detected. Install an NVIDIA driver for your distro (see docs/installing.md)."
fi

# Package and Sunshine/Buddy install (skip when SKIP_DEPS=1; see docs/installing.md)
MOONDECK_APPIMAGE="/opt/moondeckbuddy/MoonDeckBuddy.AppImage"
MOONDECK_OPT_DIR="/opt/moondeckbuddy"
BUDDY_INSTALLED=0

if [[ "${SKIP_DEPS:-0}" == "1" ]]; then
    log_info "SKIP_DEPS=1: skipping package and AUR installation"
    command -v sunshine &>/dev/null || log_warn "sunshine not in PATH; ensure Sunshine is installed"
else
    # Detect distro from /etc/os-release
    OS_ID=""
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        OS_ID="${ID:-}"
        [[ -z "$OS_ID" && -n "${ID_LIKE:-}" ]] && OS_ID="${ID_LIKE%% *}"
    fi

    case "${OS_ID:-}" in
        arch)
            log_info "Installing dependencies (Arch)..."
            pacman -Sy --noconfirm --needed \
                xorg-server xorg-xrandr xf86-video-dummy openbox xterm nvidia-utils wl-clipboard \
                || log_fatal "Failed to install dependencies"
            log_info "Installing sunshine from AUR..."
            if ! pacman -Q sunshine &>/dev/null; then
                command -v yay &>/dev/null || log_fatal "yay not found. Install yay or set SKIP_DEPS=1 and install Sunshine manually (see docs/installing.md)"
                yay -S --needed --noconfirm sunshine || log_fatal "Failed to install sunshine from AUR"
            else
                log_info "sunshine is already installed"
            fi
            if pacman -Q moondeckbuddy-appimage &>/dev/null; then
                BUDDY_INSTALLED=1
            elif command -v yay &>/dev/null && yay -S --needed --noconfirm moondeckbuddy-appimage; then
                BUDDY_INSTALLED=1
            else
                log_warn "AUR moondeckbuddy-appimage failed or unavailable, will try AppImage fallback"
            fi
            ;;
        debian|ubuntu)
            log_info "Installing dependencies (Debian/Ubuntu)..."
            apt-get update -qq && apt-get install -y -qq \
                xserver-xorg xserver-xorg-video-dummy openbox xterm nvidia-utils wl-clipboard \
                || log_fatal "Failed to install dependencies"
            command -v sunshine &>/dev/null || log_warn "Sunshine not in PATH. Install from PPA or AppImage (see docs/installing.md)"
            ;;
        fedora)
            log_info "Installing dependencies (Fedora)..."
            dnf install -y xorg-x11-server-Xorg xorg-x11-server-Xorg-xorg-dummy openbox xterm nvidia-utils wl-clipboard \
                || log_fatal "Failed to install dependencies"
            command -v sunshine &>/dev/null || log_warn "Sunshine not in PATH. Install manually (see docs/installing.md)"
            ;;
        *)
            log_fatal "Unsupported distro (ID=$OS_ID). Install dependencies manually (see docs/installing.md) and set SKIP_DEPS=1 to run the rest of install."
            ;;
    esac
fi

# Install MoonDeck Buddy if not already installed (AppImage fallback on any distro)
log_info "Installing MoonDeck Buddy..."
# Fallback: install AppImage to stable path and create wrappers
if [[ $BUDDY_INSTALLED -eq 0 ]] || ! command -v MoonDeckStream &>/dev/null; then
    mkdir -p "$MOONDECK_OPT_DIR"
    # Resolve latest AppImage URL from GitHub releases (requires curl)
    MOONDECK_URL=""
    if command -v curl &>/dev/null; then
        MOONDECK_URL=$(curl -sL "https://api.github.com/repos/FrogTheFrog/moondeck-buddy/releases/latest" | grep -oE 'https://[^"]+MoonDeckBuddy[^"]*\.AppImage' | head -1)
    fi
    if [[ -z "$MOONDECK_URL" ]]; then
        if [[ ! -x "$MOONDECK_APPIMAGE" ]]; then
            log_fatal "MoonDeck Buddy not installed (AUR failed and could not resolve AppImage URL). Install moondeckbuddy-appimage manually or place MoonDeckBuddy.AppImage in $MOONDECK_OPT_DIR"
        fi
        log_info "Using existing $MOONDECK_APPIMAGE"
    else
        log_info "Downloading MoonDeck Buddy AppImage to $MOONDECK_APPIMAGE"
        curl -sL -o "$MOONDECK_APPIMAGE" "$MOONDECK_URL" || log_fatal "Failed to download MoonDeck Buddy AppImage"
        chmod +x "$MOONDECK_APPIMAGE"
    fi
    for bin in MoonDeckBuddy MoonDeckStream; do
        WRAPPER="/usr/local/bin/$bin"
        if [[ ! -x "$WRAPPER" ]] || ! grep -q "MoonDeckBuddy.AppImage" "$WRAPPER" 2>/dev/null; then
            if [[ "$bin" == "MoonDeckStream" ]]; then
                install_moondeckstream_wrapper "$MOONDECK_APPIMAGE" "--exec MoonDeckStream"
            else
                cat > "$WRAPPER" << EOF
#!/bin/bash
exec "$MOONDECK_APPIMAGE" --exec $bin "\$@"
EOF
                chmod +x "$WRAPPER"
                log_info "Created $WRAPPER"
            fi
        fi
    done
fi
# Ensure /usr/local/bin wrappers exist when AUR installed (so apps.json and systemd use stable path)
# MoonDeckStream: wrapper from scripts/moondeckstream-wrapper.sh; MoonDeckBuddy: symlink to AUR binary
for bin in MoonDeckBuddy MoonDeckStream; do
    WRAPPER="/usr/local/bin/$bin"
    if [[ "$bin" == "MoonDeckStream" ]]; then
        AUR_BIN=$(PATH=/usr/bin:/bin command -v MoonDeckStream 2>/dev/null || true)
        if [[ -n "$AUR_BIN" ]]; then
            install_moondeckstream_wrapper "$AUR_BIN" ""
        fi
    else
        if [[ ! -x "$WRAPPER" ]]; then
            AUR_BIN=$(PATH=/usr/bin:/bin command -v "$bin" 2>/dev/null || true)
            if [[ -n "$AUR_BIN" ]]; then
                ln -sf "$AUR_BIN" "$WRAPPER"
                log_info "Linked $WRAPPER -> $AUR_BIN"
            fi
        fi
    fi
done
if ! command -v MoonDeckBuddy &>/dev/null || ! command -v MoonDeckStream &>/dev/null; then
    log_fatal "MoonDeck Buddy binaries not found. Ensure /usr/local/bin is on PATH and MoonDeckBuddy/MoonDeckStream are present."
fi
log_info "MoonDeck Buddy install OK"

# Configure MoonDeck Buddy autostart (systemd user services). Headless mode for reliability.
if id "$BUDDY_USER" &>/dev/null; then
    log_info "Configuring MoonDeck Buddy autostart for user $BUDDY_USER..."
    # Enable autostart via CLI if supported (creates systemd user services)
    if sudo -u "$BUDDY_USER" MoonDeckBuddy --enable-autostart 2>/dev/null; then
        log_info "MoonDeck Buddy --enable-autostart succeeded"
    fi
    # Ensure headless unit runs with NO_GUI=1 so Buddy does not depend on compositor/display
    BUDDY_USER_UNIT_DIR="/home/$BUDDY_USER/.config/systemd/user"
    OVERRIDE_DIR="$BUDDY_USER_UNIT_DIR/moondeckbuddy.service.d"
    mkdir -p "$OVERRIDE_DIR"
    chown -R "$BUDDY_USER:$BUDDY_USER" "$BUDDY_USER_UNIT_DIR"
    if [[ ! -f "$OVERRIDE_DIR/override.conf" ]]; then
        cat > "$OVERRIDE_DIR/override.conf" << 'OVEREOF'
# Force headless mode so Buddy does not crash when display/compositor is unavailable
# TMPDIR=/tmp so Qt shared-memory key path matches MoonDeckStream (ENV regex IPC); see docs/env-regex-shared-memory-research.md
[Service]
Environment=NO_GUI=1
Environment=TMPDIR=/tmp
OVEREOF
        chown "$BUDDY_USER:$BUDDY_USER" "$OVERRIDE_DIR/override.conf"
        log_info "Created moondeckbuddy.service override (NO_GUI=1, TMPDIR=/tmp)"
    else
        # Existing override: ensure TMPDIR=/tmp for ENV regex IPC (Buddy↔MoonDeckStream same key path)
        if ! grep -q 'TMPDIR=' "$OVERRIDE_DIR/override.conf" 2>/dev/null; then
            echo "Environment=TMPDIR=/tmp" >> "$OVERRIDE_DIR/override.conf"
            chown "$BUDDY_USER:$BUDDY_USER" "$OVERRIDE_DIR/override.conf"
            log_info "Added TMPDIR=/tmp to moondeckbuddy.service override"
        fi
    fi
    # Reload so override (e.g. TMPDIR=/tmp) is applied; restart so running Buddy picks up new env
    sudo -u "$BUDDY_USER" XDG_RUNTIME_DIR="/run/user/$(id -u "$BUDDY_USER")" systemctl --user daemon-reload 2>/dev/null || true
    sudo -u "$BUDDY_USER" XDG_RUNTIME_DIR="/run/user/$(id -u "$BUDDY_USER")" systemctl --user enable moondeckbuddy.service 2>/dev/null || log_warn "Could not enable moondeckbuddy.service"
    sudo -u "$BUDDY_USER" XDG_RUNTIME_DIR="/run/user/$(id -u "$BUDDY_USER")" systemctl --user restart moondeckbuddy.service 2>/dev/null || log_warn "Could not restart moondeckbuddy.service (install Buddy and run --enable-autostart as $BUDDY_USER)"
    sudo -u "$BUDDY_USER" XDG_RUNTIME_DIR="/run/user/$(id -u "$BUDDY_USER")" systemctl --user enable --now moondeckbuddy-gui-session.service 2>/dev/null || true
else
    log_warn "User $BUDDY_USER not found; skip Buddy autostart. Create user and run: sudo -u $BUDDY_USER MoonDeckBuddy --enable-autostart && systemctl --user enable --now moondeckbuddy.service"
fi

# Create stream user if it doesn't exist
if ! id "$STREAM_USER" &>/dev/null; then
    log_info "Creating user: $STREAM_USER"
    useradd -r -m -s /bin/bash -G video,input,tty "$STREAM_USER" || log_fatal "Failed to create user"
else
    log_info "User $STREAM_USER already exists"
    # Ensure user is in required groups (including tty for VT access if needed)
    usermod -aG video,input,tty "$STREAM_USER" || true
fi

# --- Audio Bridge Setup ---
log_info "Adding $STREAM_USER to audio group for ALSA access..."
usermod -aG audio "$STREAM_USER" || true

log_info "Configuring snd-aloop module..."
if [[ -f "$REPO_ROOT/etc/modules-load.d/snd-aloop.conf" ]]; then
    cp "$REPO_ROOT/etc/modules-load.d/snd-aloop.conf" /etc/modules-load.d/
else
    printf '# ALSA loopback for Stream Deck audio bridge\nsnd-aloop\n' > /etc/modules-load.d/snd-aloop.conf
fi

if ! lsmod | grep -q snd_aloop; then
    modprobe snd-aloop
fi

log_info "Installing audio bridge scripts..."
# Install to /usr/local so streamdeck user can execute (cannot traverse /home/__BUDDY_USER__)
INSTALL_SCRIPT_DIR="/usr/local/lib/streamdeck/scripts"
mkdir -p "$INSTALL_SCRIPT_DIR"
install -m 0755 "$REPO_ROOT/scripts/audio-bridge.sh" "$INSTALL_SCRIPT_DIR/"
install -m 0755 "$REPO_ROOT/scripts/audio-capture-bridge.sh" "$INSTALL_SCRIPT_DIR/"

log_info "Installing audio bridge and capture services..."
# Create streamdeck-audio runtime dir via tmpfiles (PipeWire needs it before service start)
if [[ -f "$REPO_ROOT/etc/tmpfiles.d/streamdeck-audio.conf" ]]; then
    install -m 0644 "$REPO_ROOT/etc/tmpfiles.d/streamdeck-audio.conf" /etc/tmpfiles.d/
    systemd-tmpfiles --create /etc/tmpfiles.d/streamdeck-audio.conf 2>/dev/null || true
fi
cp "$REPO_ROOT/systemd/streamdeck-audio-bridge.service" /etc/systemd/system/
cp "$REPO_ROOT/systemd/streamdeck-pipewire.service" /etc/systemd/system/
cp "$REPO_ROOT/systemd/streamdeck-audio-capture.service" /etc/systemd/system/

# Create directories
log_info "Creating directories..."
mkdir -p /etc/X11/xorg.conf.d
mkdir -p /etc/X11/edid
mkdir -p "$STREAM_HOME/.config/sunshine"
mkdir -p /var/log/sunshine
mkdir -p "/var/log/$STREAM_USER"
chown -R "$STREAM_USER:$STREAM_USER" "$STREAM_HOME/.config"
chown -R "$STREAM_USER:$STREAM_USER" /var/log/sunshine
chown -R "$STREAM_USER:$STREAM_USER" "/var/log/$STREAM_USER"

# Configure Xwrapper to allow non-console users to run Xorg
# This is required for the stream user to start Xorg from systemd
log_info "Configuring Xwrapper..."
cat > /etc/X11/Xwrapper.config <<EOF
# Allow any user to run Xorg (required for systemd service running as stream user)
# Security: The stream user is restricted and only runs the isolated streaming session
allowed_users=anybody
EOF

# Verify Xwrapper config was created
if [[ ! -f /etc/X11/Xwrapper.config ]]; then
    log_fatal "Failed to create /etc/X11/Xwrapper.config"
fi
log_info "Xwrapper configured: $(cat /etc/X11/Xwrapper.config | grep allowed_users)"

# Configure sudo to allow stream user to run steam/eden/MoonDeckStream as BUDDY_USER
log_info "Configuring sudoers for Steam access..."
SUDOERS_TEMPLATE="$REPO_ROOT/sudoers.d/streamdeck-steam.template"
if [[ -f "$SUDOERS_TEMPLATE" ]]; then
    sed -e "s|__STREAM_USER__|$STREAM_USER|g" -e "s|__BUDDY_USER__|$BUDDY_USER|g" "$SUDOERS_TEMPLATE" > /etc/sudoers.d/streamdeck-steam
    chmod 0440 /etc/sudoers.d/streamdeck-steam
    visudo -c -f /etc/sudoers.d/streamdeck-steam || log_fatal "Invalid sudoers file"
    log_info "Sudoers configured for Steam access"
else
    log_warn "sudoers.d/streamdeck-steam.template not found, skipping"
fi

# Install udev rules (from templates: stream user group for input isolation)
log_info "Installing udev rules..."
for template in "$REPO_ROOT"/udev/*.rules.template; do
    [[ -f "$template" ]] || continue
    basename_no_tpl="$(basename "$template" .rules.template)"
    out_name="${basename_no_tpl}.rules"
    sed "s|__STREAM_GROUP__|$STREAM_GROUP|g" "$template" > "/etc/udev/rules.d/$out_name"
    log_info "Installed udev rule: $out_name"
done
if compgen -G "$REPO_ROOT/udev/*.rules.template" >/dev/null; then
    udevadm control --reload-rules
    udevadm trigger --subsystem-match=tty
    udevadm trigger --subsystem-match=input
fi
if ! compgen -G "$REPO_ROOT/udev/*.rules.template" >/dev/null; then
    log_warn "No udev rule templates found in: $REPO_ROOT/udev/"
fi

# Install Xorg config
log_info "Installing Xorg configuration..."
XORG_CONF="/etc/X11/xorg.conf.d/99-streamdeck.conf"
if [[ -f "$REPO_ROOT/xorg/99-streamdeck.conf.template" ]]; then
    # For now, copy template as-is (could add variable substitution later)
    cp "$REPO_ROOT/xorg/99-streamdeck.conf.template" "$XORG_CONF"
    log_info "Installed Xorg config: $XORG_CONF"
else
    log_fatal "Xorg template not found: $REPO_ROOT/xorg/99-streamdeck.conf.template"
fi

# Install Sunshine config
log_info "Installing Sunshine configuration..."
SUNSHINE_CONF="$STREAM_HOME/.config/sunshine/sunshine.conf"
if [[ -f "$REPO_ROOT/sunshine/sunshine.conf.template" ]]; then
    # Substitute DISPLAY and optional ADAPTER_NAME (GPU PCI id for NVENC; see docs/installing.md)
    ADAPTER_NAME="${ADAPTER_NAME:-00000000:01:00.0}"
    sed -e "s|:99|$STREAM_DISPLAY|g" -e "s|__ADAPTER_NAME__|$ADAPTER_NAME|g" "$REPO_ROOT/sunshine/sunshine.conf.template" > "$SUNSHINE_CONF"
    chown "$STREAM_USER:$STREAM_USER" "$SUNSHINE_CONF"
    log_info "Installed Sunshine config: $SUNSHINE_CONF"
else
    log_fatal "Sunshine template not found: $REPO_ROOT/sunshine/sunshine.conf.template"
fi

# Install Sunshine apps.json (MoonDeck-first: MoonDeckStream + Desktop/Steam BP for debug).
# Template placeholders: :99 -> STREAM_DISPLAY; __BUDDY_USER__ / __BUDDY_UID__ -> Buddy user and UID.
# MoonDeckStream must run as Buddy user (same user as Buddy) and with SUNSHINE_LAUNCHED=1, DISPLAY, etc.
# MoonDeckStream app cmd is /usr/local/bin/MoonDeckStream (wrapper that kills stale PIDs and exec's real binary).
log_info "Installing Sunshine apps.json..."
APPS_JSON="$STREAM_HOME/.config/sunshine/apps.json"
BUDDY_UID=""
if id "$BUDDY_USER" &>/dev/null; then
    BUDDY_UID=$(id -u "$BUDDY_USER")
fi
if [[ -f "$REPO_ROOT/sunshine/apps.json.template" ]]; then
    sed -e "s|:99|$STREAM_DISPLAY|g" \
        -e "s|__BUDDY_USER__|$BUDDY_USER|g" \
        -e "s|__BUDDY_UID__|${BUDDY_UID:-0}|g" \
        "$REPO_ROOT/sunshine/apps.json.template" > "$APPS_JSON"
    chown "$STREAM_USER:$STREAM_USER" "$APPS_JSON"
    log_info "Installed apps.json: $APPS_JSON"
    if ! grep -q "sudo -u $BUDDY_USER.*MoonDeckStream" "$APPS_JSON" 2>/dev/null; then
        log_warn "MoonDeckStream app cmd may not run as $BUDDY_USER — check $APPS_JSON; exit 134 will persist if it runs as $STREAM_USER"
    fi
else
    log_warn "apps.json template not found, using default"
fi

# Install systemd units (from templates)
log_info "Installing systemd units..."

# Stop existing services before updating (idempotent - won't fail if not running)
systemctl stop streamdeck-sunshine.service 2>/dev/null || true
systemctl stop streamdeck-audio-capture.service 2>/dev/null || true
systemctl stop streamdeck-pipewire.service 2>/dev/null || true
systemctl stop streamdeck-audio-bridge.service 2>/dev/null || true
systemctl stop streamdeck-xorg.service 2>/dev/null || true

substitute_systemd() {
    local src="$1"
    local dest="$2"
    sed -e "s|__STREAM_USER__|$STREAM_USER|g" \
        -e "s|__STREAM_GROUP__|$STREAM_GROUP|g" \
        -e "s|__STREAM_DISPLAY__|$STREAM_DISPLAY|g" \
        -e "s|__STREAM_HOME__|$STREAM_HOME|g" \
        "$src" > "$dest"
}

XORG_TPL="$REPO_ROOT/systemd/streamdeck-xorg.service.template"
SUNSHINE_TPL="$REPO_ROOT/systemd/streamdeck-sunshine.service.template"
if [[ -f "$XORG_TPL" ]]; then
    substitute_systemd "$XORG_TPL" /etc/systemd/system/streamdeck-xorg.service
    log_info "Installed streamdeck-xorg.service"
else
    log_fatal "Xorg unit template not found: $XORG_TPL"
fi
if [[ -f "$SUNSHINE_TPL" ]]; then
    substitute_systemd "$SUNSHINE_TPL" /etc/systemd/system/streamdeck-sunshine.service
    log_info "Installed streamdeck-sunshine.service"
else
    log_fatal "Sunshine unit template not found: $SUNSHINE_TPL"
fi

# Audio services installed earlier in Audio Bridge Setup
# Reload systemd after installing all units
systemctl daemon-reload

# Enable services
log_info "Enabling services..."
systemctl enable streamdeck-xorg.service
systemctl enable streamdeck-audio-bridge.service
systemctl enable streamdeck-pipewire.service
systemctl enable streamdeck-audio-capture.service
systemctl enable streamdeck-sunshine.service

# Start audio bridge first (hard requirement; fail-fast if __BUDDY_USER__'s session inactive)
log_info "Starting audio bridge..."
if ! systemctl start streamdeck-audio-bridge.service; then
    log_error "Audio bridge failed to start (__BUDDY_USER__'s PipeWire session must be active)"
    log_error "Next step: ensure __BUDDY_USER__ is logged in (user session running), then re-run install"
    exit 1
fi

# Kill any stray Sunshine processes that might conflict
log_info "Checking for conflicting Sunshine processes..."
if pgrep -u "$STREAM_USER" sunshine &>/dev/null; then
    log_warn "Found existing Sunshine processes, stopping them..."
    pkill -u "$STREAM_USER" sunshine || true
    sleep 1
fi

# Start services
log_info "Starting services..."
systemctl restart streamdeck-xorg.service || log_error "Failed to start streamdeck-xorg"
sleep 2  # Give Xorg time to start
systemctl restart streamdeck-pipewire.service || log_error "Failed to start streamdeck-pipewire"
sleep 2  # Give PipeWire time to create pulse socket
systemctl restart streamdeck-audio-capture.service || log_error "Failed to start streamdeck-audio-capture"
sleep 2  # Give capture bridge time to create sink
systemctl restart streamdeck-sunshine.service || log_error "Failed to start streamdeck-sunshine"
sleep 12  # Give Sunshine time to initialize, test encoders, and recover from system tray crashes

# Health checks
log_info "Running health checks..."

HEALTH_FAILED=0

# GPU check
if check_nvidia_smi; then
    log_info "✓ nvidia-smi working"
else
    log_error "✗ nvidia-smi failed"
    HEALTH_FAILED=1
fi

# NVENC check
if check_nvenc; then
    log_info "✓ NVENC encoder detected"
else
    log_error "✗ NVENC encoder not detected"
    HEALTH_FAILED=1
fi

# Xorg display check
if check_xorg_display "$STREAM_DISPLAY"; then
    log_info "✓ Xorg display $STREAM_DISPLAY accessible"
else
    log_error "✗ Xorg display $STREAM_DISPLAY not accessible"
    HEALTH_FAILED=1
fi

# Xorg mode check
if check_xorg_mode "$STREAM_DISPLAY" "1280x800"; then
    log_info "✓ Mode 1280x800 found on display"
else
    log_error "✗ Mode 1280x800 not found"
    HEALTH_FAILED=1
fi

# Sunshine service check
if check_sunshine_service; then
    log_info "✓ streamdeck-sunshine.service is active"
else
    log_error "✗ streamdeck-sunshine.service is not active"
    HEALTH_FAILED=1
fi

# Sunshine logs check
SUNSHINE_LOG_DIR="/var/log/sunshine"
if check_sunshine_logs; then
    log_info "✓ Sunshine logs show successful startup"
else
    log_error "✗ Sunshine logs not found or show errors"
    HEALTH_FAILED=1
fi

# Summary
if [[ $HEALTH_FAILED -eq 0 ]]; then
    log_info ""
    log_info "Collecting post-install diagnostic logs..."
    INSTALL_LOG_DIR="$("$REPO_ROOT/collect-logs.sh")"
    log_info "Logs collected to: $INSTALL_LOG_DIR"
    log_info ""
    log_info "=========================================="
    log_info "Setup completed successfully!"
    log_info "=========================================="
    log_info ""
    log_info "Services are running:"
    log_info "  - streamdeck-xorg.service"
    log_info "  - streamdeck-sunshine.service"
    log_info ""
    log_info "Next steps:"
    log_info "  1. Pair Moonlight on Steam Deck with this PC"
    log_info "  2. Run ./test-full-cycle.sh for end-to-end testing"
    exit 0
else
    log_error ""
    log_error "=========================================="
    log_error "Setup completed with errors!"
    log_error "=========================================="
    log_error ""
    log_error "Collecting diagnostic logs..."
    INSTALL_LOG_DIR="$("$REPO_ROOT/collect-logs.sh")"
    log_error "Logs collected to: $INSTALL_LOG_DIR"
    exit 1
fi
