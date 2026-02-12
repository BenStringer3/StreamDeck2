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

# Check for existing Sunshine installation
if systemctl list-units --type=service --all | grep -q "sunshine.service"; then
    log_warn "Existing sunshine.service found - may conflict with streamdeck-sunshine"
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
pacman -Sy --noconfirm --needed \
    xorg-server \
    xorg-xrandr \
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
chown -R "$STREAM_USER:$STREAM_USER" /home/"$STREAM_USER"/.config
chown -R "$STREAM_USER:$STREAM_USER" /var/log/sunshine

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

# Install Sunshine apps.json
log_info "Installing Sunshine apps.json..."
APPS_JSON="/home/$STREAM_USER/.config/sunshine/apps.json"
if [[ -f "$REPO_ROOT/sunshine/apps.json.template" ]]; then
    sed "s|:99|$STREAM_DISPLAY|g" "$REPO_ROOT/sunshine/apps.json.template" > "$APPS_JSON"
    chown "$STREAM_USER:$STREAM_USER" "$APPS_JSON"
    log_info "Installed apps.json: $APPS_JSON"
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
    log_error "Some health checks failed. Run ./collect-logs.sh for diagnostics."
    exit 1
fi
