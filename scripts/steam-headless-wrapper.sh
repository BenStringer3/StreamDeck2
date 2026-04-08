#!/bin/bash
# Steam wrapper for headless streaming sessions (used by MoonDeck Buddy).
#
# Two fixes for headless :99 (Xorg dummy driver):
#
# 1. GLX vendor mismatch: Buddy inherits __GLX_VENDOR_LIBRARY_NAME=nvidia from
#    Sunshine's systemd env and passes it to Steam. But Xorg :99 (dummy driver)
#    only provides DRISWRAST (Mesa software GLX). NVIDIA's client-side GLX can't
#    negotiate with the swrast server, so Steam's CEF fails to acquire a GL
#    context and enters degraded mode — silently dropping all game launch commands.
#    Fix: unset the NVIDIA GLX vars so Mesa's client GLX matches the server.
#    Games use Vulkan (Proton/DXVK), not GLX, so this doesn't affect rendering.
#
# 2. Dialog URI: Buddy sends steam://launch/<AppID>/dialog which renders a launch
#    config dialog. On :99 with degraded CEF this blocks forever.
#    Fix: rewrite to steam://rungameid/<AppID> (launches directly, no dialog).
#
# Installed to /usr/local/bin/steam-headless by install.sh.
# Configured via Buddy's steam_exec_override setting.

REAL_STEAM="/usr/bin/steam"

# Strip NVIDIA GLX env vars — they cause a vendor mismatch on the dummy X server.
# Keep __VK_LAYER_NV_optimus so Vulkan games still select the NVIDIA GPU.
unset __GLX_VENDOR_LIBRARY_NAME
unset __NV_PRIME_RENDER_OFFLOAD

args=()
for arg in "$@"; do
    if [[ "$arg" =~ ^steam://launch/([0-9]+)/dialog$ ]]; then
        args+=("steam://rungameid/${BASH_REMATCH[1]}")
    else
        args+=("$arg")
    fi
done

exec "$REAL_STEAM" "${args[@]}"
