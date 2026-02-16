#!/bin/bash
# Load install configuration: STREAM_USER, BUDDY_USER, STREAM_DISPLAY, STREAM_GROUP.
# Source this from scripts that need these values. Order: config file (if readable) -> env -> defaults.
# Install writes /etc/streamdeck/install.conf (mode 644) so non-root scripts can read it.

if [[ -n "${STREAM_USER:-}" && -n "${BUDDY_USER:-}" && -n "${STREAM_DISPLAY:-}" ]]; then
    # Already fully set (e.g. by install.sh before sourcing)
    : no-op
else
    # Resolve REPO_ROOT from this script's location (we live in scripts/)
    _loader_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    _repo_root="$(cd "$_loader_dir/.." && pwd)"

    if [[ -r /etc/streamdeck/install.conf ]]; then
        # shellcheck source=/dev/null
        source /etc/streamdeck/install.conf
    fi
    if [[ -f "$_repo_root/.streamdeck-install.conf" ]] && [[ -r "$_repo_root/.streamdeck-install.conf" ]]; then
        # shellcheck source=/dev/null
        source "$_repo_root/.streamdeck-install.conf"
    fi

    # Env overrides whatever was in config
    STREAM_USER="${STREAM_USER:-streamdeck}"
    # BUDDY_USER detection: prefer env var, then SUDO_USER, then logname (skip root)
    BUDDY_USER="${BUDDY_USER:-${SUDO_USER:-}}"
    if [[ -z "$BUDDY_USER" ]]; then
        LOGNAME_USER=$(logname 2>/dev/null || true)
        if [[ -n "$LOGNAME_USER" && "$LOGNAME_USER" != "root" ]]; then
            BUDDY_USER="$LOGNAME_USER"
        fi
    fi
    STREAM_DISPLAY="${STREAM_DISPLAY:-:99}"
    STREAM_GROUP="${STREAM_GROUP:-$STREAM_USER}"
fi
