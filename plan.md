
# plan.md — Stream Deck → Moonlight → Sunshine on Linux

## 0) What this repo is (and is not)

This repository automates a reliable, repeatable setup for **game streaming from a Linux PC to a Steam Deck** using:

- **Sunshine** (server, running on the PC)
- **Moonlight** (client, running on the Steam Deck)

It is specifically designed for **“headless / virtual display” streaming** that does **not** require taking over the user’s main desktop session, and aims to support **concurrent local PC usage** while a Steam Deck session is running.

This repo is **not** a general Wayland compositor experiment. It is an operational, debuggable, idempotent streaming setup with strong health checks and log capture.

---

## 1) User goals (solution-independent)

### Primary goals
1. **Reliable launch**: Moonlight can start an app with no “503 / capture init failed” class of errors.
2. **Concurrent use (“containerization”)**: the local PC user can keep using their normal desktop session without input/focus fights against the stream session.
3. **Idempotent automation**: a single `install.sh` sets everything up reproducibly.
4. **Fast iteration on failures**:
   - `test-full-cycle.sh` runs install, validates health, prompts user to launch an app from Steam Deck, then collects logs, prints a high-signal summary, and copies it to clipboard via `wl-copy`.

### Secondary goals
- Minimal changes to the user’s day-to-day PC workflow.
- Clear separation of “streaming session” from “desktop session” for debugging and concurrency.
- Transparent health checks with actionable failure messages.

---

## 2) Environment facts (as provided)

- OS: Arch-based **__HOSTNAME__** (Wayland desktop in daily use).
- Daily compositor: **Hyprland** (user preference).
- GPU: **NVIDIA GeForce RTX 3090 Ti**.
- User already has an **EDID override on DP-3** at **Steam Deck resolution** (1280x800).
- User timezone: Europe/Berlin.
- Preference: brief + high-signal diagnostics, scripts over manual steps.

---

## 3) Option B: definition (architecture choice)

### Option B = “Dedicated streaming display server session, isolated from desktop”
Instead of running Sunshine inside a wlroots headless compositor session (Sway headless), Option B creates a **separate display server session** for streaming that:

- Has its **own display** (virtual / EDID-driven)
- Receives **its own input** (Sunshine virtual input devices routed to that session)
- Does **not** steal focus from the normal Hyprland desktop
- Can run even when no monitor is physically active (headless-friendly)

**Canonical implementation of Option B**:
- Run a **dedicated Xorg server** (headless/EDID-backed) on a separate display (e.g. `:99`) and VT if needed.
- Launch Sunshine in that Xorg session using Sunshine’s **X11 capture** method, bound to that X display.
- Keep Hyprland (normal desktop) unchanged.

Why this is justified:
- Sunshine docs explicitly reference headless setup on Linux and provide an official headless guide focused on **X11 + NVIDIA**.  
- Sunshine supports multiple capture backends (wlroots, kms, x11), and X11 is a supported backend.  
- NVIDIA provides documented Xorg options to start without a physical monitor and/or to fake a monitor via EDID.

---

## 4) Primary sources and research (must-read)

### Sunshine official documentation (primary)
- Sunshine “Getting Started” docs (official): mentions headless setup guide and configuration basics.  
  Source: Sunshine docs “Getting Started”. https://docs.lizardbyte.dev/projects/sunshine/latest/md_docs_2getting__started.html
- Sunshine configuration docs: capture backends include `wlr` (wlroots screencopy), `kms` (DRM/KMS, requires capability), and `x11` (XCB, slower).  
  Source: Sunshine configuration docs (master). https://docs.lizardbyte.dev/projects/sunshine/master/md_docs_2configuration.html :contentReference[oaicite:0]{index=0}
- Sunshine docs (v0.23) note `kms` requires `cap_sys_admin`.  
  Source: Sunshine advanced usage docs. https://docs.lizardbyte.dev/projects/sunshine/v0.23.0/about/advanced_usage.html :contentReference[oaicite:1]{index=1}

### Sunshine official headless guide (primary)
- “Remote SSH Headless Sunshine Setup” (official LizardByte blog/guide): describes starting X server + Sunshine without autologin or dummy plugs, using NVIDIA configuration.  
  Source: https://app.lizardbyte.dev/2023-09-14-remote-ssh-headless-sunshine-setup/?lng=en-US :contentReference[oaicite:2]{index=2}

### NVIDIA Xorg headless / EDID options (primary-ish, vendor-backed)
- NVIDIA dev forum confirms using `ConnectedMonitor` + `CustomEDID` to fake a display headlessly.  
  Source: NVIDIA Developer Forums thread. :contentReference[oaicite:3]{index=3}
- Common/recognized Xorg option: `AllowEmptyInitialConfiguration`.  
  Source: Unix.SE answer (widely referenced pattern). :contentReference[oaicite:4]{index=4}
- A modern real-world writeup using those options for headless NVIDIA streaming.  
  Source: Mark Hamilton (2025). :contentReference[oaicite:5]{index=5}

### “Real user accounts” (secondary but useful)
- LizardByte discussion about headless Sunshine on Arch Linux (community). :contentReference[oaicite:6]{index=6}
- Level1Techs headless Sunshine guide (community). :contentReference[oaicite:7]{index=7}
- Community Hyprland headless-ish setups exist, but are more “janky / bespoke”. :contentReference[oaicite:8]{index=8}

---

## 5) Requirements derived from the above (do not assume implementation details)

### Functional requirements
1. Sunshine must start reliably and remain running.
2. A **streamable display** must exist at the intended resolution (1280x800).
3. The Steam Deck can connect and launch an app.
4. Concurrency: local desktop usage must not fight input focus with stream session.

### Operational requirements
- Setup is automated and repeatable (`install.sh` idempotent).
- Logs are easy to collect and summarize (single command).
- Failures are actionable (health checks explain what is broken and what to do next).

---

## 6) Repository deliverables

### Top-level files
- `AGENTS.md` (instructions for cursor-agent contribution style and invariants)
- `plan.md` (this doc)
- `README.md` (quickstart + troubleshooting)
- `LICENSE` (MIT or Apache-2.0 preferred)

### Scripts (required)
1. `install.sh`
   - Idempotently installs dependencies, writes configs, installs systemd units, enables services.
   - Performs transparent health checks at the end.

2. `collect-logs.sh`
   - Collects all high-signal system state + logs into a timestamped `/tmp/streamdeck-test-.../` directory:
     - `systemctl status` for relevant units
     - `journalctl` slices for units
     - Sunshine logs directory
     - versions (Sunshine, driver, kernel)
     - GPU state (nvidia-smi, encoder presence)
     - Xorg logs for the streaming session (`Xorg.99.log` or configured location)
     - display probe results (xrandr output for the streaming X display)

3. `test-full-cycle.sh`
   - Runs `install.sh`
   - Confirms health checks (and exits early if unhealthy)
   - Prompts user: “Start an app via Moonlight on Steam Deck, then press Enter”
   - Runs `collect-logs.sh`
   - Prints a **high-signal-density summary**
   - Copies the summary to clipboard using `wl-copy`

### Config/templates (required)
- `systemd/` units (templated, installed by `install.sh`)
- `xorg/` config templates (EDID / headless config for NVIDIA)
- `sunshine/` config templates (minimal, explicit capture + encoder selections)
- `scripts/lib.sh` (shared helpers for logging, assertions, etc.)

---

## 7) Option B implementation blueprint (what cursor-agent should build)

### 7.1 High-level layout
- The user’s desktop session remains **Hyprland**.
- The streaming session is a **separate Xorg instance**:
  - Runs on display `:99` (or another fixed number)
  - Uses NVIDIA + EDID override (DP-3 already points to Steam Deck resolution)
  - Creates a stable X screen at 1280x800
- Sunshine runs bound to that X display:
  - `DISPLAY=:99`
  - capture backend: `x11` (explicit)
  - encoder: `nvenc` (explicit)
- Steam/game launcher is optional in v1:
  - v1 success metric is: **Moonlight can connect and show the X session reliably**
  - Later: start Steam Big Picture inside the X session.

### 7.2 Why a separate Xorg instance solves the concurrency requirement
- If Sunshine runs inside the user’s Hyprland session, Sunshine’s injected input can fight focus.
- A separate X server isolates input/focus to the streaming session.
- The desktop remains fully usable without “mouse tug-of-war”.

(We should validate this with actual behavior; see test plan below.)

---

## 8) Systemd architecture (v1)

### Proposed units
1. `streamdeck-xorg.service`
   - Starts Xorg `:99` with a known config file (generated/installed).
   - Ensures the display exists and responds.

2. `streamdeck-sunshine.service`
   - Requires `streamdeck-xorg.service`
   - Exports `DISPLAY=:99`
   - Starts `sunshine` (or a wrapper script) with logs captured.

3. Optional later: `streamdeck-session@.service`
   - Starts Steam/gamescope/etc inside `DISPLAY=:99`

### User choice: separate `streamdeck` user?
Make it a design decision, but do NOT assume it’s required.

- **Pros** of a separate `streamdeck` user:
  - Less chance of stepping on the primary user’s runtime/config.
  - Clean separation of logs, permissions, and environment.
- **Pros** of running under the main user (`__BUDDY_USER__`):
  - Simpler file permissions.
  - Might avoid “access denied” issues on GPU nodes depending on group memberships.

Plan:
- Implement v1 with **separate `streamdeck` user**, because separation is a core repo goal.
- Make it configurable with a single variable in `install.sh` (e.g., `STREAM_USER=streamdeck`).

---

## 9) Health checks (must be explicit and actionable)

`install.sh` and `test-full-cycle.sh` must check:

### GPU / encoder
- `nvidia-smi` works.
- NVENC is present in FFmpeg encoder list (or Sunshine sees NVENC).
  - If FFmpeg is absent, check Sunshine logs for encoder detection.

### Xorg streaming display
- `DISPLAY=:99 xrandr --query` returns output(s) and the expected mode 1280x800.
- Xorg log exists and does not contain fatal errors.

### Sunshine
- Sunshine service is active.
- Sunshine log contains “Sunshine version …” and not immediate fatal errors.
- Sunshine web UI port is listening (if enabled) OR logs show it started successfully.

### Concurrency (containerization check)
- Provide a manual check step in `test-full-cycle.sh`:
  - while Steam Deck stream is active, confirm local desktop mouse/keyboard still work normally.
- Collect data:
  - which `/dev/input` devices Sunshine created and where they are routed (log it)
  - confirm desktop session is still responsive

---

## 10) Logging + summary requirements

### `collect-logs.sh` must capture:
- `systemctl status streamdeck-xorg streamdeck-sunshine`
- `journalctl -u streamdeck-xorg -n 200 --no-pager`
- `journalctl -u streamdeck-sunshine -n 200 --no-pager`
- Sunshine log directory (copy files)
- Xorg log (copy)
- `DISPLAY=:99 xrandr --verbose`
- `nvidia-smi -L`, `nvidia-smi --query-gpu=... --format=csv`
- versions:
  - `sunshine --version`
  - kernel `uname -a`
  - NVIDIA driver version
- If present: `/etc/X11/xorg.conf.d/*` or the repo’s installed config

### `test-full-cycle.sh` summary should include:
- PASS/FAIL list with reasons:
  - Xorg started? (yes/no)
  - Mode 1280x800 active? (yes/no)
  - Sunshine started? (yes/no)
  - Encoder detected? (yes/no)
  - User-confirmed Moonlight app launch? (yes/no)
- 20–40 lines max (high density)
- Copied via `wl-copy`

---

## 11) Test strategy (how we validate Option B works)

### v1 acceptance criteria
- After running `./test-full-cycle.sh`:
  - Sunshine is reachable by Moonlight.
  - Starting an “app” from Steam Deck succeeds (even if it’s just a dummy X app).
  - No capture init errors.
  - Local desktop remains usable during streaming.

### Debug triage order if it fails
1. Xorg not stable (most likely config/EDID/driver issue).
2. Sunshine can’t see display `:99` (DISPLAY/env wrong).
3. Encoder init fails (NVENC / permissions / driver mismatch).
4. Moonlight networking pairing issues (secondary).

---

## 12) Implementation checklist for cursor-agent

### Repo bootstrap
- Create repo as user `__BUDDY_USER__`.
- Add `README.md`, `LICENSE`, `AGENTS.md`, `plan.md`.
- Add directory structure:
  - `systemd/`
  - `xorg/`
  - `sunshine/`
  - `scripts/` (including `lib.sh`)
- Add scripts:
  - `install.sh`
  - `collect-logs.sh`
  - `test-full-cycle.sh`

### Minimal initial behavior
- `install.sh` installs packages + writes configs + enables services + prints health report.
- `test-full-cycle.sh` produces a `/tmp/streamdeck-test-...` bundle and a summary.

---

## 13) Open questions (cursor-agent should not guess; it should probe and log)

1. Best Xorg config approach on this distro:
   - Use `AllowEmptyInitialConfiguration` only?
   - Or enforce `ConnectedMonitor` + `CustomEDID` for DP-3 (since EDID override exists)?
2. Does the system already have a stable EDID file path for DP-3? If yes, log it.
3. Does the user want Steam started in the stream session automatically in v1? (Default: no; keep v1 minimal.)
4. Are there any existing Sunshine installs that must be removed/disabled?

Cursor-agent should implement probing commands and record results rather than assume.

---

## 14) Sources list (for README “Research” section)

- Sunshine Getting Started (references headless guide): https://docs.lizardbyte.dev/projects/sunshine/latest/md_docs_2getting__started.html
- Sunshine Configuration (capture backends): https://docs.lizardbyte.dev/projects/sunshine/master/md_docs_2configuration.html :contentReference[oaicite:9]{index=9}
- Official headless Sunshine setup guide (X11 + NVIDIA): https://app.lizardbyte.dev/2023-09-14-remote-ssh-headless-sunshine-setup/?lng=en-US :contentReference[oaicite:10]{index=10}
- NVIDIA dev forum: `ConnectedMonitor` + `CustomEDID`: :contentReference[oaicite:11]{index=11}
- Unix.SE: `AllowEmptyInitialConfiguration`: :contentReference[oaicite:12]{index=12}
- Real-world modern headless NVIDIA streaming writeup: :contentReference[oaicite:13]{index=13}
- LizardByte community discussion (headless on Arch): :contentReference[oaicite:14]{index=14}
