# Input leakage — evidence from logs

Use this when interpreting `input-leakage.txt` and `controller-input.txt` from a test run.

## 1. PC keyboard/mouse affect Eden (and “mice are linked”)

**Evidence:** Xorg :99 has **physical** input devices open.

From `input-leakage.txt`, section *"Which input devices does Xorg :99 (streamdeck) have open?"*:

| fd  | device    | Device name (from /proc/bus/input/devices) |
|-----|-----------|--------------------------------------------|
| 19  | event1    | Power Button                               |
| 20  | event2    | Video Bus                                  |
| 21  | event0    | Power Button                               |
| 22  | event3    | **OBINS OBINS AnnePro2** (PC keyboard)     |
| 23  | event5    | OBINS AnnePro2 Consumer Control            |
| 24  | event6    | **OBINS OBINS AnnePro2 Keyboard**          |
| 25  | event7    | **OBINS OBINS AnnePro2 Mouse**              |
| 26  | event16   | Eee PC WMI hotkeys                         |
| 27  | event20   | **Logitech MX Master 3S** (PC mouse)        |
| 28  | event18   | Mouse passthrough (absolute) ✓             |
| 29  | event19   | Keyboard passthrough ✓                     |
| 30  | event17   | Mouse passthrough ✓                        |
| 34  | event22   | Pen passthrough ✓                          |
| 35  | event21   | Touch passthrough ✓                        |

So Xorg :99 is opening **OBINS Anne Pro 2** (keyboard/mouse) and **Logitech MX Master 3S**, plus power/video/WMI. That is why PC keyboard and PC mouse affect the stream (Eden) and why “mice are linked” (both PC mouse and Moonlight mouse move the same cursor on :99).

**Root cause:** The Xorg InputClass “ignore all” rule using `MatchProduct "*"` does not match devices in this setup (Xorg/libinput do not treat `*` as a glob). So the ignore-all never applies and all devices are still added.

---

## 2. Steam Deck trackpad/mouse moves PC cursor

**Evidence:** In `input-leakage.txt`, section *"Processes with /dev/input/* open"*: which process has the **Mouse passthrough** (or **Mouse passthrough (absolute)**) event open?

- If a **desktop** process (e.g. hyprland, Xwayland, gnome-shell) has it open, the desktop is reading Moonlight input → cursor moves on PC. That can happen even when udev TAGS do *not* contain `uaccess`, because udev may have set `GROUP="input"` and `MODE="0660"`: the desktop user is typically in group `input`, so the compositor can open the device **by path**.
- **Fix:** udev rule must use `GROUP="streamdeck"` (not `input`) so only the streamdeck user can open these devices. Also `TAG-="uaccess"`. After changing the rule, re-run `install.sh` and **reboot** so device nodes are recreated and the desktop drops open handles.
- If passthrough devices have `uaccess` in TAGS, logind is granting desktop access; the same udev fix removes that.

---

## 3. Gamepad not recognized in Eden

**Evidence:** Xorg :99 does **not** have the Sunshine virtual gamepad open.

- **Sunshine X-Box One (virtual) pad** is `event23` (from `/proc/bus/input/devices`).
- The list of devices open by Xorg :99 (above) does **not** include event23.

So the gamepad device exists and Sunshine creates it, but the stream session (Xorg :99) never opens it. Eden only sees input from devices attached to :99, so the gamepad is not recognized.

**Root cause:** (1) Xorg allow list must include the gamepad: InputClass `MatchProduct "Sunshine X-Box One"` with `Option "Ignore" "false"` (done in `xorg/99-streamdeck.conf.template`). (2) The gamepad is created by Sunshine when a client connects, so it appears **after** Xorg :99 has started (hotplug). Xorg should pick it up when udev adds it; if :99 still doesn’t have it open, collect logs **while in an active stream** so the device exists, then check which PID has that event open. (3) udev must use `GROUP="streamdeck"` for the gamepad so the desktop cannot grab it first.

---

## Summary

| Observation           | Evidence in logs                                                                 | Cause |
|-----------------------|-----------------------------------------------------------------------------------|--------|
| PC keyboard affects Eden | Xorg :99 has event3, event6 (Anne Pro 2 keyboard) open                          | InputClass `MatchProduct "*"` not applied; physical devices still added |
| PC mouse affects Eden | Xorg :99 has event7 (Anne Pro 2 mouse), event20 (Logitech MX Master 3S) open    | Same |
| Mice “linked”         | Both PC mouse and passthrough mouse open on :99 → same cursor                    | Same |
| Gamepad not in Eden   | event23 (Sunshine X-Box One virtual pad) not in Xorg’s open fd list               | Gamepad not in Xorg allow list |
