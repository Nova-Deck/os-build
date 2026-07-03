#!/bin/sh
# novadeck Steam OFFLINE factory-reset re-seeder (SteamOS layer D) — re-materialize the deck home
# from the pristine RO-root RECOVERY seed.
#
# NOTE: this does NOT run on a normal boot. make-sdcard.sh pre-seeds /home/deck at image-build time,
# so a healthy first boot already has a ready-to-run client (no copy). This tool exists for OFFLINE
# FACTORY RESET: it wipes /home/deck and rebuilds it from the reset-proof seed baked in the sealed
# RO root at /usr/share/novadeck/steam-seed (which survives a /home wipe) — no network (Steam's OOBE
# owns Wi-Fi). It is left UNENABLED and invoked on demand by a reset flow, not by graphical.target.
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
# Completion sentinel — written ONLY after a full seed succeeds. Guarding on this (not on the
# presence of steamrtarm64/steam) is what makes a partial/interrupted seed re-seed instead of
# sticking: an ENOSPC'd cp leaves steamrtarm64/steam behind yet the tree is incomplete, so a binary
# check would wrongly report "already seeded" (this exact trap killed a first boot — the /home ext4
# had not grown, cp ran out of space, and the half-tree then blocked re-seeding). Lives inside the
# seeded tree so wiping the tree also clears it.
SEED_STAMP="${STEAM}/.novadeck-seed-complete"

log() { echo "[novadeck-steam-bootstrap] $*"; }

# Seed the Steam tree only if the completion sentinel is present AND the client binary exists — but
# ALWAYS fix ownership below (see why). Not an early `exit 0`: a prior/older seed can leave the home
# present yet wrongly-owned, and we must still repair that or Steam cannot write its home.
if [ -e "$SEED_STAMP" ] && [ -x "${STEAM}/steamrtarm64/steam" ]; then
  log "native arm64 Steam already seeded at ${STEAM} (sentinel present) — verifying ownership only"
else
  [ -d "$SEED" ] || { log "ERROR: baked seed missing at ${SEED} (build-time bake skipped?)"; exit 1; }

  # Clear any partial/stale tree first so a re-seed after an interrupted copy starts clean (no merge
  # of a half-written tree with the fresh seed, no leftover files from an older seed).
  log "seeding native arm64 Steam into ${STEAM} from ${SEED} (offline)"
  rm -rf "${STEAM}" "${DOT_STEAM}"
  mkdir -p "${STEAM}" "${DOT_STEAM}"

  # Copy the baked .local/share/Steam contents (client seed + runtime + package/beta + libibus shim
  # + .cef marker) into the writable home. cp -a preserves the relative libibus symlink. set -e means
  # a failed copy (e.g. ENOSPC) aborts BEFORE the sentinel is written, so the next run re-seeds.
  cp -a "${SEED}/." "${STEAM}/"

  # .steam/ compatibility symlinks Steam + tools expect (mirror SteamOS's ~/.steam layout). These are
  # HOME-relative, so they are created here against /home/deck, not baked into the RO seed.
  ln -sfn ../.local/share/Steam            "${DOT_STEAM}/steam"
  ln -sfn ../.local/share/Steam            "${DOT_STEAM}/root"
  ln -sfn ../.local/share/Steam/linuxarm64 "${DOT_STEAM}/sdkarm64"

  # Mark the seed complete — LAST, only once every copy above has succeeded.
  : >"$SEED_STAMP"
  log "seed complete — wrote sentinel ${SEED_STAMP##*/}"
fi

# ALWAYS ensure the deck user owns its ENTIRE home — not just the seeded Steam subtree. Two traps make
# this mandatory on every boot, not just the seeding one: (1) the baked seed is owned by the build
# user (uid 1000) and `cp -a` preserves that, while mkdir creates /home/deck + the .local/.steam
# PARENTS as root — so the parents end up root-owned even though the Steam content is deck-owned;
# (2) a stale home from an older seed can already have Steam present (so the seed step above is
# skipped) yet keep /home/deck root-owned. Either way deck (uid 1000) then cannot create ~/.cache or
# ~/.steam/steam.token and Steam dies with "Permission denied". Guard the recursive chown on a cheap
# top-level owner check so normal boots pay nothing.
if getent passwd deck >/dev/null 2>&1; then
  deck_uid="$(id -u deck)"
  if [ "$(stat -c '%u' "${STEAM_HOME}" 2>/dev/null || echo -1)" != "${deck_uid}" ]; then
    log "repairing ownership of ${STEAM_HOME} -> deck:deck"
    chown -R deck:deck "${STEAM_HOME}"
  fi
else
  log "WARNING: deck user missing — leaving ${STEAM_HOME} root-owned"
fi

log "done — native arm64 Steam seeded + home owned by deck; first launch self-updates the UI"
