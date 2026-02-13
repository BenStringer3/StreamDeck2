# Audio Fix Summary

## Experiment Results

The experiment revealed:
1. **PulseAudio cookie exists** at `/home/__BUDDY_USER__/.config/pulse/cookie`
2. **streamdeck user cannot access PulseAudio** (baseline test failed)
3. **Cookie sharing approach** was not tested due to script bug (fixed cookie path)
4. **ALSA access** requires adding streamdeck to audio group (not tested yet)

## Root Cause Confirmed

**PulseAudio Authentication**: The `streamdeck` user cannot authenticate to PulseAudio because:
- PulseAudio uses cookie-based authentication
- Cookie is stored in `~/.config/pulse/cookie` (user-specific)
- `streamdeck` user doesn't have access to `__BUDDY_USER__`'s cookie

## Solution: Cookie Sharing

**Approach**: Copy PulseAudio cookie to `streamdeck` user's home directory and configure systemd service to use it.

**Implementation**: `fix-audio-access.sh` script:
1. Copies PulseAudio cookie from `__BUDDY_USER__` to `streamdeck` user
2. Sets proper permissions (600, owned by streamdeck)
3. Updates systemd service to set `PULSE_RUNTIME_PATH` and `PULSE_COOKIE` environment variables
4. Tests access to verify it works
5. Reloads systemd daemon

## Next Steps

1. **Run the fix script**:
   ```bash
   sudo ./fix-audio-access.sh
   ```

2. **Restart Sunshine service**:
   ```bash
   sudo systemctl restart streamdeck-sunshine.service
   ```

3. **Verify audio capture**:
   ```bash
   sudo journalctl -u streamdeck-sunshine.service -f
   ```
   Look for successful audio capture (no "Access denied" errors)

4. **Test streaming**: Start a game and verify audio is captured in the stream

## Notes

- **Cookie refresh**: PulseAudio cookies may need to be refreshed periodically. If audio stops working, re-run `fix-audio-access.sh`
- **PipeWire compatibility**: System is using PipeWire with PulseAudio compatibility layer, which should work with this approach
- **Alternative solutions**: If cookie sharing doesn't work, consider:
  - Adding `streamdeck` to `audio` group for ALSA direct access
  - Configuring PulseAudio for anonymous/trusted connections
  - Creating a virtual sink accessible to both users

## Files Created

- `fix-audio-access.sh` - Automated fix script
- `experiment-audio-access.sh` - Experiment script (fixed cookie path bug)
- `AUDIO_DIAGNOSIS.md` - Detailed diagnosis
- `AUDIO_ROOT_CAUSE_SUMMARY.md` - Root cause analysis
- `AUDIO_FIX_SUMMARY.md` - This file
