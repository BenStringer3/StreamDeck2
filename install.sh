#!/bin/bash
# Idempotent installation script for Stream Deck → Moonlight → Sunshine setup

set -euo pipefail

# Source shared library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"
source "$REPO_ROOT/scripts/lib.sh"

# Configuration
STREAM_USER="${STREAM_USER:-streamdeck}"
STREAM_DISPLAY="${STREAM_DISPLAY:-:99}"

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

# Detect system state
log_info "Probing system state..."

# Check for existing EDID file
EDID_PATH="/etc/X11/edid/steamdeck-edid.bin"
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
    log_fatal "No NVIDIA driver package detected. Please install one of: nvidia-open-dkms, nvidia-open, nvidia, nvidia-dkms"
fi

# Install dependencies
log_info "Installing dependencies..."
# Only install nvidia-utils (provides nvidia-smi) - skip kernel driver package since it's already installed
# xf86-video-dummy: dummy driver for headless Xorg; pipewire/pipewire-pulse for streamdeck audio capture
# openbox: lightweight window manager on :99 (needed so apps can request fullscreen via EWMH)
# xterm: Sunshine Desktop app runs this on :99 when user launches Desktop from Moonlight
pacman -Sy --noconfirm --needed \
    xorg-server \
    xorg-xrandr \
    xf86-video-dummy \
    openbox \
    xterm \
    nvidia-utils \
    wl-clipboard || log_fatal "Failed to install dependencies"

# Install sunshine from AUR (idempotent)
log_info "Installing sunshine from AUR..."
if ! pacman -Q sunshine &>/dev/null; then
    # Check if yay is available
    if ! command -v yay &>/dev/null; then
        log_fatal "yay AUR helper not found. Please install yay first: pacman -S --needed base-devel git && cd /tmp && git clone https://aur.archlinux.org/yay.git && cd yay && makepkg -si"
    fi
    # Install sunshine from AUR (yay handles dropping root privileges automatically)
    yay -S --needed --noconfirm sunshine || log_fatal "Failed to install sunshine from AUR"
else
    log_info "sunshine is already installed"
fi

# Install MoonDeck Buddy (host helper for MoonDeck plugin). Runs as user __BUDDY_USER__; Sunshine invokes MoonDeckStream.
log_info "Installing MoonDeck Buddy..."
MOONDECK_APPIMAGE="/opt/moondeckbuddy/MoonDeckBuddy.AppImage"
MOONDECK_OPT_DIR="/opt/moondeckbuddy"
BUDDY_INSTALLED=0
if pacman -Q moondeckbuddy-appimage &>/dev/null; then
    log_info "moondeckbuddy-appimage already installed"
    BUDDY_INSTALLED=1
elif command -v yay &>/dev/null; then
    if yay -S --needed --noconfirm moondeckbuddy-appimage; then
        BUDDY_INSTALLED=1
    else
        log_warn "AUR install of moondeckbuddy-appimage failed, will try AppImage fallback"
    fi
else
    log_warn "yay not available, will try AppImage fallback"
fi
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

# Configure MoonDeck Buddy autostart as user __BUDDY_USER__ (systemd user services). Headless mode for reliability.
BUDDY_USER="${BUDDY_USER:-__BUDDY_USER__}"
if id "$BUDDY_USER" &>/dev/null; then
    log_info "Configuring MoonDeck Buddy autostart for user $BUDDY_USER..."
    # Enable autostart via CLI if supported (creates systemd user services)
    if sudo -u "$BUDDY_USER" MoonDeckBuddy --enable-autostart 2>/dev/null; then
        log_info "MoonDeck Buddy --enable-autostart succeeded"
    fi
    # Ensure headless unit runs with NO_GUI=1 so Buddy does not depend on compositor/display
    BEN_USER_UNIT_DIR="/home/$BUDDY_USER/.config/systemd/user"
    OVERRIDE_DIR="$BEN_USER_UNIT_DIR/moondeckbuddy.service.d"
    mkdir -p "$OVERRIDE_DIR"
    chown -R "$BUDDY_USER:$BUDDY_USER" "$BEN_USER_UNIT_DIR"
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

# Create streamdeck user if it doesn't exist
if ! id "$STREAM_USER" &>/dev/null; then
    log_info "Creating user: $STREAM_USER"
    useradd -r -m -s /bin/bash -G video,input,tty "$STREAM_USER" || log_fatal "Failed to create user"
else
    log_info "User $STREAM_USER already exists"
    # Ensure user is in required groups (including tty for VT access if needed)
    usermod -aG video,input,tty "$STREAM_USER" || true
fi

# Create directories
log_info "Creating directories..."
mkdir -p /etc/X11/xorg.conf.d
mkdir -p /etc/X11/edid
mkdir -p /home/"$STREAM_USER"/.config/sunshine
mkdir -p /var/log/sunshine
mkdir -p /var/log/streamdeck
chown -R "$STREAM_USER:$STREAM_USER" /home/"$STREAM_USER"/.config
chown -R "$STREAM_USER:$STREAM_USER" /var/log/sunshine
chown -R "$STREAM_USER:$STREAM_USER" /var/log/streamdeck

# Configure Xwrapper to allow non-console users to run Xorg
# This is required for the streamdeck user to start Xorg from systemd
log_info "Configuring Xwrapper..."
cat > /etc/X11/Xwrapper.config <<EOF
# Allow any user to run Xorg (required for systemd service running as streamdeck user)
# Security: The streamdeck user is restricted and only runs the isolated streaming session
allowed_users=anybody
EOF

# Verify Xwrapper config was created
if [[ ! -f /etc/X11/Xwrapper.config ]]; then
    log_fatal "Failed to create /etc/X11/Xwrapper.config"
fi
log_info "Xwrapper configured: $(cat /etc/X11/Xwrapper.config | grep allowed_users)"

# Configure sudo to allow streamdeck user to run steam as __BUDDY_USER__
# This enables launching Steam with __BUDDY_USER__'s library from the streaming session
log_info "Configuring sudoers for Steam access..."
if [[ -f "$REPO_ROOT/sudoers.d/streamdeck-steam" ]]; then
    install -m 0440 "$REPO_ROOT/sudoers.d/streamdeck-steam" /etc/sudoers.d/streamdeck-steam
    visudo -c -f /etc/sudoers.d/streamdeck-steam || log_fatal "Invalid sudoers file"
    log_info "Sudoers configured for Steam access"
else
    log_warn "sudoers.d/streamdeck-steam not found, skipping"
fi

# Install udev rule for tty device access
log_info "Installing udev rule for tty access..."
# We ship udev rules to:
# - allow streamdeck to access tty (for Xorg/VT edge cases)
# - isolate Sunshine virtual input devices so Moonlight input doesn't leak into the desktop session
if compgen -G "$REPO_ROOT/udev/*.rules" >/dev/null; then
    cp "$REPO_ROOT"/udev/*.rules /etc/udev/rules.d/
    udevadm control --reload-rules
    # Re-apply rules to the relevant subsystems.
    udevadm trigger --subsystem-match=tty
    udevadm trigger --subsystem-match=input
    log_info "Installed udev rules from: $REPO_ROOT/udev/"
else
    log_warn "No udev rules found in: $REPO_ROOT/udev/"
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
SUNSHINE_CONF="/home/$STREAM_USER/.config/sunshine/sunshine.conf"
if [[ -f "$REPO_ROOT/sunshine/sunshine.conf.template" ]]; then
    # Substitute DISPLAY variable
    sed "s|:99|$STREAM_DISPLAY|g" "$REPO_ROOT/sunshine/sunshine.conf.template" > "$SUNSHINE_CONF"
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
APPS_JSON="/home/$STREAM_USER/.config/sunshine/apps.json"
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
        log_warn "MoonDeckStream app cmd may not run as $BUDDY_USER — check $APPS_JSON; exit 134 will persist if it runs as streamdeck"
    fi
else
    log_warn "apps.json template not found, using default"
fi

# Install systemd units
log_info "Installing systemd units..."

# Stop existing services before updating (idempotent - won't fail if not running)
systemctl stop streamdeck-sunshine.service 2>/dev/null || true
systemctl stop streamdeck-xorg.service 2>/dev/null || true

# Install xorg service
XORG_UNIT="$REPO_ROOT/systemd/streamdeck-xorg.service"
if [[ -f "$XORG_UNIT" ]]; then
    cp "$XORG_UNIT" /etc/systemd/system/
    log_info "Installed streamdeck-xorg.service"
else
    log_fatal "Xorg unit not found: $XORG_UNIT"
fi

# Install sunshine service
SUNSHINE_UNIT="$REPO_ROOT/systemd/streamdeck-sunshine.service"
if [[ -f "$SUNSHINE_UNIT" ]]; then
    cp "$SUNSHINE_UNIT" /etc/systemd/system/
    log_info "Installed streamdeck-sunshine.service"
else
    log_fatal "Sunshine unit not found: $SUNSHINE_UNIT"
fi

# Reload systemd after installing all units
systemctl daemon-reload

# Enable services
log_info "Enabling services..."
systemctl enable streamdeck-xorg.service
systemctl enable streamdeck-sunshine.service

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
