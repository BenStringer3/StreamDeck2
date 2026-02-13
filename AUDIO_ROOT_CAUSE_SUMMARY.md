# Audio Issue Root Cause Summary

## Problem Statement
**No audio when streaming Horizon Forbidden West to Steam Deck**

## Root Cause Identified
**PulseAudio Access Denied**: Sunshine (running as `streamdeck` user) cannot connect to PulseAudio (running in `__BUDDY_USER__`'s user session)

### Evidence
From `/tmp/streamdeck-test-20260213-162325/journalctl-sunshine.log`:
```
[2026-02-13 16:21:30.508]: Error: Couldn't connect to pulseaudio: Access denied
[2026-02-13 16:21:30.508]: Warning: There will be no audio
[2026-02-13 16:21:30.508]: Error: Unable to initialize audio capture. The stream will not have audio.
```

### System Context
- **Sunshine service**: Runs as `streamdeck` user (uid=1001) via systemd
- **PulseAudio**: Runs in `__BUDDY_USER__`'s user session (uid=1000)
- **PulseAudio socket**: `/run/user/1000/pulse/native` (user-specific)
- **Audio system**: PipeWire with PulseAudio compatibility layer
- **Authentication**: PulseAudio uses cookie-based authentication (`~/.config/pulse/cookie`)

## Potential Root Causes (Brainstormed)

### 1. **PulseAudio Cookie Authentication** (Most Likely)
- PulseAudio requires a cookie file for authentication
- Cookie is stored in `~/.config/pulse/cookie` (user-specific)
- `streamdeck` user doesn't have access to `__BUDDY_USER__`'s cookie
- Even if socket is accessible, authentication fails without valid cookie

### 2. **PulseAudio Socket Permissions**
- Socket is in `/run/user/1000/` (owned by `__BUDDY_USER__`)
- Systemd service context may not provide access to user session sockets
- Socket permissions may not allow cross-user access

### 3. **PulseAudio Module Configuration**
- May need `module-native-protocol-unix` with `auth-anonymous=1`
- Virtual sink modules may not be loaded
- Cross-user access may require explicit configuration

### 4. **Systemd Service Environment**
- Systemd services run in isolated environment
- User session PulseAudio socket may not be accessible
- Environment variables may not be set correctly

### 5. **ALSA Direct Access Alternative**
- Could bypass PulseAudio entirely
- Requires `streamdeck` user in `audio` group
- Less flexible but simpler solution

## Hypothesis

**Primary Hypothesis**: The `streamdeck` user cannot authenticate to PulseAudio because:
1. PulseAudio cookie (`~/.config/pulse/cookie`) is not accessible to `streamdeck` user
2. PulseAudio socket authentication requires cookie validation
3. Systemd service context doesn't provide user session PulseAudio access

**Expected Behavior**: If we grant `streamdeck` user access to PulseAudio cookie, it should be able to connect and capture audio.

## Experiment Design

**Script**: `experiment-audio-access.sh`

**Tests**:
1. **Baseline**: Verify current PulseAudio state (socket, cookie, permissions)
2. **Cookie Sharing**: Copy PulseAudio cookie to `streamdeck` user and test access
3. **Module Configuration**: Check PulseAudio modules for cross-user access
4. **ALSA Access**: Test if `streamdeck` user can access ALSA directly
5. **Sunshine Integration**: Verify if Sunshine can capture audio after fixes

**Expected Outcomes**:
- **Option A (Cookie Sharing)**: If successful, update systemd service to use shared cookie
- **Option B (Module Config)**: Configure PulseAudio for anonymous/trusted connections
- **Option C (Virtual Sink)**: Create virtual sink accessible to both users
- **Option D (ALSA)**: Add `streamdeck` to `audio` group and configure Sunshine for ALSA

## Next Steps

1. **Run experiment**: `sudo ./experiment-audio-access.sh`
2. **Analyze results**: Determine which solution works
3. **Implement fix**: Update systemd service and/or PulseAudio configuration
4. **Verify**: Test audio capture in Sunshine stream
5. **Document**: Update `AUDIO_SETUP.md` with solution

## Related Files
- `AUDIO_SETUP.md` - Existing audio setup documentation
- `AUDIO_DIAGNOSIS.md` - Detailed diagnosis
- `experiment-audio-access.sh` - Experiment script
- `/tmp/streamdeck-test-20260213-162325/` - Collected logs
