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
| `ADAPTER_NAME`| (see below)          | GPU PCI id for Sunshine NVENC (optional; see **GPU / adapter_name**). |

## Install config file

After a successful install, `/etc/streamdeck/install.conf` is created (mode 644) with:

- `STREAM_USER`
- `BUDDY_USER`
- `STREAM_DISPLAY`
- `STREAM_GROUP`

Other scripts (`collect-logs.sh`, `check-input-pipeline.sh`, `test-full-cycle.sh`) read this file so they use the same users and paths. You can override by setting the same variables in the environment.

## Per-game Sunshine apps

A per-game app lets a Moonlight client start one game directly, e.g. from a Steam Deck library shortcut running `moonlight stream <host> "<name>"`. The game lives exactly as long as the stream:

- **Start:** Moonlight wakes the host (Wake-on-LAN to the paired host's MAC) and Sunshine runs the game's command as `BUDDY_USER` under `systemd-inhibit --what=sleep --mode=block`, so the host cannot suspend mid-stream.
- **Quit:** when the client quits the app (Moonlight's *Quit app after stream* setting, or quitting from the Moonlight menu), Sunshine asks the game to exit, waits `exit-timeout` (10 s), then terminates it. `systemd-inhibit` exits with the game and the sleep block is released.

List the games in **`~BUDDY_USER/.config/streamdeck/games.json`** (machine-local, not in the repo) and re-run `sudo ./install.sh`:

```json
[
  {"name": "inFAMOUS", "command": ["/home/ben/.local/bin/rpcs3-streamdeck", "/home/ben/Games/ps3/inFamous-BCES00220/PS3_GAME/USRDIR/EBOOT.BIN"]}
]
```

`command` is an argv list. The first element must be an executable absolute path, and no argument may contain whitespace or `, : = \ "`, because the command becomes both a sudoers rule and the Sunshine `cmd`. The command must stay in the foreground (no daemonising launcher), or Sunshine loses track of it. That rules out `steam steam://rungameid/...`: Steam hands the launch to its own process, so quitting the stream would not stop the game.

From the file, `install.sh` generates:

| Generated | Purpose |
|---|---|
| Entries appended to `~STREAM_USER/.config/sunshine/apps.json` | One app per game, with `exit-timeout` |
| `/etc/sudoers.d/streamdeck-games` | `STREAM_USER` may run exactly each listed command as `BUDDY_USER` |
| `/etc/polkit-1/rules.d/50-streamdeck-inhibit.rules` | `STREAM_USER` may take a blocking sleep inhibitor (logind denies this to processes outside a login session by default) |

Without the file, the sudoers and polkit rules are removed.

## Per-distro dependency notes

### Arch Linux

- **Packages:** `xorg-server`, `xorg-xrandr`, `xf86-video-dummy`, `openbox`, `xterm`, `nvidia-utils`, `wl-clipboard`, `jq`.
- **Sunshine:** AUR package `sunshine` (requires [yay](https://github.com/Jguer/yay) or another AUR helper).
- **MoonDeck Buddy:** AUR `moondeckbuddy-appimage` or AppImage fallback (install script downloads to `/opt/moondeckbuddy/` if needed).

### Debian / Ubuntu

- **Packages:** `xserver-xorg`, `xserver-xorg-video-dummy`, `openbox`, `xterm`, `nvidia-utils`, `wl-clipboard`, `jq`. Install with `apt-get install -y ...`.
- **Sunshine:** Not in default repos. Use [LizardByte instructions](https://docs.lizardbyte.dev/projects/sunshine/) (e.g. PPA or AppImage). Ensure `sunshine` is on PATH before or after install.
- **MoonDeck Buddy:** AppImage from [releases](https://github.com/FrogTheFrog/moondeck-buddy/releases); place in `/opt/moondeckbuddy/MoonDeckBuddy.AppImage` or let the install script download it (when `curl` is available).

### Fedora

- **Packages:** Xorg, dummy driver, openbox, xterm, nvidia-utils, wl-clipboard, jq. Package names may differ (e.g. `xorg-x11-server-Xorg`, `xorg-x11-server-Xorg-xorg-dummy`). See `dnf search` if install fails.
- **Sunshine / MoonDeck Buddy:** Install manually or via AppImage as on Debian.

## GPU (optional)

### adapter_name (Sunshine)

Sunshine’s config uses `adapter_name` to select the GPU for NVENC. The template ships with an example PCI id (e.g. `00000000:01:00.0`). To find your GPU:

```bash
nvidia-smi -q | grep "Bus Id"
# or
lspci | grep -i nvidia
```

Format is `BBBB:DD:F` (Bus:Device.Function in hex). `install.sh` substitutes `ADAPTER_NAME` into `sunshine/sunshine.conf.template` (default `00000000:01:00.0` if unset). To change after install, edit `/home/<STREAM_USER>/.config/sunshine/sunshine.conf` or re-run install with `ADAPTER_NAME=…`.

Headless video uses the dummy Xorg driver with an explicit 1280×800 modeline (`xorg/99-streamdeck.conf.template`); no physical monitor is required.
