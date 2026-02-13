#!/bin/bash
# Experiment: Test PipeWire/PulseAudio access for streamdeck user
# Updated hypothesis: PipeWire uses stricter authentication than PulseAudio
# Tests multiple approaches: PipeWire config, virtual sinks, ALSA direct access

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"
source "$REPO_ROOT/scripts/lib.sh"

STREAMDECK_USER="streamdeck"
STREAMDECK_UID="1001"
BEN_USER="__BUDDY_USER__"
BEN_UID="1000"
PULSE_SOCKET="/run/user/${BEN_UID}/pulse/native"
PIPEWIRE_SOCKET="/run/user/${BEN_UID}/pipewire-0"
PULSE_COOKIE_BEN="/home/${BEN_USER}/.config/pulse/cookie"
PULSE_COOKIE_STREAMDECK="/home/${STREAMDECK_USER}/.config/pulse/cookie"

log_info "=== Audio Access Experiment (PipeWire Edition) ==="
log_info "Testing PipeWire/PulseAudio access for streamdeck user"
log_info ""

# Test 1: Check PipeWire vs PulseAudio
log_info "[TEST 1] Audio system identification"
log_info "Checking what audio system is running..."
if pactl info 2>/dev/null | grep -q "PipeWire"; then
    AUDIO_SYSTEM="PipeWire"
    log_info "✓ System is using PipeWire (with PulseAudio compatibility)"
    pactl info 2>/dev/null | grep "Server Name" || true
else
    AUDIO_SYSTEM="PulseAudio"
    log_info "✓ System is using PulseAudio"
fi

log_info ""
log_info "Checking sockets..."
if [[ -S "$PIPEWIRE_SOCKET" ]]; then
    log_info "✓ PipeWire socket exists: $PIPEWIRE_SOCKET"
    ls -la "$PIPEWIRE_SOCKET"
fi
if [[ -S "$PULSE_SOCKET" ]]; then
    log_info "✓ PulseAudio socket exists: $PULSE_SOCKET"
    ls -la "$PULSE_SOCKET"
fi

# Test 2: Test cookie-based access (baseline - we know this fails)
log_info ""
log_info "[TEST 2] Cookie-based access (baseline)"
log_info "Testing if streamdeck can access PulseAudio with cookie..."
if sudo -u "$STREAMDECK_USER" PULSE_RUNTIME_PATH="/run/user/${BEN_UID}/pulse" PULSE_COOKIE="$PULSE_COOKIE_STREAMDECK" pactl info &>/dev/null 2>&1; then
    log_info "✓ streamdeck CAN access PulseAudio with cookie!"
    TEST2_RESULT="PASS"
else
    ERROR_MSG=$(sudo -u "$STREAMDECK_USER" PULSE_RUNTIME_PATH="/run/user/${BEN_UID}/pulse" PULSE_COOKIE="$PULSE_COOKIE_STREAMDECK" pactl info 2>&1 || true)
    log_info "✗ streamdeck CANNOT access PulseAudio with cookie"
    log_info "Error: $ERROR_MSG"
    TEST2_RESULT="FAIL"
fi

# Test 3: Test PipeWire socket access directly
log_info ""
log_info "[TEST 3] PipeWire socket access"
log_info "Testing if streamdeck can access PipeWire socket directly..."
if sudo -u "$STREAMDECK_USER" PIPEWIRE_RUNTIME_DIR="/run/user/${BEN_UID}" pw-cli info 0 &>/dev/null 2>&1; then
    log_info "✓ streamdeck CAN access PipeWire socket!"
    TEST3_RESULT="PASS"
else
    ERROR_MSG=$(sudo -u "$STREAMDECK_USER" PIPEWIRE_RUNTIME_DIR="/run/user/${BEN_UID}" pw-cli info 0 2>&1 || true)
    log_info "✗ streamdeck CANNOT access PipeWire socket"
    log_info "Error: $ERROR_MSG"
    TEST3_RESULT="FAIL"
fi

# Test 4: Create virtual sink and test access
log_info ""
log_info "[TEST 4] Virtual sink creation"
log_info "Creating a virtual sink (null sink) for streaming..."
VIRTUAL_SINK_NAME="streamdeck-sink"
if sudo -u "$BEN_USER" pactl list sinks short | grep -q "$VIRTUAL_SINK_NAME"; then
    log_info "✓ Virtual sink already exists: $VIRTUAL_SINK_NAME"
    sudo -u "$BEN_USER" pactl list sinks short | grep "$VIRTUAL_SINK_NAME" || true
else
    log_info "Creating virtual sink..."
    if sudo -u "$BEN_USER" pactl load-module module-null-sink sink_name="$VIRTUAL_SINK_NAME" sink_properties=device.description="StreamDeck\ Audio" &>/dev/null; then
        log_info "✓ Virtual sink created: $VIRTUAL_SINK_NAME"
        sudo -u "$BEN_USER" pactl list sinks short | grep "$VIRTUAL_SINK_NAME" || true
    else
        log_error "✗ Failed to create virtual sink"
        TEST4_RESULT="FAIL"
    fi
fi

# Test 5: Test ALSA direct access
log_info ""
log_info "[TEST 5] ALSA direct access"
log_info "Checking if streamdeck user is in audio group..."
if groups "$STREAMDECK_USER" | grep -q "audio"; then
    log_info "✓ streamdeck user is in audio group"
    TEST5A_RESULT="PASS"
else
    log_info "✗ streamdeck user is NOT in audio group"
    log_info "Would need: sudo usermod -aG audio streamdeck"
    TEST5A_RESULT="FAIL"
fi

log_info ""
log_info "Checking ALSA devices..."
if command -v aplay &>/dev/null; then
    if sudo -u "$STREAMDECK_USER" aplay -l &>/dev/null 2>&1; then
        log_info "✓ streamdeck can access ALSA devices"
        sudo -u "$STREAMDECK_USER" aplay -l 2>&1 | head -5 || true
        TEST5B_RESULT="PASS"
    else
        log_info "✗ streamdeck cannot access ALSA devices"
        ERROR_MSG=$(sudo -u "$STREAMDECK_USER" aplay -l 2>&1 || true)
        log_info "Error: $ERROR_MSG"
        TEST5B_RESULT="FAIL"
    fi
else
    log_warn "aplay not found, cannot test ALSA access"
    TEST5B_RESULT="SKIP"
fi

# Test 6: Check Sunshine configuration for audio backend
log_info ""
log_info "[TEST 6] Sunshine audio configuration"
log_info "Checking Sunshine configuration..."
SUNSHINE_CONF="/home/${STREAMDECK_USER}/.config/sunshine/sunshine.conf"
if [[ -f "$SUNSHINE_CONF" ]]; then
    log_info "✓ Sunshine config exists"
    if grep -q "audio" "$SUNSHINE_CONF"; then
        log_info "Audio-related config found:"
        grep -i "audio" "$SUNSHINE_CONF" || true
    else
        log_info "No audio configuration found in Sunshine config"
        log_info "Sunshine may be using default PulseAudio backend"
    fi
else
    log_warn "Sunshine config not found: $SUNSHINE_CONF"
fi

# Test 7: Check PipeWire permissions/security
log_info ""
log_info "[TEST 7] PipeWire security/permissions"
log_info "Checking PipeWire security settings..."
if command -v pw-metadata &>/dev/null; then
    log_info "PipeWire metadata (as __BUDDY_USER__ user):"
    sudo -u "$BEN_USER" pw-metadata 2>/dev/null | grep -i "policy\|auth\|permission" | head -10 || log_info "No policy/auth metadata found"
else
    log_warn "pw-metadata not found"
fi

# Summary
log_info ""
log_info "=== EXPERIMENT SUMMARY ==="
log_info "Test 1 (Audio system): $AUDIO_SYSTEM detected"
log_info "Test 2 (Cookie access): $TEST2_RESULT"
log_info "Test 3 (PipeWire socket): $TEST3_RESULT"
log_info "Test 4 (Virtual sink): Created/checked"
log_info "Test 5A (Audio group): $TEST5A_RESULT"
log_info "Test 5B (ALSA access): $TEST5B_RESULT"
log_info "Test 6 (Sunshine config): Checked"
log_info "Test 7 (PipeWire security): Checked"
log_info ""
log_info "Hypothesis update:"
if [[ "$TEST2_RESULT" == "FAIL" && "$TEST3_RESULT" == "FAIL" ]]; then
    log_info "→ PipeWire uses stricter authentication than PulseAudio"
    log_info "→ Cookie sharing may not work with PipeWire"
    log_info "→ Need alternative approach: ALSA direct access or PipeWire config"
elif [[ "$TEST5A_RESULT" == "FAIL" ]]; then
    log_info "→ ALSA direct access requires audio group membership"
    log_info "→ Consider: sudo usermod -aG audio streamdeck"
fi
log_info ""
log_info "Recommended next steps:"
if [[ "$TEST5A_RESULT" == "FAIL" ]]; then
    log_info "1. Add streamdeck to audio group: sudo usermod -aG audio streamdeck"
    log_info "2. Configure Sunshine to use ALSA backend"
    log_info "3. Test ALSA capture"
elif [[ "$TEST4_RESULT" != "FAIL" ]]; then
    log_info "1. Configure PipeWire for cross-user access"
    log_info "2. Use virtual sink for audio capture"
    log_info "3. Route game audio to virtual sink"
fi
