#!/bin/bash
# Experiment: Test PulseAudio access for streamdeck user
# Hypothesis: streamdeck user cannot access PulseAudio due to authentication/permissions
# Tests multiple solutions systematically

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"
source "$REPO_ROOT/scripts/lib.sh"

# Configuration
STREAMDECK_USER="streamdeck"
STREAMDECK_UID="1001"
BEN_USER="__BUDDY_USER__"
BEN_UID="1000"
PULSE_SOCKET="/run/user/${BEN_UID}/pulse/native"
PULSE_COOKIE_BEN="/home/${BEN_USER}/.config/pulse/cookie"
PULSE_COOKIE_STREAMDECK="/home/${STREAMDECK_USER}/.config/pulse/cookie"

log_info "=== Audio Access Experiment ==="
log_info "Testing PulseAudio access for streamdeck user"
log_info ""

# Test 1: Check current PulseAudio state
log_info "[TEST 1] Current PulseAudio state"
log_info "Checking PulseAudio socket..."
if [[ -S "$PULSE_SOCKET" ]]; then
    log_info "✓ PulseAudio socket exists: $PULSE_SOCKET"
    ls -la "$PULSE_SOCKET"
else
    log_error "✗ PulseAudio socket not found: $PULSE_SOCKET"
fi

log_info ""
log_info "Checking PulseAudio cookie..."
if [[ -f "$PULSE_COOKIE_BEN" ]]; then
    log_info "✓ PulseAudio cookie exists: $PULSE_COOKIE_BEN"
    ls -la "$PULSE_COOKIE_BEN"
else
    log_warn "✗ PulseAudio cookie not found: $PULSE_COOKIE_BEN"
fi

log_info ""
log_info "Checking streamdeck user's PulseAudio config..."
if sudo -u "$STREAMDECK_USER" test -d "/home/${STREAMDECK_USER}/.config/pulse"; then
    log_info "✓ streamdeck PulseAudio config directory exists"
    sudo -u "$STREAMDECK_USER" ls -la "/home/${STREAMDECK_USER}/.config/pulse/" || true
else
    log_info "Creating streamdeck PulseAudio config directory..."
    sudo -u "$STREAMDECK_USER" mkdir -p "/home/${STREAMDECK_USER}/.config/pulse"
fi

# Test 2: Try accessing PulseAudio as streamdeck user (baseline)
log_info ""
log_info "[TEST 2] Baseline: streamdeck user PulseAudio access"
log_info "Testing if streamdeck can connect to PulseAudio..."
if sudo -u "$STREAMDECK_USER" PULSE_RUNTIME_PATH="/run/user/${BEN_UID}/pulse" pactl info &>/dev/null; then
    log_info "✓ streamdeck CAN access PulseAudio (unexpected!)"
    TEST2_RESULT="PASS"
else
    log_info "✗ streamdeck CANNOT access PulseAudio (expected)"
    TEST2_RESULT="FAIL"
fi

# Test 3: Copy PulseAudio cookie to streamdeck user
log_info ""
log_info "[TEST 3] Option A: Share PulseAudio cookie"
if [[ -f "$PULSE_COOKIE_BEN" ]]; then
    log_info "Copying PulseAudio cookie to streamdeck user..."
    sudo cp "$PULSE_COOKIE_BEN" "$PULSE_COOKIE_STREAMDECK"
    sudo chown "${STREAMDECK_USER}:${STREAMDECK_USER}" "$PULSE_COOKIE_STREAMDECK"
    sudo chmod 600 "$PULSE_COOKIE_STREAMDECK"
    log_info "✓ Cookie copied"
    
    log_info "Testing access with cookie..."
    if sudo -u "$STREAMDECK_USER" PULSE_RUNTIME_PATH="/run/user/${BEN_UID}/pulse" PULSE_COOKIE="$PULSE_COOKIE_STREAMDECK" pactl info &>/dev/null; then
        log_info "✓ streamdeck CAN access PulseAudio with cookie!"
        TEST3_RESULT="PASS"
    else
        log_info "✗ streamdeck still cannot access PulseAudio with cookie"
        TEST3_RESULT="FAIL"
    fi
else
    log_warn "✗ Cannot test: PulseAudio cookie not found"
    TEST3_RESULT="SKIP"
fi

# Test 4: Check PulseAudio module configuration
log_info ""
log_info "[TEST 4] Option B: PulseAudio module configuration"
log_info "Checking PulseAudio modules (as __BUDDY_USER__ user)..."
if sudo -u "$BEN_USER" pactl list modules short 2>/dev/null | grep -q "module-native-protocol-unix"; then
    log_info "✓ module-native-protocol-unix is loaded"
    sudo -u "$BEN_USER" pactl list modules short 2>/dev/null | grep "module-native-protocol-unix" || true
else
    log_warn "✗ module-native-protocol-unix not found (or cannot connect)"
fi

log_info ""
log_info "Checking for virtual sink..."
if sudo -u "$BEN_USER" pactl list sinks short 2>/dev/null | grep -q "null"; then
    log_info "✓ Virtual/null sink exists"
    sudo -u "$BEN_USER" pactl list sinks short 2>/dev/null | grep "null" || true
else
    log_info "No virtual sink found (may need to create one)"
fi

# Test 5: Check ALSA access
log_info ""
log_info "[TEST 5] Option D: ALSA direct access"
log_info "Checking if streamdeck user is in audio group..."
if groups "$STREAMDECK_USER" | grep -q "audio"; then
    log_info "✓ streamdeck user is in audio group"
    TEST5_RESULT="PASS"
else
    log_info "✗ streamdeck user is NOT in audio group"
    log_info "Would need: sudo usermod -aG audio streamdeck"
    TEST5_RESULT="FAIL"
fi

log_info ""
log_info "Checking ALSA devices..."
if sudo -u "$STREAMDECK_USER" aplay -l &>/dev/null; then
    log_info "✓ streamdeck can access ALSA devices"
    sudo -u "$STREAMDECK_USER" aplay -l 2>&1 | head -5 || true
else
    log_info "✗ streamdeck cannot access ALSA devices"
    sudo -u "$STREAMDECK_USER" aplay -l 2>&1 | head -5 || true
fi

# Test 6: Test Sunshine audio capture (if running)
log_info ""
log_info "[TEST 6] Sunshine audio capture test"
if systemctl is-active --quiet streamdeck-sunshine.service; then
    log_info "Sunshine is running, checking logs for audio errors..."
    if journalctl -u streamdeck-sunshine.service --no-pager -n 50 | grep -q "Couldn't connect to pulseaudio"; then
        log_info "✗ Sunshine still showing PulseAudio connection errors"
        journalctl -u streamdeck-sunshine.service --no-pager -n 50 | grep -i "pulse\|audio" || true
    else
        log_info "✓ No PulseAudio errors in recent Sunshine logs"
    fi
else
    log_info "Sunshine is not running (skipping)"
fi

# Summary
log_info ""
log_info "=== EXPERIMENT SUMMARY ==="
log_info "Test 1 (Current state): PulseAudio socket and cookie checked"
log_info "Test 2 (Baseline): $TEST2_RESULT"
log_info "Test 3 (Cookie sharing): $TEST3_RESULT"
log_info "Test 4 (Module config): Checked PulseAudio modules"
log_info "Test 5 (ALSA access): $TEST5_RESULT"
log_info "Test 6 (Sunshine): Checked Sunshine logs"
log_info ""
log_info "Next steps:"
if [[ "$TEST3_RESULT" == "PASS" ]]; then
    log_info "→ Cookie sharing WORKS! Update systemd service to use cookie"
elif [[ "$TEST5_RESULT" == "FAIL" ]]; then
    log_info "→ Consider adding streamdeck to audio group for ALSA access"
else
    log_info "→ May need to configure PulseAudio for cross-user access"
fi
