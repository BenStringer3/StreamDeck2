#!/bin/bash
# Steam wrapper for headless streaming sessions (used by MoonDeck Buddy).
#
# Three fixes for headless :99 (Xorg dummy driver):
#
# 1. GLX vendor mismatch: Buddy inherits __GLX_VENDOR_LIBRARY_NAME=nvidia from
#    Sunshine's systemd env and passes it to Steam. But Xorg :99 (dummy driver)
#    only provides DRISWRAST (Mesa software GLX). NVIDIA's client-side GLX can't
#    negotiate with the swrast server, so Steam's CEF fails to acquire a GL
#    context and enters degraded mode — silently dropping all game launch commands.
#    Fix: unset the NVIDIA GLX vars so Mesa's client GLX matches the server.
#    Games use Vulkan (Proton/DXVK), not GLX, so this doesn't affect rendering.
#
# 2. Launch-options dialog: Buddy sends steam://launch/<AppID>/dialog. For games
#    with multiple launch configs (e.g. Satisfactory: with/without EAC), both
#    /dialog and rungameid show a config selection dialog. CEF can't render this
#    on the dummy display (X_PutImage BadMatch), so the launch blocks silently.
#    Fix: rewrite to steam://launch/<AppID>/0 (selects config 0, skips dialog).
#
# 3. Shader cache dialog: games with pending Vulkan shader pre-cache downloads
#    trigger a "Processing Vulkan Shaders" progress dialog (ProcessingShaderCache
#    GameAction step). On the headless display CEF can't render this dialog, so
#    the launch hangs indefinitely waiting for user acknowledgment.
#    Fix: pass -noshaders to disable Steam's shader manager. Games still compile
#    shaders at runtime via DXVK pipeline cache — only the pre-compiled download
#    cache is skipped, which may cause minor first-run stuttering.
#
# Installed to /usr/local/bin/steam-headless by install.sh.
# Configured via Buddy's steam_exec_override setting.

REAL_STEAM="/usr/bin/steam"

# Strip NVIDIA GLX env vars — they cause a vendor mismatch on the dummy X server.
# Keep __VK_LAYER_NV_optimus so Vulkan games still select the NVIDIA GPU.
unset __GLX_VENDOR_LIBRARY_NAME
unset __NV_PRIME_RENDER_OFFLOAD

args=(-noshaders)
for arg in "$@"; do
    if [[ "$arg" =~ ^steam://launch/([0-9]+)/dialog$ ]]; then
        args+=("steam://launch/${BASH_REMATCH[1]}/0")
    else
        args+=("$arg")
    fi
done

exec "$REAL_STEAM" "${args[@]}"
