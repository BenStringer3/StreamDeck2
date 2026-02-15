# MoonDeck host setup — pinned facts

Reference notes for the MoonDeck-first workflow. Sources: [MoonDeck Buddy Wiki](https://github.com/FrogTheFrog/moondeck-buddy/wiki), [Sunshine setup](https://github.com/FrogTheFrog/moondeck-buddy/wiki/Sunshine-setup), [Buddy installation](https://github.com/FrogTheFrog/moondeck-buddy/wiki/Buddy-installation-guide), [Buddy configuration](https://github.com/FrogTheFrog/moondeck-buddy/wiki/Buddy-configuration).

## Sunshine app: MoonDeckStream

- **App name:** `MoonDeckStream` (required).
- **Command:** Path to the MoonDeckStream executable. Prefer a stable wrapper, e.g. `/usr/local/bin/MoonDeckStream`. With AppImage: `path/to/MoonDeckBuddy.AppImage --exec MoonDeckStream`.
- **Continue streaming:** Must be **disabled** for MoonDeckStream. The Buddy wiki states: *"Continue streaming... - just disable the checkbox."* ([Sunshine setup](https://github.com/FrogTheFrog/moondeck-buddy/wiki/Sunshine-setup), [G-Sync note](https://github.com/FrogTheFrog/moondeck-buddy/wiki/Sunshine-setup)). In Sunshine’s app schema this is the **`wait-all`** boolean; set `"wait-all": false` so the stream does not continue after the helper exits.

## Arch install

- **Preferred:** AUR package [moondeckbuddy-appimage](https://aur.archlinux.org/packages/moondeckbuddy-appimage). Install with your AUR helper (e.g. `yay -S moondeckbuddy-appimage`). After install, `MoonDeckBuddy` and `MoonDeckStream` are on PATH.
- **Fallback:** Download the latest [AppImage](https://github.com/FrogTheFrog/moondeck-buddy/releases), place at a stable path (e.g. `/opt/moondeckbuddy/MoonDeckBuddy.AppImage`), `chmod +x`, and create wrappers in `/usr/local/bin` that run the AppImage with `--exec MoonDeckBuddy` or `--exec MoonDeckStream`.
- The AppImage embeds both binaries; invoke with `--exec <binary>` or use symlinks named `MoonDeckBuddy` / `MoonDeckStream` that point to the AppImage.

## Autostart (Linux)

- Enabling autostart creates two **systemd user** services:
  - `moondeckbuddy.service` — headless mode (stays running without a display).
  - `moondeckbuddy-gui-session.service` — attaches to `xdg-desktop-autostart.target`, runs Buddy in GUI when a DE session is present; when the session ends, Buddy is restarted in headless mode.
- **First run:** You may need a reboot, or start the units manually: `systemctl --user start moondeckbuddy && systemctl --user start moondeckbuddy-gui-session`. Install scripts should use `enable --now` so services start without a reboot when possible.
- Autostart can be toggled from the tray (right-click → autostart). For automation, prefer installing/enabling the user units explicitly rather than relying on the tray.

## Logs and config

- **Buddy logs:** Under `/tmp`, prefixed `moondeck...` (e.g. `/tmp/moondeckbuddy.log`). ([Buddy wiki](https://github.com/FrogTheFrog/moondeck-buddy/wiki) — logs live in `/tmp`.)
- **Buddy config:** `$XDG_CONFIG_HOME/moondeckbuddy/settings.json` or `~/.config/moondeckbuddy/settings.json`. Restart Buddy after editing.
- **Port:** Default port **59999**. Buddy’s HTTP server listens on this port; log lines indicate “Server started listening” (or similar).
- **Headless:** Set `NO_GUI=1` (or `NO_GUI=true`) so Buddy runs headless and does not depend on a compositor/display (avoids Qt terminating when display is gone). See [Buddy configuration — NO_GUI](https://github.com/FrogTheFrog/moondeck-buddy/wiki/Buddy-configuration#no_gui).
