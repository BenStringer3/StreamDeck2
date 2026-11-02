# Architecture

Technical reference for how this repository wires **Sunshine**, **Moonlight**, **MoonDeck**, and **MoonDeck Buddy** on the host. For install options and distros, see [installing.md](installing.md). For audio specifics, see [audio-pipeline.md](audio-pipeline.md).

## Overview

The host runs a **dedicated Xorg session** on a separate display number (default **`STREAM_DISPLAY=:99`**, configurable via `install.sh`). That session uses a **dummy video driver** and a fixed **1280×800** mode (Steam Deck native) so capture works **headless** and **without conflicting with your normal desktop** (no DRM master fight with the compositor’s GPU session).

- **Sunshine** runs as **`STREAM_USER`** (default `streamdeck`) under `streamdeck-sunshine.service`, captures video from that X session, and encodes with **NVENC** (NVIDIA GPU required today — see `install.sh` NVIDIA detection).
- **MoonDeck Buddy** and **Steam** run as **`BUDDY_USER`** (default: the user who ran `sudo ./install.sh`, overridable with `BUDDY_USER=…`). Buddy is started via **systemd user** units: `install.sh` writes a **`moondeckbuddy.service.d` override** with **`NO_GUI=1`** and **`TMPDIR=/tmp`** (Buddy must not depend on the desktop compositor for the headless stream path; `TMPDIR` aligns shared-memory IPC with MoonDeckStream). It also runs **`systemctl --user enable --now moondeckbuddy-gui-session.service`** when configuring Buddy (upstream unit shipped with Buddy; harmless if missing).
- **MoonDeckStream** is the Sunshine “app” you connect to from Moonlight. Sunshine still reads application definitions from **`apps.json`** under the stream user’s config dir (see `SUNSHINE_CONFIG_DIR` in `streamdeck-sunshine.service`). `install.sh` renders **`sunshine/apps.json.template`** → **`~STREAM_USER/.config/sunshine/apps.json`** so Sunshine starts MoonDeckStream with `sudo -u BUDDY_USER` and the correct `DISPLAY`, `XDG_RUNTIME_DIR`, `DBUS_SESSION_BUS_ADDRESS`, and `TMPDIR=/tmp` (Buddy ↔ MoonDeckStream shared-memory key path). **`/etc/sudoers.d/streamdeck-steam`** grants narrowly scoped `NOPASSWD` for that pattern.

If the distribution ships a system **`sunshine.service`**, **`install.sh` stops and disables it** so only **`streamdeck-sunshine.service`** owns the streaming ports.

## Audio

Sunshine (`STREAM_USER`) cannot open the Buddy user’s Pulse/PipeWire socket under `/run/user/<buddy_uid>/` (permissions). **`install.sh`** deploys a PipeWire-Pulse drop-in (`pipewire/10-tcp-localhost.conf` → `~/.config/pipewire/pipewire-pulse.conf.d/`) so **`pipewire-pulse` also listens on `tcp:127.0.0.1:4713`**. **`streamdeck-sunshine.service`** sets `PULSE_SERVER=tcp:127.0.0.1:4713`. Details and validation: [audio-pipeline.md](audio-pipeline.md).

## Input isolation

Moonlight input is forwarded through **Sunshine virtual HID** devices. **`udev/85-streamdeck-sunshine-input-isolation.rules`** (rendered from the template under `install.sh`) sets **`TAG+="seat"`**, **`GROUP`/`MODE`** for **`STREAM_GROUP`**, and **`ENV{LIBINPUT_IGNORE_DEVICE}=1`** on those nodes so **desktop compositors using libinput** ignore them, while the streaming Xorg stack uses **`xf86-input-evdev`**, which opens devices by node permissions and does not consult `LIBINPUT_IGNORE_DEVICE`. The Xorg config (**`xorg/99-streamdeck.conf`**) restricts which devices the `:99` server uses. Do **not** set `ID_SEAT` on parent devices in custom rules — see [troubleshooting.md](troubleshooting.md).

## Per-game apps (stream-scoped lifecycle)

Optional apps generated from `~BUDDY_USER/.config/streamdeck/games.json` (setup: [installing.md](installing.md#per-game-sunshine-apps)). Each one ties a game's whole lifetime to one stream, the way a context manager ties a resource to a block. Moonlight's Wake-on-LAN and Sunshine's app start are the setup, the game process is the body, and Sunshine's quit handling is the teardown:

```mermaid
sequenceDiagram
    participant Deck as Moonlight (client)
    participant Sun as Sunshine (STREAM_USER)
    participant Inh as systemd-inhibit
    participant Game as game command (BUDDY_USER)
    Deck->>Sun: Wake-on-LAN, then stream "inFAMOUS"
    Sun->>Inh: run app cmd
    Inh->>Inh: take sleep lock (mode=block)
    Inh->>Game: sudo -u BUDDY_USER command
    Note over Game: game runs on the stream display
    Deck->>Sun: quit app (end of stream)
    Sun->>Game: ask to exit, wait exit-timeout, then terminate
    Game-->>Inh: exits
    Inh-->>Sun: exits, sleep lock released
```

- **Sleep:** the blocking inhibitor exists exactly as long as the game process. A host suspend policy that honours `block` inhibitors (e.g. `systemd-inhibit --list` checks) cannot suspend mid-stream, and nothing needs to keep the host awake afterwards. A polkit rule lets `STREAM_USER` take the lock.
- **Privilege:** `STREAM_USER` may run only the exact listed commands as `BUDDY_USER` (generated sudoers rule).
- **Not covered:** a client that disconnects without quitting leaves the app running (and the host awake) until a client reconnects and quits it. Launchers that daemonise (e.g. `steam steam://rungameid/...`) escape Sunshine's process tracking, so they can't be per-game apps.

## System diagram

```mermaid
flowchart TB
    subgraph host["Linux host"]
        subgraph supervision["Supervision"]
            direction LR
            subgraph systemd_system["systemd (system)"]
                direction LR
                xorg_svc["streamdeck-xorg.service"]
                sunshine_svc["streamdeck-sunshine.service"]
            end
            subgraph systemd_user["systemd user · BUDDY_USER"]
                direction LR
                buddy_svc["moondeckbuddy.service<br>(NO_GUI=1, TMPDIR=/tmp)"]
                buddy_gui_svc["moondeckbuddy-gui-session.service"]
            end
        end

        subgraph data["Runtime"]
            direction LR
            subgraph config["Config · permissions"]
                direction TB
                apps["apps.json<br>(Desktop, Steam BP, MoonDeckStream)"]
                xorg_conf["/etc/X11/xorg.conf.d/99-streamdeck.conf"]
                udev_rules["udev rules<br>(input isolation + seat tag)"]
                sudoers["/etc/sudoers.d/streamdeck-steam"]
            end
            Moonlight["Moonlight<br>(Steam Deck)"]
            subgraph streamdeck["User STREAM_USER · display"]
                direction TB
                Sunshine["Sunshine<br>(X11 capture, NVENC)"]
                Xorg["Xorg STREAM_DISPLAY<br>(dummy 1280×800)"]
                Openbox["Openbox"]
            end
            subgraph buddy_user["User BUDDY_USER"]
                direction TB
                PipeWire["PipeWire-Pulse<br>(tcp 127.0.0.1:4713)"]
                MDS["MoonDeckStream<br>(sudo from Sunshine)"]
                Buddy["MoonDeck Buddy<br>(HTTP :59999)"]
            end
        end
    end

    sunshine_svc -.->|"After=, Requires="| xorg_svc
    xorg_svc --> Xorg
    xorg_svc --> Openbox
    sunshine_svc --> Sunshine
    buddy_svc --> Buddy
    buddy_gui_svc --> Buddy

    apps -.-> Sunshine
    xorg_conf -.-> Xorg
    udev_rules -.-> Xorg
    sudoers -.->|"NOPASSWD"| MDS

    Moonlight <-->|"UDP/TCP"| Sunshine
    Sunshine -->|"X11 video"| Xorg
    Xorg --> Openbox
    Sunshine -->|"PULSE_SERVER"| PipeWire
    Sunshine -->|"sudo … MoonDeckStream"| MDS
    MDS -->|"HTTP / Qt shm"| Buddy
```

## Stream and game-launch sequence

```mermaid
sequenceDiagram
    participant User as User (Steam Deck)
    participant Moonlight as Moonlight
    participant MoonDeck as MoonDeck (plugin)
    participant Sunshine as Sunshine
    participant MDS as MoonDeckStream
    participant Buddy as MoonDeck Buddy
    participant Steam as Steam
    participant Xorg as Xorg streaming display

    Note over User,Xorg: Start stream
    User->>Moonlight: Select host, launch MoonDeckStream
    Moonlight->>Sunshine: Request stream (launch app)
    Sunshine->>Sunshine: apps.json: sudo -u BUDDY_USER … MoonDeckStream
    Sunshine->>MDS: exec as BUDDY_USER (DISPLAY, TMPDIR, dbus, …)
    MDS->>Buddy: Connect (HTTP :59999 / shared-memory IPC)
    Buddy-->>MDS: Ready
    Sunshine->>Xorg: X11 capture
    Sunshine->>Moonlight: Video/audio (NVENC)
    Moonlight->>User: Display stream

    Note over User,Xorg: User picks game in MoonDeck
    User->>MoonDeck: Select game (Steam library)
    MoonDeck->>Buddy: Launch game (HTTP host:59999)
    Buddy->>Steam: steam-headless steam://rungameid/… (on streaming DISPLAY)
    Steam->>Xorg: Game renders on streaming display
    Sunshine->>Xorg: Capture
    Sunshine->>Moonlight: Stream
    Moonlight->>User: Display game
```

## Repository layout

| Path | Role |
|------|------|
| `install.sh` | Idempotent setup: deps, Buddy, Xorg/Sunshine units, udev, `sunshine.conf`, `apps.json`, sudoers, per-game apps (`games.json`); health checks; runs `collect-logs.sh` on success and failure |
| `collect-logs.sh` | Diagnostics: journald, Sunshine/Xorg logs, GPU, udev, `apps.json`, Buddy journal, Steam client logs, input-device udev tags |
| `test-full-cycle.sh` | Runs `install.sh`, health gates, manual Moonlight step, `collect-logs.sh`, `scripts/check-input-pipeline.sh`; Ctrl+C collects logs |
| `scripts/lib.sh` | Shared logging, health checks (`check_*`), helpers |
| `scripts/load-install-config.sh` | Loads `/etc/streamdeck/install.conf`; used by collect-logs, test cycle, check-input-pipeline |
| `scripts/steam-headless-wrapper.sh` | Installed as `/usr/local/bin/steam-headless` for Buddy’s `steam_exec_override` on the streaming display |
| `scripts/moondeckstream-wrapper.sh` | Installed as `/usr/local/bin/MoonDeckStream` (real binary + singleton / lifecycle) |
| `scripts/check-input-pipeline.sh` | Strict PASS/FAIL checks on Sunshine virtual input and udev tags |
| `scripts/experiment-*.sh` | Optional one-off experiments; not required for install |
| `systemd/*.template` | Rendered to `/etc/systemd/system/streamdeck-{xorg,sunshine}.service` |
| `sunshine/*.template` | `sunshine.conf` and `apps.json` for `STREAM_USER` |
| `xorg/99-streamdeck.conf.template` | Dummy driver + 1280×800 modeline + evdev input class |
| `pipewire/10-tcp-localhost.conf` | Copied into Buddy user’s `pipewire-pulse.conf.d` for the audio TCP bridge |
| `udev/*.rules.template`, `udev/*.rules` | Input isolation for Sunshine passthrough; static rules (e.g. TTY) for headless Xorg |
| `sudoers.d/streamdeck-steam.template` | NOPASSWD for stream user to run Buddy-scoped launch commands |
| `polkit/50-streamdeck-inhibit.rules.template` | Lets the stream user hold a blocking sleep inhibitor for per-game apps (installed only with `games.json`) |

## References

- [Sunshine Getting Started](https://docs.lizardbyte.dev/projects/sunshine/latest/md_docs_2getting__started.html)
- [Sunshine Configuration](https://docs.lizardbyte.dev/projects/sunshine/master/md_docs_2configuration.html)
- [MoonDeck Buddy Wiki](https://github.com/FrogTheFrog/moondeck-buddy/wiki)
- [Headless Sunshine setup (LizardByte)](https://app.lizardbyte.dev/2023-09-14-remote-ssh-headless-sunshine-setup/?lng=en-US)
