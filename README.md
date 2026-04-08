# Stream your Linux PC to a Steam Deck (Moonlight + Sunshine)

This repo is a **set of install scripts** that turn a **Linux gaming PC with an NVIDIA GPU** into a **headless-friendly Moonlight host**: you keep using your normal desktop, while a **separate, invisible X11 session** captures **1280×800** video for the Deck. It is built around **Sunshine** on the PC, **Moonlight** on the Deck, and the **MoonDeck** plugin so you browse your **Steam library on the Deck**; games run and stream from the host.

**Philosophy:** as close to **clone, run one installer, pair Moonlight, play** as Linux allows — with **health checks**, **log collection**, and **[troubleshooting](docs/troubleshooting.md)** when something is wrong.

## What you need

| | |
|--|--|
| **Host** | Linux (Arch is tested; others supported — see [docs/installing.md](docs/installing.md)). **NVIDIA GPU + driver** (NVENC). |
| **Steam Deck** | **Moonlight** and the **[MoonDeck](https://github.com/FrogTheFrog/moondeck)** Decky plugin. |
| **On the host** | **MoonDeck Buddy** (the installer wires autostart and settings). The Deck plugin talks to Buddy to launch games. |

## Install

```bash
sudo ./install.sh
```

By default the user who runs `sudo` is treated as the account that owns **Steam and Buddy**. To use another account:

```bash
BUDDY_USER=yourlogin sudo ./install.sh
```

Full options (distros, `STREAM_USER`, display number, skipping deps): **[docs/installing.md](docs/installing.md)**.

## After install

1. Open **Moonlight** on the Deck, add the PC, complete pairing if prompted.
2. Start a stream using **MoonDeckStream** (or **Desktop** / **Steam Big Picture** for debugging — they appear in Sunshine’s app list).
3. Use **MoonDeck** on the Deck to pick games; the host runs them in the streaming session.

If audio is silent or wrong, see **[docs/audio-pipeline.md](docs/audio-pipeline.md)**.

## Full validation (optional)

Maintainers and anyone who wants a **guided end-to-end check** (re-runs install, health gates, manual Moonlight step, log bundle):

```bash
./test-full-cycle.sh
```

## Documentation

| Doc | Purpose |
|-----|--------|
| [docs/architecture.md](docs/architecture.md) | How Xorg, Sunshine, Buddy, audio, and input isolation fit together (diagrams + repo map) |
| [docs/installing.md](docs/installing.md) | Distros, environment variables, GPU hints |
| [docs/audio-pipeline.md](docs/audio-pipeline.md) | PipeWire TCP bridge and capture path |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Common failures and fixes |
| [AGENTS.md](AGENTS.md) | Contributor expectations (logging, idempotent installs, etc.) |

## Contributing

Follow **[AGENTS.md](AGENTS.md)**. When you change behavior or failure modes, keep **[docs/troubleshooting.md](docs/troubleshooting.md)** and **`collect-logs.sh`** in sync with what operators need to diagnose issues.
