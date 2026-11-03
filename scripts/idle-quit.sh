#!/bin/bash
# Quits a per-game app once no client has been streaming it for STREAMDECK_IDLE_QUIT_SECONDS.
# Installed to /usr/local/bin/streamdeck-idle-quit by install.sh; runs as BUDDY_USER
# (streamdeck-idle-quit.service).
#
# A client that disconnects without quitting leaves Sunshine's app running so it can resume, and the
# app's systemd-inhibit block keeps the host awake indefinitely. Sunshine has no idle timeout, so this
# watches for the two facts that define an abandoned game:
#   - a per-game app is running: a 'block' sleep inhibitor with Who=streamdeck. Sunshine starts each
#     app in its own process group, led by that systemd-inhibit.
#   - nobody is watching it: the GPU has no NVENC session. Sunshine encodes only while a client streams.
# When both hold for the whole timeout, it sends SIGTERM to BUDDY_USER's processes in the app's
# process group (what Sunshine's own quit sends), then SIGKILL after GAME_EXIT_TIMEOUT. sudo and
# systemd-inhibit exit with the game, and Sunshine sees the app end.

set -euo pipefail

IDLE_LIMIT="${STREAMDECK_IDLE_QUIT_SECONDS:-1800}"
POLL_SECONDS=60
GAME_EXIT_TIMEOUT=10

log() {
    echo "$*" >&2
}

# Process group of the running per-game app, or nothing.
game_pgid() {
    local pid
    pid="$(systemd-inhibit --list --no-legend --no-pager \
        | awk '$1 == "streamdeck" && $NF == "block" && !pid { pid = $4 } END { print pid }')"
    if [[ -n "$pid" ]]; then
        # The app may exit between the two reads; that is the same as no app.
        ps -o pgid= -p "$pid" | tr -d ' ' || true
    fi
}

encoder_sessions() {
    nvidia-smi --query-gpu=encoder.stats.sessionCount --format=csv,noheader \
        | awk '{ n += $1 } END { print n + 0 }'
}

quit_game() {
    local pgid="$1"
    log "No client for ${IDLE_LIMIT}s: stopping per-game app (process group $pgid)"
    pkill -TERM -u "$USER" -g "$pgid" || true
    for _ in $(seq "$GAME_EXIT_TIMEOUT"); do
        pgrep -u "$USER" -g "$pgid" >/dev/null || { log "Per-game app exited"; return 0; }
        sleep 1
    done
    log "Per-game app ignored SIGTERM for ${GAME_EXIT_TIMEOUT}s; sending SIGKILL"
    pkill -KILL -u "$USER" -g "$pgid" || true
}

log "Watching per-game apps: quit after ${IDLE_LIMIT}s without a streaming client"
idle_pgid=""
idle_since=0
while true; do
    pgid="$(game_pgid)"
    if [[ -z "$pgid" ]] || (( $(encoder_sessions) > 0 )); then
        [[ -n "$idle_pgid" ]] && log "Client streaming again (or app ended); idle timer cleared"
        idle_pgid=""
    elif [[ "$pgid" != "$idle_pgid" ]]; then
        idle_pgid="$pgid"
        idle_since="$(date +%s)"
        log "Per-game app (process group $pgid) has no streaming client; quitting it in ${IDLE_LIMIT}s"
    elif (( $(date +%s) - idle_since >= IDLE_LIMIT )); then
        quit_game "$pgid"
        idle_pgid=""
    fi
    sleep "$POLL_SECONDS"
done
