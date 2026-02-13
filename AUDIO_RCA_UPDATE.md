# Audio Issue - Updated Root Cause Analysis

## Previous Hypothesis (Failed)

**Hypothesis**: Cookie sharing would allow `streamdeck` user to access PulseAudio
**Result**: FAILED - Cookie sharing did not work

## New Evidence

1. **System is using PipeWire**, not PulseAudio directly
   - `pactl info` shows: "Server Name: PulseAudio (on PipeWire 1.4.9)"
   - PipeWire provides PulseAudio compatibility layer
   - PipeWire uses different authentication mechanisms

2. **Cookie sharing failed**
   - Copied cookie to streamdeck user
   - Set PULSE_RUNTIME_PATH and PULSE_COOKIE environment variables
   - Still getting "Access denied" error

3. **PipeWire sockets exist**
   - `/run/user/1000/pipewire-0` (main socket)
   - `/run/user/1000/pipewire-0-manager` (manager socket)
   - Both have `srw-rw-rw-` permissions but may have stricter authentication

## Updated Hypothesis

**Primary Hypothesis**: PipeWire uses stricter authentication than PulseAudio:
1. PipeWire checks UID/GID in addition to cookie
2. PipeWire may use different authentication mechanisms
3. Cross-user access requires explicit PipeWire configuration
4. Cookie-based authentication may not work with PipeWire

**Alternative Hypothesis**: Systemd service context prevents access:
1. Systemd services run in isolated environment
2. User session sockets may not be accessible from systemd context
3. Environment variables may not be properly inherited

**Alternative Hypothesis**: ALSA direct access is needed:
1. Bypass PulseAudio/PipeWire entirely
2. Requires `streamdeck` user in `audio` group
3. Configure Sunshine to use ALSA backend directly

## New Experiment Design

See `experiment-audio-pipewire.sh` for comprehensive testing:

1. **Test 1**: Identify audio system (PipeWire vs PulseAudio)
2. **Test 2**: Cookie-based access (baseline - known to fail)
3. **Test 3**: PipeWire socket access directly
4. **Test 4**: Create virtual sink for streaming
5. **Test 5**: ALSA direct access (requires audio group)
6. **Test 6**: Check Sunshine configuration for audio backend
7. **Test 7**: Check PipeWire security/permissions

## Potential Solutions

### Solution A: ALSA Direct Access (Simplest)
- Add `streamdeck` to `audio` group
- Configure Sunshine to use ALSA backend
- Bypass PulseAudio/PipeWire entirely
- **Pros**: Simple, no complex configuration
- **Cons**: Less flexible, may have device conflicts

### Solution B: PipeWire Configuration
- Configure PipeWire for cross-user access
- May require PipeWire policy configuration
- **Pros**: Flexible, modern approach
- **Cons**: Complex, requires PipeWire expertise

### Solution C: Virtual Sink + Routing
- Create virtual sink accessible to both users
- Route game audio to virtual sink
- Capture from virtual sink
- **Pros**: Isolated, flexible
- **Cons**: Requires audio routing setup

### Solution D: Systemd User Service
- Run Sunshine as user service instead of system service
- Would have access to user session PulseAudio
- **Pros**: Natural access to user session
- **Cons**: May conflict with current setup

## Next Steps

1. Run `experiment-audio-pipewire.sh` to gather data
2. Analyze results to determine which solution is viable
3. Implement chosen solution
4. Test audio capture in Sunshine stream
