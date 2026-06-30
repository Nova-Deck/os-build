#!/bin/sh
# novadeck Steam first-boot seeder (SteamOS layer D) — seed the deck home from the BAKED seed.
#
# OFFLINE analog of SteamOS's steamos-create-homedir: the native arm64 Steam client+runtime are
# baked into the sealed RO root at /usr/share/novadeck/steam-seed/ (build-time, by
# steam/fetch-steam-seed.sh + images/assemble-rootfs.sh). This copies that seed into the WRITABLE
# /home/deck so Steam can self-update there across A/B rootfs slots — with NO network: Steam's own
# OOBE owns first-boot Wi-Fi, so an OS-side network fetch here would deadlock (see the
# steam-must-be-baked-offline note). Runs after /home is mounted + grown (novadeck-grow-home).
#
# Idempotent: a no-op once steamrtarm64/steam is present in the home. The actual self-update + full
# UI download happens on the first real launch inside gamescope (novadeck-steam), not here.
set -eu

STEAM_HOME="${STEAM_HOME:-/home/deck}"
STEAM="${STEAM_HOME}/.local/share/Steam"
DOT_STEAM="${STEAM_HOME}/.steam"
SEED="/usr/share/novadeck/steam-seed"

log() { echo "[novadeck-steam-bootstrap] $*"; }

if [ -x "${STEAM}/steamrtarm64/steam" ]; then
  log "native arm64 Steam already seeded at ${STEAM} — nothing to do"
  exit 0
fi

[ -d "$SEED" ] || { log "ERROR: baked seed missing at ${SEED} (build-time bake skipped?)"; exit 1; }

log "seeding native arm64 Steam into ${STEAM} from ${SEED} (offline)"
mkdir -p "${STEAM}" "${DOT_STEAM}"

# Copy the baked .local/share/Steam contents (client seed + runtime + package/beta + libibus shim
# + .cef marker) into the writable home. cp -a preserves the relative libibus symlink.
cp -a "${SEED}/." "${STEAM}/"

# .steam/ compatibility symlinks Steam + tools expect (mirror SteamOS's ~/.steam layout). These are
# HOME-relative, so they are created here against /home/deck, not baked into the RO seed.
ln -sfn ../.local/share/Steam            "${DOT_STEAM}/steam"
ln -sfn ../.local/share/Steam            "${DOT_STEAM}/root"
ln -sfn ../.local/share/Steam/linuxarm64 "${DOT_STEAM}/sdkarm64"

# The whole tree must belong to the deck user (uid 1000) that owns the session/home.
if getent passwd deck >/dev/null 2>&1; then
  chown -R deck:deck "${STEAM_HOME}"
else
  log "WARNING: deck user missing — leaving ${STEAM_HOME} root-owned"
fi

log "done — native arm64 Steam seeded; first launch self-updates + downloads the UI"
