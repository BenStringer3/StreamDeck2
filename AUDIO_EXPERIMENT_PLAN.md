# Audio Experiment Plan - Updated Hypothesis

## Problem Statement
No audio when streaming Horizon Forbidden West to Steam Deck. Previous cookie-sharing approach failed.

## Updated Root Cause Hypothesis

### Previous Attempt (Failed)
- **Approach**: Share PulseAudio cookie with `streamdeck` user
- **Result**: Still getting "Access denied" error
- **Conclusion**: Cookie sharing alone is insufficient

### New Understanding
1. **System uses PipeWire**, not PulseAudio directly
   - PipeWire provides PulseAudio compatibility layer
   - PipeWire may use stricter authentication mechanisms
   - PipeWire checks UID/GID in addition to cookie

2. **Systemd service context**
   - Services run in isolated environment
   - May not have access to user session sockets
   - Environment variables may not be properly inherited

3. **Alternative approaches available**
   - ALSA direct access (bypass PulseAudio/PipeWire)
   - PipeWire configuration for cross-user access
   - Virtual sink with proper routing

## Experiment Design

**Script**: `experiment-audio-pipewire.sh`

### Test Cases

1. **Audio System Identification**
   - Verify PipeWire vs PulseAudio
   - Check socket locations and permissions

2. **Cookie-Based Access (Baseline)**
   - Test if cookie sharing works (expected to fail)
   - Capture exact error message

3. **PipeWire Socket Access**
   - Test direct PipeWire socket access
   - Check if PipeWire has different authentication

4. **Virtual Sink Creation**
   - Create null sink for streaming
   - Test if virtual sink is accessible

5. **ALSA Direct Access**
   - Check if `streamdeck` is in `audio` group
   - Test ALSA device access
   - Determine if ALSA bypass is viable

6. **Sunshine Configuration**
   - Check current Sunshine audio backend
   - Determine if ALSA backend can be configured

7. **PipeWire Security**
   - Check PipeWire security/permission settings
   - Look for policy configuration options

## Expected Outcomes

### Scenario A: ALSA Access Works
- Add `streamdeck` to `audio` group
- Configure Sunshine to use ALSA backend
- **Pros**: Simple, bypasses PulseAudio/PipeWire
- **Cons**: Less flexible

### Scenario B: PipeWire Configuration Needed
- Configure PipeWire for cross-user access
- May require policy changes
- **Pros**: Flexible, modern approach
- **Cons**: Complex configuration

### Scenario C: Virtual Sink Works
- Create virtual sink accessible to both users
- Route game audio to virtual sink
- Capture from virtual sink
- **Pros**: Isolated, flexible
- **Cons**: Requires routing setup

## Next Steps

1. **Run experiment**: `sudo ./experiment-audio-pipewire.sh`
2. **Analyze results**: Determine which approach is viable
3. **Implement solution**: Based on experiment results
4. **Test**: Verify audio capture in Sunshine stream

## Files

- `experiment-audio-pipewire.sh` - Comprehensive experiment script
- `AUDIO_RCA_UPDATE.md` - Updated root cause analysis
- `AUDIO_EXPERIMENT_PLAN.md` - This file
