Goal

Replace the repo’s “Sunshine apps.json contains explicit games (Steam URLs, Eden, etc.)” approach with a MoonDeck-first workflow:

Sunshine exposes one canonical launcher app: MoonDeckStream

The Steam Deck’s MoonDeck Decky plugin drives game selection/launch (Steam library → Moonlight → Sunshine) without predefining games in Sunshine.

Preserve the repo’s core properties:

Option B architecture: isolated Xorg :99 streaming session

Fail fast health checks

High-signal log collection and summary

MoonDeck requires a host-side helper, MoonDeck Buddy, which:

tracks Steam state and running game

launches Steam games

provides host automation features
(Plugin overview)

Non-goals

Replacing Sunshine or Moonlight

Replacing Option B (:99) session isolation

Perfectly automating every MoonDeck Decky setting (we’ll document required toggles, but host-side automation is the priority)

What changes in the repo
1) Sunshine apps become minimal

Keep: Desktop (debug) and optionally Steam Big Picture (debug/fallback)

Add: MoonDeckStream (required)

Remove: per-game entries (steam://rungameid/..., Eden TOTK, etc.)

MoonDeck Buddy docs explicitly require adding MoonDeckStream as a Sunshine app and disabling “Continue streaming…” for it.

2) Install and manage MoonDeck Buddy (Arch)

MoonDeck Buddy install guide:

Arch: install moondeckbuddy-appimage via AUR

AppImage contains both binaries: MoonDeckBuddy and MoonDeckStream

Newer releases also added CLI flags like --enable-autostart / --disable-autostart.
Linux autostart uses systemd user services and may require restart or manual start the first time.

3) Logs: collect Buddy + MoonDeck logs

Buddy logs live in /tmp and are prefixed with moondeck...
MoonDeck plugin itself also writes logs in /tmp (on the Deck side / plugin backend), which is useful to know when correlating behavior.

Key design decisions
A) Which user runs MoonDeck Buddy?

MoonDeck Buddy is about Steam state and launching games, so it should run under the Steam library owner user (your __BUDDY_USER__), not the restricted streamdeck user.

Sunshine can still run as streamdeck and invoke MoonDeckStream; the stream helper can talk to Buddy over localhost/network (Buddy runs an HTTP server; logs show it listening on a port).

Implication: install.sh must configure Buddy as a user service for __BUDDY_USER__ (or at least provide a deterministic way to start it under __BUDDY_USER__).

B) Headless vs GUI Buddy mode

Buddy can run headless; GUI mode can crash if the display/compositor disappears. The config docs call out NO_GUI and behavior.

Given your setup has a dedicated Xorg session and separate desktop session, “headless” is the safest default for reliability.

C) Don’t rely on Buddy’s “click tray icon to enable autostart”

We want automation, so we should prefer:

MoonDeckBuddy --enable-autostart (if available in installed version)

or explicit systemd --user unit installation/enablement (fallback)

Phased plan (each phase must end with validation)
Phase 0 — Research checkpoints (pin facts in repo)

Deliverable: docs/moondeck.md with short, cited notes:

required Sunshine app entry (“MoonDeckStream”, “Continue streaming…” unchecked)

Arch install path options (AUR vs AppImage)

autostart behavior and systemd services

where logs live (/tmp/moondeck*)

Validation: doc exists; links work; notes match sources.

Phase 1 — Add MoonDeckStream to Sunshine apps.json.template

Work:

Edit sunshine/apps.json.template:

Add a new app entry MoonDeckStream

Command should be deterministic and stable:

Prefer a wrapper script: /usr/local/bin/MoonDeckStream

Or AppImage execution: .../MoonDeckBuddy.AppImage --exec MoonDeckStream

Ensure “Continue streaming…” is disabled in Sunshine for this app (Sunshine JSON field depends on format; mirror what your template already does for other entries, but set it to disabled as required).

Remove per-game entries from the template (Eden, specific rungameid, etc.)

Keep a Desktop debug entry.

Validation (host-side):

install.sh renders apps.json and Sunshine UI shows MoonDeckStream.

Moonlight can connect and selecting “MoonDeckStream” opens a session (even if it doesn’t launch a game yet).

Phase 2 — Idempotent MoonDeck Buddy install (Arch)

Work:
Implement one of these strategies (prefer A; keep B as fallback):

Strategy A: AUR package (moondeckbuddy-appimage)

Use your existing yay requirement (already in repo) to install it.

Ensure binaries are on PATH (or create wrappers).

This is the official Arch path per Buddy docs.

Strategy B: Direct AppImage install (fallback)

Download the latest AppImage release to a stable location (e.g. /opt/moondeckbuddy/MoonDeckBuddy.AppImage)

chmod +x

Create wrappers or symlinks so both binaries are available:

MoonDeckBuddy.AppImage --exec MoonDeckBuddy

MoonDeckBuddy.AppImage --exec MoonDeckStream

Also add: install.sh should sanity check Buddy presence:

command -v MoonDeckBuddy

command -v MoonDeckStream

Validation:

As user __BUDDY_USER__: MoonDeckBuddy --version works (or at least starts and writes /tmp/moondeckbuddy.log)

As user __BUDDY_USER__: Buddy is listening (log shows server listening on a port; example shows port 59999).

Phase 3 — Configure Buddy autostart as __BUDDY_USER__ (systemd user)

Buddy’s wiki explains Linux autostart creates two systemd user services:

moondeckbuddy.service (headless)

moondeckbuddy-gui-session.service (switches to GUI when DE session is present)

Work:

Prefer enabling via CLI flag if available:

sudo -u __BUDDY_USER__ MoonDeckBuddy --enable-autostart

Ensure services are enabled/started:

sudo -u __BUDDY_USER__ systemctl --user enable --now moondeckbuddy.service

sudo -u __BUDDY_USER__ systemctl --user enable --now moondeckbuddy-gui-session.service

Handle the “first time needs restart or manual start” footgun by explicitly starting both units.

Force headless reliability by setting NO_GUI=1 for the headless unit (either via unit override or environment file), based on Buddy config docs.

Validation:

sudo -u __BUDDY_USER__ systemctl --user status moondeckbuddy.service is active

/tmp/moondeckbuddy.log exists and shows “Server started listening …”

Phase 4 — Update collect-logs.sh to capture Buddy/MoonDeck signal

Work:
Add sections to collect-logs.sh:

Copy /tmp/moondeck*.log (Buddy wiki: all related logs start with moondeck... and live in /tmp).

Collect user-service logs (__BUDDY_USER__):

sudo -u __BUDDY_USER__ journalctl --user -u moondeckbuddy.service -n 300 --no-pager

sudo -u __BUDDY_USER__ journalctl --user -u moondeckbuddy-gui-session.service -n 300 --no-pager

Capture Buddy config:

~/.config/moondeckbuddy/settings.json location described in wiki.

Add a grep summary section:

error|warn|fail|port|listen|pair|moonlight|sunshine|stream

Keep your existing Sunshine/Xorg/NVIDIA checks.

Validation:

Running ./collect-logs.sh after a failed launch produces:

/tmp/moondeckbuddy.log copy (or at least the relevant moondeck logs)

user journal output for Buddy units

a grep summary that surfaces “connection refused”, “port”, etc.

Phase 5 — Update test-full-cycle.sh to include Buddy health gates

Work:
Before prompting the Deck interaction, add:

Buddy running check (__BUDDY_USER__ user):

systemctl --user status via sudo -u __BUDDY_USER__ ...

check /tmp/moondeckbuddy.log exists

Sunshine apps include MoonDeckStream:

parse rendered apps.json and ensure the entry exists

Optional: check Buddy listening port by parsing logs (port appears in log line in the wild).

After the run, include moondeck logs in the clipboard summary.

Validation:

If Buddy isn’t active, script exits early with a crisp, actionable error (“Buddy not running under __BUDDY_USER__; run …”).

If everything is active, you still get your normal prompt/collect/summary loop.

Phase 6 — README updates (new workflow)

Work:
Revise README to say:

Sunshine now publishes MoonDeckStream as the “one true” app for MoonDeck-based launching.

Install steps include MoonDeck Buddy on the host and MoonDeck plugin on the Deck.

Troubleshooting points at new logs collected from Buddy and /tmp/moondeck*.log.

Also include a short “first pairing” note:

Buddy pairing and general behavior is described in MoonDeck plugin docs; the plugin explicitly requires Buddy installed on the host.

Validation:

Fresh clone → ./test-full-cycle.sh gets you to a point where the Deck can launch a title via MoonDeck.

Additional footguns / research-backed “gotchas” to bake in

Resolution / scaling weirdness (especially external display on Deck)
MoonDeck troubleshooting calls out black borders/odd scaling causes, including Gamescope resolution settings and “pass resolution to Moonlight” interactions.
Action: add a README troubleshooting snippet: “set Moonlight display resolution to native; beware external display being primary.”

GUI mode crashes when display disappears
Buddy config docs explicitly warn Qt may terminate Buddy if compositor/display goes away; headless mode avoids this.
Action: default to headless in automated service.

Autostart uses systemd user services and can require manual start once
Buddy install guide notes you may need a reboot or to start units manually the first time.
Action: install.sh should explicitly enable --now the user units.

AUR package path/autostart edge cases
Recent Buddy release notes mention Linux autostart behavior changes and issues related to AppImage paths / systemd.
Action: prefer stable install location + wrappers; avoid “download in ~/Downloads” paths.

Concrete TODO checklist

 Add docs/moondeck.md with pinned facts + links (Phase 0)

 Update sunshine/apps.json.template:

 add MoonDeckStream

 remove hardcoded games

 Update install.sh:

 install moondeckbuddy (AUR primary, AppImage fallback)

 create stable wrapper scripts (/usr/local/bin/MoonDeckBuddy, /usr/local/bin/MoonDeckStream)

 configure __BUDDY_USER__ user services for Buddy (enable + start)

 Update collect-logs.sh:

 /tmp/moondeck*.log

 journalctl --user for Buddy units (__BUDDY_USER__)

 ~/.config/moondeckbuddy/settings.json

 Update test-full-cycle.sh:

 Buddy health gate

 Sunshine app presence gate

 Update README for new workflow + troubleshooting
