#!/bin/bash
# Shared helper functions for streamdeck scripts

set -euo pipefail

# Logging functions
log_info() {
    echo "[INFO] $*" >&2
}

log_warn() {
    echo "[WARN] $*" >&2
}

log_error() {
    echo "[ERROR] $*" >&2
}

log_fatal() {
    echo "[FATAL] $*" >&2
    exit 1
}

# Assertion helpers
assert_command() {
    if ! command -v "$1" &>/dev/null; then
        log_fatal "Required command '$1' not found in PATH"
    fi
}

assert_root() {
    if [[ $EUID -ne 0 ]]; then
        log_fatal "This script must be run as root"
    fi
}

# Health check helpers
check_nvidia_smi() {
    if ! nvidia-smi &>/dev/null; then
        log_error "nvidia-smi failed"
        return 1
    fi
    return 0
}

check_nvenc() {
    # Check if NVENC is available via ffmpeg or nvidia-smi
    if command -v ffmpeg &>/dev/null; then
        if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q "h264_nvenc\|hevc_nvenc"; then
            return 0
        fi
    fi
    # Fallback: check nvidia-smi for encoder support
    if nvidia-smi --query-gpu=encoder.stats.session_count --format=csv,noheader &>/dev/null; then
        return 0
    fi
    log_error "NVENC encoder not detected"
    return 1
}

check_xorg_display() {
    local display="${1:-:99}"
    if ! DISPLAY="$display" xrandr --query &>/dev/null; then
        log_error "Xorg display $display not accessible"
        return 1
    fi
    return 0
}

check_xorg_mode() {
    local display="${1:-:99}"
    local expected_mode="${2:-1280x800}"
    if DISPLAY="$display" xrandr --query 2>/dev/null | grep -q "$expected_mode"; then
        return 0
    fi
    log_error "Expected mode $expected_mode not found on display $display"
    return 1
}

check_sunshine_service() {
    if systemctl is-active --quiet streamdeck-sunshine.service; then
        return 0
    fi
    log_error "streamdeck-sunshine.service is not active"
    return 1
}

check_sunshine_logs() {
    local log_dir="${SUNSHINE_LOG_DIR:-/var/log/sunshine}"
    if [[ -f "$log_dir/sunshine.log" ]] && grep -q "Sunshine version" "$log_dir/sunshine.log" 2>/dev/null; then
        return 0
    fi
    log_error "Sunshine logs not found or don't show successful startup"
    return 1
}

# System state collection
collect_systemctl_status() {
    local unit="$1"
    local output_file="$2"
    systemctl status "$unit" --no-pager > "$output_file" 2>&1 || true
}

collect_journalctl() {
    local unit="$1"
    local output_file="$2"
    local lines="${3:-200}"
    journalctl -u "$unit" -n "$lines" --no-pager > "$output_file" 2>&1 || true
}

# Version detection
get_sunshine_version() {
    if command -v sunshine &>/dev/null; then
        sunshine --version 2>&1 || echo "unknown"
    else
        echo "not installed"
    fi
}

get_nvidia_driver_version() {
    if command -v nvidia-smi &>/dev/null; then
        nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -n1 || echo "unknown"
    else
        echo "not available"
    fi
}

get_kernel_version() {
    uname -a
}

# Detect installed NVIDIA driver package
# Returns the package name if found, empty string if not found
detect_nvidia_driver() {
    # Check for common NVIDIA driver packages
    local drivers=(
        "nvidia-open-dkms"
        "nvidia-open"
        "nvidia-open-lts"
        "nvidia"
        "nvidia-dkms"
        "nvidia-lts"
        "nvidia-580xx-dkms"
    )
    
    for driver in "${drivers[@]}"; do
        if pacman -Q "$driver" &>/dev/null; then
            echo "$driver"
            return 0
        fi
    done
    
    # No driver package found
    return 1
}

# Path resolution
get_repo_root() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    echo "$(cd "$script_dir/.." && pwd)"
}
