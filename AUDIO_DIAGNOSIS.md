# Audio Issue Diagnosis - Horizon Forbidden West Streaming

## Root Cause Analysis

### Primary Issue Identified
**Error**: `Couldn't connect to pulseaudio: Access denied`
**Location**: Sunshine logs (lines 41-43, 197-199)
**Impact**: No audio in stream

### Evidence from Logs
```
[2026-02-13 16:21:30.508]: Error: Couldn't connect to pulseaudio: Access denied
[2026-02-13 16:21:30.508]: Warning: There will be no audio
[2026-02-13 16:21:30.508]: Error: Unable to initialize audio capture. The stream will not have audio.
```

### System State
- **Sunshine user**: `streamdeck` (uid=1001)
- **PulseAudio user**: `__BUDDY_USER__` (uid=1000)
- **PulseAudio socket**: `/run/user/1000/pulse/native` (owned by __BUDDY_USER__)
- **Audio system**: PipeWire with PulseAudio compatibility
- **streamdeck groups**: streamdeck, input, render, tty, video (NOT in audio group)

## Potential Root Causes (Brainstormed)

### 1. PulseAudio Socket Permissions
- Socket is in `/run/user/1000/` which is owned by `__BUDDY_USER__`
- Even with `srw-rw-rw-` permissions, PulseAudio uses cookie-based authentication
- `streamdeck` user cannot access `__BUDDY_USER__`'s user directory

### 2. PulseAudio Cookie Authentication
- PulseAudio requires a cookie file (`~/.config/pulse/cookie`) for authentication
- Cookie is user-specific and not accessible to `streamdeck` user
- Even if socket is accessible, authentication will fail without cookie

### 3. Systemd Service Context
- Sunshine runs as systemd service with `User=streamdeck`
- Systemd services may not have access to user session PulseAudio sockets
- PulseAudio socket may not be in systemd's environment

### 4. PulseAudio Module Configuration
- May need to load `module-native-protocol-unix` with `auth-anonymous=1`
- May need to configure `module-native-protocol-tcp` for network access
- Virtual sink modules may not be loaded

### 5. ALSA Direct Access Alternative
- Could bypass PulseAudio entirely
- Requires `streamdeck` user in `audio` group
- Less flexible than PulseAudio but simpler

## Hypothesis

**Primary Hypothesis**: The `streamdeck` user cannot authenticate to PulseAudio because:
1. PulseAudio cookie (`~/.config/pulse/cookie`) is not accessible to `streamdeck` user
2. PulseAudio socket authentication requires cookie validation
3. Systemd service context doesn't provide user session PulseAudio access

**Expected Solution**: Grant `streamdeck` user access to PulseAudio through one of:
- **Option A**: Share PulseAudio cookie (copy to streamdeck user's home)
- **Option B**: Configure PulseAudio for anonymous/trusted connections
- **Option C**: Create virtual sink with cross-user access
- **Option D**: Use ALSA directly (bypass PulseAudio)

## Experiment Design

See `experiment-audio-access.sh` for systematic testing of each option.
