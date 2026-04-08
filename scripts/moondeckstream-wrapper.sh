#!/bin/bash
# MoonDeckStream wrapper: manages Steam lifecycle, clears stale singleton, runs real binary.
# Installed to /usr/local/bin/MoonDeckStream by install.sh (placeholders __REAL_BIN__ and __PRE_ARGS__ substituted).
#
# Lifecycle: kill stale Steam → pre-launch Steam on :99 → run MoonDeckStream → on exit, shut down Steam.
# MoonDeckStream runs as a child (not exec) so the wrapper can clean up Steam when the stream ends.

set -e

STDERR_LOG="/tmp/moondeckstream-stderr.log"
exec 2>>"$STDERR_LOG"

log_wrapper() {
    echo "[$(date -Iseconds)] wrapper: $*" >&2
}

export SUNSHINE_LAUNCHED=1

STEAM_BIN="/usr/bin/steam"
REAL_BIN="__REAL_BIN__"

if [[ -z "${DISPLAY:-}" ]]; then
    log_wrapper "WARN: DISPLAY is not set (Sunshine typically sets DISPLAY=:99)"
fi

if [[ ! -x "$REAL_BIN" ]]; then
    log_wrapper "FATAL: real binary not executable or missing: $REAL_BIN"
    exit 127
fi

# --- Steam lifecycle ---

shutdown_steam() {
    if ! [[ -x "$STEAM_BIN" ]]; then return; fi
    if ! pgrep -u "$(whoami)" -f '[s]team' &>/dev/null; then
        log_wrapper "No Steam processes to shut down"
        return
    fi
    log_wrapper "Shutting down Steam on :99"
    timeout 10 env DISPLAY=:99 WAYLAND_DISPLAY= "$STEAM_BIN" -shutdown &>/dev/null || true
    local i=0
    while [[ $i -lt 15 ]] && pgrep -u "$(whoami)" -f '[s]team' &>/dev/null; do
        sleep 1; i=$((i + 1))
    done
    local leftover
    leftover=$(pgrep -u "$(whoami)" -f '[s]team' 2>/dev/null || true)
    if [[ -n "$leftover" ]]; then
        log_wrapper "Force-killing remaining Steam PIDs: $leftover"
        kill -9 $leftover 2>/dev/null || true
        sleep 1
    fi
}

# Kill stale Steam from previous sessions so each stream starts clean.
# This prevents accumulation and ensures fresh game-launch state.
shutdown_steam

# Buddy will start Steam via steam_exec_override (steam-headless) with the
# game URI on the command line. Do NOT pre-launch Steam here — Steam's
# singleton IPC unreliably forwards URIs on the headless :99 display (CEF
# degraded mode drops IPC messages). Direct command-line URI is reliable.

# --- Stale MoonDeckStream singleton cleanup ---

MY_PID=$$
STALE_PIDS=()
for pid in $(pgrep -u "$(whoami)" -x MoonDeckStream 2>/dev/null); do
    [[ "$pid" != "$MY_PID" ]] && STALE_PIDS+=( "$pid" )
done
if [[ ${#STALE_PIDS[@]} -gt 0 ]]; then
    log_wrapper "Sending SIGTERM to stale MoonDeckStream PIDs (excluding self $MY_PID): ${STALE_PIDS[*]}"
    for pid in "${STALE_PIDS[@]}"; do
        kill -TERM "$pid" 2>/dev/null || true
    done
    local_wait=0
    while [[ $local_wait -lt 50 ]]; do
        all_gone=1
        for pid in "${STALE_PIDS[@]}"; do
            kill -0 "$pid" 2>/dev/null && all_gone=0
        done
        [[ $all_gone -eq 1 ]] && break
        sleep 0.2; local_wait=$((local_wait + 1))
    done
    if [[ $local_wait -ge 50 ]]; then
        log_wrapper "WARN: stale PIDs did not exit within 10s, proceeding anyway"
    else
        log_wrapper "Stale PIDs gone"
    fi
    sleep 0.2
fi

# Qt IPC key-file cleanup (MoonDeckStream singleton uses QSharedMemory/QSystemSemaphore)
HASH_SHM=$(echo -n "MoonDeckStream_shared_mem_key" | sha1sum 2>/dev/null | cut -c1-40)
HASH_SEM=$(echo -n "MoonDeckStream_mem_lock_key" | sha1sum 2>/dev/null | cut -c1-40)
log_wrapper "Singleton cleanup: HASH_SHM=$HASH_SHM HASH_SEM=$HASH_SEM"
CLEANUP_DIRS=(/tmp "/tmp/$(id -u)")
[[ -n "${XDG_RUNTIME_DIR:-}" ]] && [[ -d "$XDG_RUNTIME_DIR" ]] && CLEANUP_DIRS+=( "$XDG_RUNTIME_DIR" )
REMOVED_COUNT=0
for dir in "${CLEANUP_DIRS[@]}"; do
    [[ -d "$dir" ]] || continue
    for f in "$dir"/qipc_sharedmemory_* "$dir"/qipc_systemsem_*; do
        [[ -f "$f" ]] || continue
        match=no
        [[ "$f" == *"$HASH_SHM"* ]] || [[ "$f" == *"$HASH_SEM"* ]] && match=yes
        log_wrapper "Candidate key file: $f (match=$match)"
        [[ "$f" == *"$HASH_SHM"* ]] || [[ "$f" == *"$HASH_SEM"* ]] || continue
        rm -f "$f" && { log_wrapper "Removed orphaned Qt IPC key file: $f"; REMOVED_COUNT=$(( REMOVED_COUNT + 1 )); }
    done
done
log_wrapper "Singleton cleanup: removed $REMOVED_COUNT key file(s)"

# Orphaned System V IPC fallback (MoonDeckStream quick_exit() doesn't run destructors)
if [[ $REMOVED_COUNT -eq 0 ]] && command -v ipcs &>/dev/null && command -v ipcrm &>/dev/null; then
    ME=$(whoami)
    while read -r shmid; do
        [[ -n "$shmid" ]] || continue
        if ipcrm -m "$shmid" 2>/dev/null; then
            log_wrapper "Removed orphaned shm segment: $shmid (owner=$ME, nattch=0)"
        fi
    done < <(ipcs -m 2>/dev/null | awk -v u="$ME" 'NR>1 && $3==u && $6==0 {print $2}')
    while read -r semid; do
        [[ -n "$semid" ]] || continue
        if ipcrm -s "$semid" 2>/dev/null; then
            log_wrapper "Removed orphaned semaphore: $semid (owner=$ME)"
        fi
    done < <(ipcs -s 2>/dev/null | awk -v u="$ME" 'NR>1 && $3==u {print $2}')
fi

# --- Run MoonDeckStream (child process, not exec) ---
# Run as child so we can shut down Steam after exit. Forward SIGTERM so Sunshine's
# kill signal reaches MoonDeckStream.

log_wrapper "Starting MoonDeckStream: $REAL_BIN (wrapper PID $$)"
# __PRE_ARGS__ is empty for AUR binary, or "--exec MoonDeckStream" for AppImage
"$REAL_BIN" __PRE_ARGS__ "$@" &
CHILD_PID=$!

trap 'log_wrapper "SIGTERM received, forwarding to MoonDeckStream ($CHILD_PID)"; kill -TERM $CHILD_PID 2>/dev/null' TERM
trap 'log_wrapper "SIGINT received, forwarding to MoonDeckStream ($CHILD_PID)"; kill -INT $CHILD_PID 2>/dev/null' INT

wait $CHILD_PID 2>/dev/null
MDS_EXIT=$?

log_wrapper "MoonDeckStream exited ($MDS_EXIT), cleaning up Steam"
shutdown_steam

exit $MDS_EXIT
