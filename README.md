# Stream Deck → Moonlight → Sunshine on Linux

Automated setup for reliable game streaming from a Linux PC to a Steam Deck using Sunshine (server) and Moonlight (client).

## Quickstart

```bash
./test-full-cycle.sh
```

This will:
1. Install dependencies and configure services
2. Run health checks
3. Prompt you to launch an app from Moonlight on Steam Deck
4. Collect diagnostic logs
5. Print a summary and copy it to clipboard

## Architecture

This setup uses **Option B**: a dedicated Xorg display server session (`:99`) isolated from your normal Hyprland desktop. This ensures:

- **Concurrent use**: Your desktop remains usable while streaming
- **Reliable capture**: Sunshine uses X11 capture backend on the isolated display
- **Headless-friendly**: Works without physical monitors via EDID override

## Components

- `install.sh` - Idempotent setup script
- `collect-logs.sh` - Diagnostic log collection
- `test-full-cycle.sh` - End-to-end test with summary

## Troubleshooting

### Health Checks Fail

Run `./collect-logs.sh` to gather diagnostics. Common issues:

1. **Xorg not starting**: Check NVIDIA driver and EDID configuration
2. **Sunshine can't see display**: Verify `DISPLAY=:99` is set correctly
3. **Encoder init fails**: Check NVENC availability with `nvidia-smi`

### Moonlight Connection Issues

- Ensure Sunshine is running: `systemctl status streamdeck-sunshine`
- Check firewall rules for Sunshine ports (default 47989-47998)
- Verify pairing PIN matches

## Research Sources

- [Sunshine Getting Started](https://docs.lizardbyte.dev/projects/sunshine/latest/md_docs_2getting__started.html)
- [Sunshine Configuration](https://docs.lizardbyte.dev/projects/sunshine/master/md_docs_2configuration.html)
- [Official Headless Sunshine Setup Guide](https://app.lizardbyte.dev/2023-09-14-remote-ssh-headless-sunshine-setup/?lng=en-US)
