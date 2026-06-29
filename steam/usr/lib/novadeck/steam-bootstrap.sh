#!/bin/sh
# novadeck Steam bootstrap (SteamOS layer D) — stage the NATIVE arm64 Steam tree.
#
# The Deck-UI shell runs native on aarch64 (only x86 *games* need FEX/Proton). Valve ships a
# native arm64 Steam client+runtime on the steamdeck_publicbeta channel; this fetches+unpacks it
# into the WRITABLE shared home so Steam can self-update there across A/B rootfs slots. It does NOT
# live in the sealed read-only root. Verified recipe (2026-06-27) cross-checked against
# ROCKNIX `Install Steam.sh` and Armada `generate-steam-bootstrap.sh` — both peers on these SoCs.
#
# Idempotent: re-running is a no-op once steamrtarm64/steam is present. Run as the first-boot
# oneshot (novadeck-steam-bootstrap.service) BEFORE the gamescope session; the actual self-update
# + UI download happens on the first real launch inside gamescope (novadeck-steam), not here.
set -eu

STEAM_HOME="${STEAM_HOME:-/home/deck}"
STEAM="${STEAM_HOME}/.local/share/Steam"
DOT_STEAM="${STEAM_HOME}/.steam"
CHANNEL="${NOVADECK_STEAM_CHANNEL:-steamdeck_publicbeta}"
CDN="https://client-update.steamstatic.com"
MANIFEST_NAME="steam_client_${CHANNEL}_linuxarm64"
MANIFEST_URL="${CDN}/${MANIFEST_NAME}"
RUNTIME_URL="https://repo.steampowered.com/steamrt3c/images/latest-public-beta/steam-runtime-steamrt-arm64.tar.xz"

log() { echo "[novadeck-steam-bootstrap] $*"; }

if [ -x "${STEAM}/steamrtarm64/steam" ]; then
  log "native arm64 Steam already staged at ${STEAM} — nothing to do"
  exit 0
fi

log "staging native arm64 Steam into ${STEAM} (channel ${CHANNEL})"
mkdir -p "${STEAM}/package" "${DOT_STEAM}"

# Channel marker so the client tracks the arm64 publicbeta line (not the x86 default).
echo "${CHANNEL}" >"${STEAM}/package/beta"

# .steam/ compatibility symlinks Steam + tools expect (mirror SteamOS's ~/.steam layout).
ln -sfn ../.local/share/Steam            "${DOT_STEAM}/steam"
ln -sfn ../.local/share/Steam            "${DOT_STEAM}/root"
ln -sfn ../.local/share/Steam/linuxarm64 "${DOT_STEAM}/sdkarm64"

# 1. Client seed: parse the arm64 bins package out of the publicbeta manifest, fetch + unpack.
log "fetching client manifest"
curl -fsSL -o "${STEAM}/package/${MANIFEST_NAME}.manifest" "${MANIFEST_URL}"
# grep -a (treat the part-binary VDF manifest as text) instead of strings(1): the base ships no
# binutils, and strings is overkill — the seed token is a plain printable run grep extracts directly.
seed=$(grep -aoE 'bins_linuxarm64_linuxarm64\.zip\.[0-9a-f]+' "${STEAM}/package/${MANIFEST_NAME}.manifest" \
  | grep -v '\.vz\.' | head -n1)
[ -n "$seed" ] || { log "ERROR: no arm64 Steam seed package in manifest" >&2; exit 1; }
log "fetching client seed ${seed}"
curl -fsSL -o "${STEAM}/package/${seed}" "${CDN}/${seed}"
unzip -q -o "${STEAM}/package/${seed}" -d "${STEAM}"

[ -f "${STEAM}/steamrtarm64/steam" ] || { log "ERROR: seed did not install steamrtarm64/steam" >&2; exit 1; }
chmod +x "${STEAM}/steamrtarm64/steam"

# 2. Steam arm64 runtime (sniper/steamrt3 aarch64): the libs the native client links against.
log "fetching arm64 steam runtime"
rt_tar=$(mktemp)
curl -fsSL -o "$rt_tar" "${RUNTIME_URL}"
tar -xJf "$rt_tar" -C "${STEAM}"
rm -f "$rt_tar"

# The native client dlopen()s libibus from a fixed path; symlink it out of the runtime (the exact
# soname version floats, so glob the newest). Mirrors ROCKNIX/Armada — without it Steam aborts.
ibus=$(find "${STEAM}/steam-runtime-steamrt-arm64" \
         -path '*/files/lib/aarch64-linux-gnu/libibus-1.0.so.5.*' -type f 2>/dev/null \
       | sort | tail -n1)
if [ -n "$ibus" ]; then
  mkdir -p "${STEAM}/lib/aarch64-linux-gnu"
  ln -sfn "$ibus" "${STEAM}/lib/aarch64-linux-gnu/libibus-1.0.so.5"
else
  log "WARNING: libibus shim not found in runtime — Steam may fail to start"
fi

# Let Decky (Phase-3 control layer, later) attach to Steam's CEF debugger when present.
touch "${STEAM}/.cef-enable-remote-debugging"

log "done — native arm64 Steam staged; first launch self-updates + downloads the UI"
