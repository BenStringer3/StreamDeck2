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
    # Check if NVENC is available by checking Sunshine logs for successful encoder detection
    # This is more reliable than checking ffmpeg directly since Sunshine uses PRIME offload
    if journalctl -u streamdeck-sunshine.service --no-pager -n 200 2>/dev/null | grep -E "Found H.264 encoder.*nvenc|Found HEVC encoder.*nvenc" >/dev/null; then
        return 0
    fi
    # Fallback: check if ffmpeg has nvenc encoders
    if command -v ffmpeg &>/dev/null; then
        if ffmpeg -hide_banner -encoders 2>/dev/null | grep -E "h264_nvenc|hevc_nvenc" >/dev/null; then
            return 0
        fi
    fi
    # Last resort: check nvidia-smi for encoder support
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
    # Journal: need enough lines that startup (or per-session encoder probe) is not pushed out by
    # interleaved Steam/sudo lines during MoonDeckStream — n=100 caused false FAIL while NVENC passed (n=200).
    local log_dir="${SUNSHINE_LOG_DIR:-/var/log/sunshine}"
    local journal_lines=400
    local js
    js="$(journalctl -u streamdeck-sunshine.service --no-pager -n "$journal_lines" 2>/dev/null || true)"
    # Note: Use grep -E ... >/dev/null instead of grep -qE to avoid SIGPIPE issues in pipelines
    if echo "$js" | grep -E "Found H\.264 encoder|Found HEVC encoder" >/dev/null; then
        if echo "$js" | grep -E "Address already in use" >/dev/null; then
            log_error "Sunshine has port conflict - another instance may be running"
            return 1
        fi
        return 0
    fi
    # Fallback: on-disk log (readable if test runs as user with access, or install.sh as root)
    if [[ -r "$log_dir/sunshine.log" ]] && grep -E "Found H\.264 encoder|Found HEVC encoder" "$log_dir/sunshine.log" >/dev/null 2>&1; then
        return 0
    fi
    if [[ -f "$log_dir/sunshine.log" ]] && grep -E "Sunshine version" "$log_dir/sunshine.log" >/dev/null 2>&1; then
        return 0
    fi
    log_error "Sunshine logs not found or don't show successful startup"
    return 1
}

check_audio_tcp() {
    # Verify that STREAM_USER can connect to Buddy's PipeWire-Pulse TCP listener.
    # Requires: STREAM_USER set, pactl available.
    local stream_user="${STREAM_USER:-streamdeck}"
    if ! command -v pactl &>/dev/null; then
        log_warn "pactl not found; cannot verify audio connectivity"
        return 1
    fi
    if sudo -u "$stream_user" PULSE_SERVER=tcp:127.0.0.1:4713 pactl info &>/dev/null; then
        return 0
    fi
    log_error "Audio: $stream_user cannot connect to PipeWire-Pulse at tcp:127.0.0.1:4713 (see docs/audio-pipeline.md)"
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

# Detect installed NVIDIA driver package (distribution-agnostic)
# Returns the package name or a label if found; empty and return 1 if not found
detect_nvidia_driver() {
    # Arch: pacman
    if command -v pacman &>/dev/null; then
        local drivers=(nvidia-open-dkms nvidia-open nvidia-open-lts nvidia nvidia-dkms nvidia-lts nvidia-580xx-dkms)
        for driver in "${drivers[@]}"; do
            if pacman -Q "$driver" &>/dev/null; then
                echo "$driver"
                return 0
            fi
        done
    fi

    # Debian/Ubuntu: dpkg
    if command -v dpkg &>/dev/null; then
        local pkg
        pkg=$(dpkg -l 2>/dev/null | awk '$2 ~ /^nvidia-(driver|utils)/ && $1 == "ii" {print $2; exit}')
        if [[ -n "$pkg" ]]; then
            echo "$pkg"
            return 0
        fi
    fi

    # Fedora/RHEL: rpm
    if command -v rpm &>/dev/null; then
        if rpm -q akmod-nvidia &>/dev/null; then
            echo "akmod-nvidia"
            return 0
        fi
        if rpm -q nvidia-driver &>/dev/null; then
            echo "nvidia-driver"
            return 0
        fi
    fi

    # Fallback: nvidia-smi present => assume driver installed
    if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
        echo "nvidia (nvidia-smi)"
        return 0
    fi

    return 1
}

# Path resolution
get_repo_root() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    echo "$(cd "$script_dir/.." && pwd)"
}
