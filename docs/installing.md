# Installation and configuration

## Supported distributions

- **Arch Linux** — Tested. Install uses `pacman` and optionally `yay` for AUR (Sunshine, moondeckbuddy-appimage).
- **Debian / Ubuntu** — Dependencies installed via `apt`; Sunshine and MoonDeck Buddy must be installed separately (PPA, AppImage, or manual). See [Sunshine docs](https://docs.lizardbyte.dev/projects/sunshine/) and [MoonDeck Buddy](https://github.com/FrogTheFrog/moondeck-buddy).
- **Fedora** — Dependencies via `dnf`; Sunshine/Buddy as on Debian (manual or AppImage).
- **Other** — Set `SKIP_DEPS=1` and install all dependencies manually, then run `sudo ./install.sh`.

## Install entry point

```bash
sudo ./install.sh
```

The user who runs `sudo ./install.sh` is used as **BUDDY_USER** by default (the desktop user under which MoonDeck Buddy and Steam run). To use a different user:

```bash
BUDDY_USER=myuser sudo ./install.sh
```

## Environment variables (install)

| Variable      | Default              | Description |
|---------------|----------------------|-------------|
| `BUDDY_USER`  | `$SUDO_USER` | Desktop user for MoonDeck Buddy and Steam. Defaults to the user who ran `sudo ./install.sh` (`$SUDO_USER` set by sudo). If you run the installer as root without `sudo` (e.g. `su -`), set `BUDDY_USER` explicitly — it is not guessed. |
| `STREAM_USER` | `streamdeck`         | System user that runs Sunshine and the isolated Xorg display. |
| `STREAM_DISPLAY` | `:99`             | X11 display number for the streaming session. |
| `SKIP_DEPS`   | (unset)              | Set to `1` to skip package and AUR installation (use when deps are installed manually). |
| `EDID_PATH`   | `/etc/X11/edid/steamdeck-edid.bin` | Path to EDID file for headless display (optional). |
| `ADAPTER_NAME`| (see below)          | GPU PCI id for Sunshine NVENC (optional; see **GPU / adapter_name**). |

## Install config file

After a successful install, `/etc/streamdeck/install.conf` is created (mode 644) with:

- `STREAM_USER`
- `BUDDY_USER`
- `STREAM_DISPLAY`
- `STREAM_GROUP`

Other scripts (`collect-logs.sh`, `check-input-pipeline.sh`, `test-full-cycle.sh`) read this file so they use the same users and paths. You can override by setting the same variables in the environment.

## Per-distro dependency notes

### Arch Linux

- **Packages:** `xorg-server`, `xorg-xrandr`, `xf86-video-dummy`, `openbox`, `xterm`, `nvidia-utils`, `wl-clipboard`.
- **Sunshine:** AUR package `sunshine` (requires [yay](https://github.com/Jguer/yay) or another AUR helper).
- **MoonDeck Buddy:** AUR `moondeckbuddy-appimage` or AppImage fallback (install script downloads to `/opt/moondeckbuddy/` if needed).

### Debian / Ubuntu

- **Packages:** `xserver-xorg`, `xserver-xorg-video-dummy`, `openbox`, `xterm`, `nvidia-utils`, `wl-clipboard`. Install with `apt-get install -y ...`.
- **Sunshine:** Not in default repos. Use [LizardByte instructions](https://docs.lizardbyte.dev/projects/sunshine/) (e.g. PPA or AppImage). Ensure `sunshine` is on PATH before or after install.
- **MoonDeck Buddy:** AppImage from [releases](https://github.com/FrogTheFrog/moondeck-buddy/releases); place in `/opt/moondeckbuddy/MoonDeckBuddy.AppImage` or let the install script download it (when `curl` is available).

### Fedora

- **Packages:** Xorg, dummy driver, openbox, xterm, nvidia-utils, wl-clipboard. Package names may differ (e.g. `xorg-x11-server-Xorg`, `xorg-x11-server-Xorg-xorg-dummy`). See `dnf search` if install fails.
- **Sunshine / MoonDeck Buddy:** Install manually or via AppImage as on Debian.

## GPU and EDID (optional)

### adapter_name (Sunshine)

Sunshine’s config uses `adapter_name` to select the GPU for NVENC. The template ships with an example PCI id (e.g. `00000000:01:00.0`). To find your GPU:

```bash
nvidia-smi -q | grep "Bus Id"
# or
lspci | grep -i nvidia
```

Format is `BBBB:DD:F` (Bus:Device.Function in hex). Edit `/home/<STREAM_USER>/.config/sunshine/sunshine.conf` after install, or set `ADAPTER_NAME` and extend the install to substitute it (see `sunshine/sunshine.conf.template`).

### EDID (headless)

For headless hosts (no physical monitor), an EDID file can be used so the dummy X output reports a resolution. Default path: `/etc/X11/edid/steamdeck-edid.bin`. Override with:

```bash
EDID_PATH=/path/to/your.edid sudo ./install.sh
```

If the file is missing, Xorg may use `AllowEmptyInitialConfiguration`; behaviour depends on the Xorg/dummy driver version.
