#!/bin/bash
# MoonDeckStream wrapper: sets SUNSHINE_LAUNCHED, clears stale singleton, execs real binary.
# Installed to /usr/local/bin/MoonDeckStream by install.sh (placeholders __REAL_BIN__ and __PRE_ARGS__ substituted).

set -e

# Stderr goes to log so collect-logs.sh and users can see wrapper and app errors
STDERR_LOG="/tmp/moondeckstream-stderr.log"
exec 2>>"$STDERR_LOG"

log_wrapper() {
    echo "[$(date -Iseconds)] wrapper: $*" >&2
}

export SUNSHINE_LAUNCHED=1

# Defensive: DISPLAY should be set by Sunshine (e.g. :99)
if [[ -z "${DISPLAY:-}" ]]; then
    log_wrapper "WARN: DISPLAY is not set (Sunshine typically sets DISPLAY=:99)"
fi

# Pre-launch Steam on the stream display so it is up before Buddy reacts; if Steam uses
# singleton behavior, Buddy's later steam (e.g. game launch) will connect to this instance and run on :99.
STEAM_BIN="/usr/bin/steam"
if [[ -x "$STEAM_BIN" ]]; then
    env DISPLAY=:99 WAYLAND_DISPLAY= XDG_SESSION_TYPE= "$STEAM_BIN" -gamepadui &>/dev/null &
else
    log_wrapper "WARN: Steam not found at $STEAM_BIN; pre-launch skipped (stream will continue)"
fi

# Defensive: real binary must exist and be executable
REAL_BIN="__REAL_BIN__"
if [[ ! -x "$REAL_BIN" ]]; then
    log_wrapper "FATAL: real binary not executable or missing: $REAL_BIN"
    exit 127
fi

# MoonDeckStream is a singleton (QSharedMemory + QSystemSemaphore). On SIGTERM it quick_exit()s
# and does not run destructors. System V shm/sem segments are NOT auto-destroyed when the process
# exits — they persist until IPC_RMID. So after killing stale PIDs we must remove the Qt IPC key
# files (used by ftok()) so the new process gets a fresh key and create()s a new segment instead
# of attach()ing to the orphaned one. See docs/moondeckstream-singleton-research.md.
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
    STALE_WAIT_MAX=50
    STALE_POLL=0.2
    ELAPSED=0
    while [[ $ELAPSED -lt $STALE_WAIT_MAX ]]; do
        STILL_ALIVE=0
        for pid in "${STALE_PIDS[@]}"; do
            kill -0 "$pid" 2>/dev/null && STILL_ALIVE=1
        done
        [[ $STILL_ALIVE -eq 0 ]] && break
        sleep "$STALE_POLL"
        ELAPSED=$(( ELAPSED + 1 ))
    done
    if [[ $ELAPSED -ge $STALE_WAIT_MAX ]]; then
        log_wrapper "WARN: stale PIDs did not exit within ${STALE_WAIT_MAX}×${STALE_POLL}s, proceeding anyway"
    else
        log_wrapper "Stale PIDs gone (waited ${ELAPSED}×${STALE_POLL}s)"
    fi
    sleep 0.2
fi

# Remove orphaned Qt IPC key files for MoonDeckStream so the new process create()s a new
# segment instead of attach()ing to the orphaned one. Keys match moondeck-buddy
# SingleInstanceGuard: SHA1("MoonDeckStream_shared_mem_key") and ("MoonDeckStream_mem_lock_key").
# Qt may create under /tmp, /tmp/$UID, or XDG_RUNTIME_DIR (e.g. /run/user/$UID). See docs/moondeckstream-singleton-research.md.
HASH_SHM=$(echo -n "MoonDeckStream_shared_mem_key" | sha1sum 2>/dev/null | cut -c1-40)
HASH_SEM=$(echo -n "MoonDeckStream_mem_lock_key" | sha1sum 2>/dev/null | cut -c1-40)
# Diagnostic: log hashes and candidate dirs/files before cleanup (so we can see why "Removed..." might never appear)
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

# TEMPORARY WORKAROUND: When key-file cleanup found nothing, orphaned System V shm/sem may still
# exist (Qt key path/format can differ from wrapper's hashes; on SIGTERM MoonDeckStream uses
# quick_exit() so destructors never run and IPC is never released). Remove orphaned shm (nattch 0)
# and all semaphores owned by us so the new process can create() fresh IPC instead of attach()ing.
# Prefer upstream fix: MoonDeckStream should handle SIGTERM with graceful shutdown so destructors
# run and IPC is released. See docs/moondeck-buddy-issue-sigterm-graceful-shutdown.md and
# docs/troubleshooting.md.
if [[ $REMOVED_COUNT -eq 0 ]] && command -v ipcs &>/dev/null && command -v ipcrm &>/dev/null; then
    ME=$(whoami)
    while read -r shmid; do
        [[ -n "$shmid" ]] || continue
        if ipcrm -m "$shmid" 2>/dev/null; then
            log_wrapper "Removed orphaned shm segment: $shmid (owner=$ME, nattch=0)"
        fi
    done < <(ipcs -m 2>/dev/null | awk -v u="$ME" 'NR>1 && $3==u && $6==0 {print $2}')
    # TEMPORARY WORKAROUND: We cannot identify which sem is MoonDeckStream's; remove all of our
    # semaphores. This may affect other Qt apps (e.g. MoonDeckBuddy) if they use semaphores in the
    # same user session. Remove this block once MoonDeckStream does graceful SIGTERM shutdown.
    while read -r semid; do
        [[ -n "$semid" ]] || continue
        if ipcrm -s "$semid" 2>/dev/null; then
            log_wrapper "Removed orphaned semaphore: $semid (owner=$ME)"
        fi
    done < <(ipcs -s 2>/dev/null | awk -v u="$ME" 'NR>1 && $3==u {print $2}')
fi

log_wrapper "Exec-ing real binary: $REAL_BIN (PID $$)"
# __PRE_ARGS__ is empty for AUR binary, or "--exec MoonDeckStream" for AppImage
exec "$REAL_BIN" __PRE_ARGS__ "$@"
