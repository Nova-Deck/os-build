#!/usr/bin/env bash
# novadeck Steam seed fetcher (build host) — stage the native arm64 Steam SEED for an OFFLINE bake.
#
# Runs on the build HOST (network required), like firmware/fetch-*.sh. Fetches the native arm64
# Steam client seed + the arm64 SR3 runtime named in steam-seed/STEAM_SEED.pin and stages the
# `.local/share/Steam` CONTENTS into work/steam-seed/. That tree is consumed once at image build:
# images/make-sdcard.sh pre-seeds it DIRECTLY into the /home partition (a ready-to-run home, no
# first-boot copy and no network — Steam's OOBE owns Wi-Fi). See steam-seed/STEAM_SEED.pin.
#
# Version-aware: re-running resolves the live publicbeta build (a cheap ~12KB manifest GET) and is a
# no-op only while the staged seed matches it; a bumped build (or an incomplete seed) triggers a
# restage. Delete the dir to force a refetch. The HOME-relative ~/.steam compat symlinks are NOT
# staged here — make-sdcard.sh creates them against /home/deck when it builds the pre-seeded home fs.
#
#   steam-seed/fetch-steam-seed.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PIN="$ROOT/steam-seed/STEAM_SEED.pin"
SEED_DIR="$ROOT/work/steam-seed"
CDN="https://client-update.steamstatic.com"

log() { echo "[fetch-steam-seed] $*" >&2; }
pin_field() { sed -n "s/^$1:[[:space:]]*//p" "$PIN" | head -1; }

[ -f "$PIN" ] || { log "missing pin: ${PIN#"$ROOT"/}"; exit 1; }
for t in curl unzip tar xz grep; do
  command -v "$t" >/dev/null 2>&1 || { log "$t not found on build host"; exit 1; }
done

CHANNEL="$(pin_field channel)";       : "${CHANNEL:?$PIN: missing channel}"
RUNTIME_URL="$(pin_field runtime_url)"; : "${RUNTIME_URL:?$PIN: missing runtime_url}"
MANIFEST_NAME="steam_client_${CHANNEL}_linuxarm64"
MANIFEST_URL="${CDN}/${MANIFEST_NAME}"
STAGED_MANIFEST="$SEED_DIR/package/${MANIFEST_NAME}.manifest"

# Steam build id out of a saved-or-live manifest (the "version" field is Valve's client build number).
# || true so an absent field yields "" (checked below) instead of tripping set -e / pipefail.
manifest_version() { grep -aoE '"version"[[:space:]]*"[0-9]+"' "$1" | grep -oE '[0-9]+' | head -1 || true; }

# Temp files (single EXIT trap for both — a second trap would replace, not add to, the first).
LIVE_MANIFEST="$(mktemp)"; rt_tar="$(mktemp)"
trap 'rm -f "$LIVE_MANIFEST" "$rt_tar"' EXIT

# We DON'T pin a build: the channel is a live rolling pointer, so every run resolves the CURRENT
# publicbeta manifest and uses whatever Valve publishes now. To stay AWARE of silent bumps rather than
# updating blindly, compare the live build id against the one in the staged manifest and restage only
# when they differ (or the seed is incomplete). This manifest GET is the only network touch on the
# skip path; the big zips are pulled solely when we actually restage.
log "resolving live ${CHANNEL} client build"
curl -fsSL -o "$LIVE_MANIFEST" "$MANIFEST_URL"
LIVE_VERSION="$(manifest_version "$LIVE_MANIFEST")"; : "${LIVE_VERSION:?could not read build id from live manifest}"
STAGED_VERSION=""; [ -f "$STAGED_MANIFEST" ] && STAGED_VERSION="$(manifest_version "$STAGED_MANIFEST")"

# Require the client binary AND both of Steam's bundled hard deps (libavutil, libSDL3) AND CEF AND the
# webhelper script to be executable: a stale seed missing any (client but no codecs, no SDL3, no CEF,
# or the pre-exec-bit-fix perms) must re-stage, else steamui.so fails to load / the UI never paints
# offline (see the codecs + sdl3 + webkit fetches and the exec-bit restore below).
if [ "$STAGED_VERSION" = "$LIVE_VERSION" ] \
   && [ -x "$SEED_DIR/steamrtarm64/steam" ] && [ -f "$SEED_DIR/steamrtarm64/libavutil.so.60" ] \
   && [ -f "$SEED_DIR/steamrtarm64/libSDL3.so.0" ] && [ -f "$SEED_DIR/steamrtarm64/libcef.so" ] \
   && [ -d "$SEED_DIR/steamui" ] && [ -x "$SEED_DIR/steamrtarm64/steamwebhelper.sh" ]; then
  log "seed in sync at Steam build ${LIVE_VERSION} — nothing to do (rm -rf to refetch)"
  exit 0
fi

if [ -n "$STAGED_VERSION" ] && [ "$STAGED_VERSION" != "$LIVE_VERSION" ]; then
  log "Steam build bumped: staged ${STAGED_VERSION} -> live ${LIVE_VERSION}; restaging"
else
  log "staging native arm64 Steam seed into ${SEED_DIR#"$ROOT"/} (channel ${CHANNEL}, build ${LIVE_VERSION})"
fi
rm -rf "$SEED_DIR"
mkdir -p "$SEED_DIR/package"

# Channel marker so the client tracks the arm64 publicbeta line (not the x86 default).
echo "${CHANNEL}" >"$SEED_DIR/package/beta"
# Reuse the manifest we already fetched (no second GET); fetch_pkg reads its tokens below.
cp "$LIVE_MANIFEST" "$STAGED_MANIFEST"

# 1. Client + media seed: fetch + unpack two NAMED packages out of the publicbeta manifest.
#  - bins_linuxarm64_linuxarm64: the bootstrap client itself (steamrtarm64/steam, steamui.so,
#    libvideo.so).
#  - codecs_linuxarm64_linuxarm64: Steam's OWN native-arm64 ffmpeg (-> steamrtarm64/libav*.so* +
#    libvpx). steamui.so -> libvideo.so NEEDs av_malloc_tracked@LIBAVUTIL_60 (+ LIBAVCODEC/FILTER/
#    FORMAT) — a Valve downstream patch the stock holo ffmpeg does NOT export, so without these
#    libvideo.so resolves the system libavutil.so.60, hits "undefined symbol: av_malloc_tracked", and
#    steamui.so fails to load. Normally Steam's first-launch self-update pulls them, but a release
#    unit has no network before Steam's OOBE — so bake them. The launcher front-loads steamrtarm64 on
#    LD_LIBRARY_PATH, so these win over the system ffmpeg.
#  - sdl3_linuxarm64_linuxarm64: Steam's OWN native-arm64 SDL3 (-> steamrtarm64/libSDL3.so.0 +
#    libSDL3_ttf/_image). steamui.so NEEDs SDL_TryLockJoysticks@SDL3_0.0.0 — newer than the SDL3 the
#    SR3 runtime ships (libSDL3.so.0.4.8 has Lock/UnlockJoysticks but NOT TryLock), and newer than the
#    holo system libSDL3. Without this, "dlmopen steamui.so failed: undefined symbol:
#    SDL_TryLockJoysticks" -> "Fatal error: Failed to load steamui.so" and the UI never paints. Same
#    offline gap as the codecs: Steam's self-update would pull it, but a release unit has no network
#    pre-OOBE. Front-loaded steamrtarm64 wins over both the runtime and system SDL3.
#  - webkit_linuxarm64_linuxarm64: Steam's CEF (Chromium Embedded Framework) -> steamrtarm64/
#    libcef.so (~218M) + cefsimple + ANGLE (libEGL/libGLESv2) + resources.pak/locales/snapshot_blob.
#    The ENTIRE GamepadUI renders in CEF via steamwebhelper, so without libcef.so the helper dies on
#    "error while loading shared libraries: libcef.so: cannot open shared object file", steamui loops
#    "Restart webhelper process" / "Failed creating offscreen shared JS context", and nothing paints.
#    CEF is the SHELL, not a download-later asset — the OOBE/Wi-Fi screens are themselves CEF — so it
#    must be baked like steamui.so/SDL3 (corrects the earlier "webkit comes over network" assumption).
# 2. UI content: the GamepadUI itself is a CEF web app. steamui_websrc_all unpacks the steamui/
#    bundle (*.js/css/images/localization) the webhelper browser navigates to; without it CEF comes
#    up "BrowserReady" but renders a BLANK page (no steamui/ dir, no network pre-OOBE) -> no UI.
#    public_all/resources_all/resource_*/strings_* + tenfoot_images_all carry the shared images,
#    strings and tenfoot art the bundle references. Like CEF, this is the SHELL the real Deck recovery
#    image SHIPS — only games/updates stream later — so it is baked, not downloaded in OOBE (~75M zips,
#    far below the reverted full-tree bake). Boot videos/sounds (steamui_websrc_movies/sounds_all) are
#    eye-candy, intentionally NOT baked. These unpack at the Steam root (not steamrtarm64/), so the
#    exec-bit restore below does not touch them.
# fetch_pkg <name> <label>: pull the plain (non-vz) zip token for an exact package out of the
# (part-binary, hence grep -a) manifest, fetch from the CDN, unpack into the seed root.
fetch_pkg() {
  pkg_name="$1"; pkg_label="$2"
  tok="$(grep -aoE "${pkg_name}\.zip\.[0-9a-f]+" \
    "$SEED_DIR/package/${MANIFEST_NAME}.manifest" | grep -v '\.vz\.' | head -n1)"
  [ -n "$tok" ] || { log "ERROR: no ${pkg_label} package (${pkg_name}) in manifest"; exit 1; }
  log "fetching ${pkg_label} ${tok}"
  curl -fsSL -o "$SEED_DIR/package/${tok}" "${CDN}/${tok}"
  unzip -q -o "$SEED_DIR/package/${tok}" -d "$SEED_DIR"
}

# Shell .so/runtime stack (unpacks into steamrtarm64/).
fetch_pkg bins_linuxarm64_linuxarm64   'client seed'
fetch_pkg codecs_linuxarm64_linuxarm64 'media codecs (ffmpeg)'
fetch_pkg sdl3_linuxarm64_linuxarm64   'SDL3'
fetch_pkg webkit_linuxarm64_linuxarm64 'CEF (webkit)'
# GamepadUI web content (unpacks at the Steam root: steamui/, public/, resource/, ...).
fetch_pkg steamui_websrc_all           'GamepadUI web bundle'
fetch_pkg public_all                   'shared public resources'
fetch_pkg resources_all                'UI resources'
fetch_pkg strings_all                  'UI strings'
fetch_pkg strings_en_all               'UI strings (en)'
fetch_pkg tenfoot_images_all           'tenfoot images'
[ -f "$SEED_DIR/steamrtarm64/steam" ] || { log "ERROR: seed did not install steamrtarm64/steam"; exit 1; }
[ -f "$SEED_DIR/steamrtarm64/libavutil.so.60" ] || { log "ERROR: codecs did not install steamrtarm64/libavutil.so.60"; exit 1; }
[ -f "$SEED_DIR/steamrtarm64/libSDL3.so.0" ] || { log "ERROR: sdl3 did not install steamrtarm64/libSDL3.so.0"; exit 1; }
[ -f "$SEED_DIR/steamrtarm64/libcef.so" ] || { log "ERROR: webkit did not install steamrtarm64/libcef.so"; exit 1; }
[ -d "$SEED_DIR/steamui" ] || { log "ERROR: steamui_websrc did not install the steamui/ web bundle"; exit 1; }

# Restore exec bits. Valve's package zips store EVERY file as 0666 and rely on Steam's own updater to
# set the exec bit per its manifest — which we bypass by unzip'ing the seed offline. So unzip leaves
# steam, steamwebhelper(.sh), reaper, gldriverquery, etc. non-executable; Steam then loops forever on
# "steamwebhelper.sh: Permission denied" (no CEF -> "Failed creating offscreen shared JS context" ->
# no UI). Mark every ELF + *.sh under steamrtarm64 executable (harmless on the .so libs, which are
# dlopen'd not exec'd). The SR3 runtime arrives as a tar.xz (modes preserved), so only the unzip'd
# steamrtarm64/ needs this.
log "restoring exec bits on unzip'd steamrtarm64 binaries"
# ELF magic compared via cmp (not $(head ...)) so binary null bytes don't trip the shell's
# "ignored null byte in command substitution" warning on non-ELF data files (.pak/.vdf).
elf_magic="$(printf '\177ELF')"
while IFS= read -r -d '' f; do
  case "$f" in
    *.sh) chmod +x "$f"; continue;;
  esac
  if printf '%s' "$elf_magic" | cmp -s -n 4 - "$f"; then chmod +x "$f"; fi
done < <(find "$SEED_DIR/steamrtarm64" -maxdepth 1 -type f -print0)
[ -x "$SEED_DIR/steamrtarm64/steam" ] || { log "ERROR: steam not executable after chmod"; exit 1; }
[ -x "$SEED_DIR/steamrtarm64/steamwebhelper.sh" ] || { log "ERROR: steamwebhelper.sh not executable after chmod"; exit 1; }

# 2. arm64 SR3 runtime (steamrt3 aarch64): the libs the native client links against.
log "fetching arm64 steam runtime"
curl -fsSL -o "$rt_tar" "$RUNTIME_URL"
tar -xJf "$rt_tar" -C "$SEED_DIR"

# The native client dlopen()s libibus from a fixed path; symlink it out of the runtime (the exact
# soname version floats, so glob the newest). Without it Steam aborts.
ibus="$(find "$SEED_DIR/steam-runtime-steamrt-arm64" \
          -path '*/files/lib/aarch64-linux-gnu/libibus-1.0.so.5.*' -type f 2>/dev/null \
        | sort | tail -n1)"
if [ -n "$ibus" ]; then
  mkdir -p "$SEED_DIR/lib/aarch64-linux-gnu"
  # Relative target so the symlink stays valid after the seed is copied into /home/deck.
  ln -sfn "../../steam-runtime-steamrt-arm64/${ibus#"$SEED_DIR/steam-runtime-steamrt-arm64/"}" \
     "$SEED_DIR/lib/aarch64-linux-gnu/libibus-1.0.so.5"
else
  log "WARNING: libibus shim not found in runtime — Steam may fail to start"
fi

# Let Decky (Phase-3 control layer, later) attach to Steam's CEF debugger when present.
touch "$SEED_DIR/.cef-enable-remote-debugging"

log "done — seed staged ($(du -sh "$SEED_DIR" | cut -f1)); assemble-rootfs bakes it into the RO root"
