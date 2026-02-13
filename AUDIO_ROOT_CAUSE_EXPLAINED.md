# Audio Root Cause - Why streamdeck Needs Access to __BUDDY_USER__'s PulseAudio

## The Problem Chain

1. **Steam runs as `__BUDDY_USER__` user** (uid 1000)
   - Command: `sudo -u __BUDDY_USER__ HOME=/home/__BUDDY_USER__ USER=__BUDDY_USER__ ... steam steam://rungameid/2420110`
   - This is configured in `sunshine/apps.json`

2. **Game audio goes to `__BUDDY_USER__`'s PulseAudio session**
   - Games run as `__BUDDY_USER__` user
   - Audio output goes to `__BUDDY_USER__`'s PulseAudio (uid 1000)
   - PulseAudio socket: `/run/user/1000/pulse/native`

3. **Sunshine runs as `streamdeck` user** (uid 1001)
   - Systemd service: `User=streamdeck`
   - Needs to capture audio from the game

4. **Cross-user access required**
   - `streamdeck` (uid 1001) needs to access `__BUDDY_USER__`'s PulseAudio (uid 1000)
   - PulseAudio tries to create secure directory: `/run/user/1000/pulse`
   - **Permission denied**: `streamdeck` cannot write to `__BUDDY_USER__`'s user directory

## Why Steam Runs as __BUDDY_USER__ User

Looking at the configuration:
- Steam library is in `/home/__BUDDY_USER__/.local/share/Steam`
- Games are installed in `__BUDDY_USER__`'s home directory
- Steam configuration is user-specific
- This is why Steam must run as `__BUDDY_USER__` user

## Solutions

### Option A: Run Steam as streamdeck User (Best Long-term)
**Pros**:
- Audio goes to `streamdeck`'s PulseAudio session
- Sunshine (also `streamdeck`) can access it directly
- No cross-user access needed
- Clean separation

**Cons**:
- Need to share Steam library between users
- Or install Steam/games for `streamdeck` user
- May require Steam library migration

**Implementation**:
1. Share Steam library: `ln -s /home/__BUDDY_USER__/.local/share/Steam /home/streamdeck/.local/share/Steam`
2. Update `apps.json` to run Steam as `streamdeck` user
3. Audio will go to `streamdeck`'s PulseAudio automatically

### Option B: Fix PulseAudio Cross-User Access (Current Attempt)
**Pros**:
- Keep Steam running as `__BUDDY_USER__` user
- No library migration needed

**Cons**:
- Complex PulseAudio configuration
- Security considerations
- Permission issues (current blocker)

### Option C: ALSA Direct Access (Current Workaround)
**Pros**:
- Bypasses PulseAudio entirely
- Simple (add to audio group)

**Cons**:
- Requires ALSA loopback module (not available)
- Limited to microphone without loopback
- Less flexible routing

### Option D: Virtual Sink + Routing (Hybrid)
**Pros**:
- Keep Steam as `__BUDDY_USER__` user
- Route audio to shared virtual sink
- Capture from virtual sink

**Cons**:
- Still requires PulseAudio access
- Complex routing setup

## Recommended Solution

**Option A: Run Steam as streamdeck user**

This is the cleanest solution because:
1. Audio naturally goes to `streamdeck`'s PulseAudio
2. Sunshine can access it directly (same user)
3. No cross-user permission issues
4. Better isolation (streaming session separate from desktop)

The only challenge is sharing Steam library, which can be done with symlinks or Steam's library sharing feature.

## Why PulseAudio Needs Write Access

When a client connects to PulseAudio, it tries to create a secure directory in `/run/user/1000/pulse/` for authentication tokens. This requires write access to that directory, which `streamdeck` user doesn't have.

Even with cookie sharing, PulseAudio still needs to create temporary files for the connection, which requires write access to the runtime directory.
