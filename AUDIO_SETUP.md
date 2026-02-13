# Audio Setup for Stream Deck

## Current Status
✅ Video streaming: **Working** (NVENC H.264/HEVC encoding)
⚠️ Audio streaming: **Not configured** (PulseAudio access denied)

## The Issue
```
Error: Couldn't connect to pulseaudio: Access denied
Error: Unable to initialize audio capture. The stream will not have audio.
```

The `streamdeck` user cannot access your user's PulseAudio session because:
1. PulseAudio runs per-user with socket-based authentication
2. The `streamdeck` user has no access to your user's audio devices
3. Audio capture requires either shared PulseAudio access or a separate audio server

## Solutions

### Option A: No Audio (Current Setup)
**Pros**: Simple, secure, no configuration needed
**Cons**: Silent streaming
**Use case**: If you only need video or will use Discord/voice chat separately

### Option B: Virtual Audio Sink (Recommended)
Set up a virtual PulseAudio sink that both users can access:

1. Create a virtual sink in your main user session
2. Configure PulseAudio to allow the `streamdeck` user to connect
3. Route game audio to the virtual sink
4. Sunshine captures from the virtual sink

**Pros**: Secure, flexible, doesn't affect your local audio
**Cons**: Requires PulseAudio configuration

### Option C: Add streamdeck to audio group
Add the `streamdeck` user to the `audio` group for direct ALSA access:

```bash
sudo usermod -aG audio streamdeck
```

Then configure Sunshine to use ALSA instead of PulseAudio.

**Pros**: Simple
**Cons**: Less flexible than PulseAudio, may have device conflicts

### Option D: PipeWire (Modern Alternative)
If you're using PipeWire instead of PulseAudio:

1. Configure PipeWire to allow the `streamdeck` user access
2. Use PipeWire's virtual devices for routing

**Pros**: Modern, better performance, more flexible
**Cons**: Requires PipeWire setup

## Recommendation

**For now**: Leave audio disabled. The video streaming is working perfectly.

**If you need audio later**: Implement Option B (virtual sink) as it provides the best isolation and flexibility without security concerns.

## Implementation Status
- [ ] Audio configuration (optional - implement only if needed)

## Notes
- Audio streaming is **optional** for game streaming
- Many users prefer using Discord or other voice chat instead
- The current setup prioritizes video quality and stability
- Audio can be added later without affecting the existing video setup
