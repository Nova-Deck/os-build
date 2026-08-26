#!/usr/bin/env bash
# novadeck Steam seed fetcher (build host) — stage a COMPLETE native arm64 Steam tree for an OFFLINE bake.
#
# Runs on the build HOST (network + docker required), like the overlay build. Fetches the native arm64
# Steam BOOTSTRAP client + the arm64 SR3 runtime named in steam-seed/STEAM_SEED.pin, then RUNS Steam's
# own updater headless under arm64 qemu emulation (`steam -steamdeck -exitsteam`) so Steam self-installs
# the WHOLE client tree from the CDN AT BUILD TIME and writes its `.installed` manifest. The finished
# `.local/share/Steam` tree is staged into work/steam-seed/; image/make-sdcard.sh pre-seeds it DIRECTLY
# into the /home partition (a ready-to-run home, no first-boot copy and no network). See STEAM_SEED.pin.
#
# WHY run Steam instead of hand-unzipping packages: the seed used to bake a hand-picked SUBSET of the
# manifest and rely on Steam's first-boot self-update (over OOBE Wi-Fi) to complete the tree. Once the
# fetcher started staging the EXACT live build, Steam saw itself as current and stopped self-updating —
# leaving the incomplete offline tree unhealed and no `.installed` present (a seed with no `.installed`
# re-installs on first boot). Running Steam here produces a genuinely COMPLETE, already-installed tree +
# a real `.installed`, so first boot needs zero self-heal and zero network. Steam's updater is x86-free
# but aarch64-only, so we drive it under qemu, like packages/build-overlay.sh — the build host needn't
# be arm64.
#
# Version-aware: re-running resolves the live publicbeta build (a cheap ~12KB manifest GET) AND the live
# runtime snapshot (a one-line GET), and is a no-op only while the staged seed is complete (has
# `.installed`) and matches BOTH; a bump in either (or an incomplete seed) triggers a full restage.
# Delete work/steam-seed to force a refetch. The HOME-relative
# ~/.steam compat symlinks are NOT staged here — make-sdcard.sh creates them against /home/deck.
#
#   steam-seed/fetch-steam-seed.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PIN="$ROOT/steam-seed/STEAM_SEED.pin"
SEED_DIR="$ROOT/work/steam-seed"
CDN="https://client-update.steamstatic.com"
DEVEL_PIN="$ROOT/base-devel.digest"
# Emulated download + unpack of the full client tree is slow; generous ceiling (override via env).
BOOTSTRAP_TIMEOUT="${STEAM_BOOTSTRAP_TIMEOUT:-1800}"

log() { echo "[fetch-steam-seed] $*" >&2; }
pin_field() { sed -n "s/^$1:[[:space:]]*//p" "$PIN" | head -1; }

[ -f "$PIN" ] || { log "missing pin: ${PIN#"$ROOT"/}"; exit 1; }
[ -f "$DEVEL_PIN" ] || { log "no build-env pin: ${DEVEL_PIN#"$ROOT"/}"; exit 1; }
for t in curl unzip tar xz grep docker; do
  command -v "$t" >/dev/null 2>&1 || { log "$t not found on build host"; exit 1; }
done

# base-devel image (arm64) is the throwaway container we run Steam's updater in under qemu — same
# pinned image the overlay build uses. Its digest does NOT affect seed CONTENT (Steam pulls its own
# libs), so it is deliberately not a Makefile content prereq.
DEVEL_REF="$(grep -vE '^[[:space:]]*(#|$)' "$DEVEL_PIN" | tail -1)"
case "$DEVEL_REF" in
  *@sha256:*) ;;
  *) log "refusing unpinned base-devel ref (need ...@sha256:<digest>): '$DEVEL_REF'"; exit 1 ;;
esac

CHANNEL="$(pin_field channel)";                 : "${CHANNEL:?$PIN: missing channel}"
RUNTIME_BASE="$(pin_field runtime_base)";       : "${RUNTIME_BASE:?$PIN: missing runtime_base}"
RUNTIME_CHANNEL="$(pin_field runtime_channel)"; : "${RUNTIME_CHANNEL:?$PIN: missing runtime_channel}"
MANIFEST_NAME="steam_client_${CHANNEL}_linuxarm64"
MANIFEST_URL="${CDN}/${MANIFEST_NAME}"
STAGED_MANIFEST="$SEED_DIR/package/${MANIFEST_NAME}.manifest"
INSTALLED="$SEED_DIR/package/${MANIFEST_NAME}.installed"

# Steam build id out of a saved-or-live manifest (the "version" field is Valve's client build number).
# || true so an absent field yields "" (checked below) instead of tripping set -e / pipefail.
manifest_version() { grep -aoE '"version"[[:space:]]*"[0-9]+"' "$1" | grep -oE '[0-9]+' | head -1 || true; }

# Runtime snapshot ACTUALLY staged, read back off the extracted tree (the tarball unpacks into a
# `steamrt<suite>_platform_<snapshot>/` dir) rather than a stamp file we write — the tree cannot
# desync from itself, and pre-existing seeds are recognised without a gratuitous multi-GB refetch.
# Empty in -> empty out; never fails, so `set -e` can't trip on the assignment.
staged_runtime_snapshot() {
  local d=""
  d="$(find "$SEED_DIR/steam-runtime-steamrt-arm64" -maxdepth 1 -type d -name '*_platform_*' \
       2>/dev/null | sort | tail -1)" || true
  printf '%s' "${d##*_platform_}"
}

# Temp files (single EXIT trap for all — a second trap would replace, not add to, the first).
LIVE_MANIFEST="$(mktemp)"; boot_zip="$(mktemp)"; rt_tar="$(mktemp)"
trap 'rm -f "$LIVE_MANIFEST" "$boot_zip" "$rt_tar"' EXIT

# We DON'T pin a build: BOTH channels are live rolling pointers, so every run resolves the CURRENT
# publicbeta manifest + runtime snapshot and installs whatever Valve publishes now. To stay AWARE of
# silent bumps rather than updating blindly, compare each live id against what is actually staged and
# restage only when one differs (or the seed is incomplete). These two small GETs are the only network
# touches on the skip path; the client tree is downloaded solely when we actually restage.
log "resolving live ${CHANNEL} client build"
curl -fsSL -o "$LIVE_MANIFEST" "$MANIFEST_URL"
LIVE_VERSION="$(manifest_version "$LIVE_MANIFEST")"; : "${LIVE_VERSION:?could not read build id from live manifest}"
STAGED_VERSION=""; [ -f "$STAGED_MANIFEST" ] && STAGED_VERSION="$(manifest_version "$STAGED_MANIFEST")"

# Resolve the runtime channel to a CONCRETE snapshot id and fetch THAT, not the floating alias dir:
# the alias hides which build we baked, and (worse) a runtime bump with no client bump would sail
# through the check below unnoticed. STEAM_RUNTIME_SNAPSHOT=<id> pins one build reproducibly.
if [ -n "${STEAM_RUNTIME_SNAPSHOT:-}" ]; then
  LIVE_SNAPSHOT="$STEAM_RUNTIME_SNAPSHOT"
  log "runtime snapshot pinned via STEAM_RUNTIME_SNAPSHOT: ${LIVE_SNAPSHOT}"
else
  log "resolving live ${RUNTIME_CHANNEL} runtime snapshot"
  LIVE_SNAPSHOT="$(curl -fsSL "${RUNTIME_BASE}/${RUNTIME_CHANNEL}.txt" | tr -d '[:space:]')"
  : "${LIVE_SNAPSHOT:?could not resolve ${RUNTIME_CHANNEL} to a runtime snapshot}"
fi
RUNTIME_URL="${RUNTIME_BASE}/${LIVE_SNAPSHOT}/steam-runtime-steamrt-arm64.tar.xz"
STAGED_SNAPSHOT="$(staged_runtime_snapshot)"

# A seed is COMPLETE only if Steam actually finished a self-install: `.installed` present (else it would
# re-install on first boot) AND steamui.so present (the UI the whole GamepadUI shell renders from). Skip
# only when that holds AND both the installed client build and the staged runtime snapshot match live.
if [ "$STAGED_VERSION" = "$LIVE_VERSION" ] && [ "$STAGED_SNAPSHOT" = "$LIVE_SNAPSHOT" ] \
   && [ -f "$INSTALLED" ] && [ -f "$SEED_DIR/steamrtarm64/steamui.so" ] \
   && [ -x "$SEED_DIR/steamrtarm64/steam" ]; then
  log "seed complete + in sync at Steam build ${LIVE_VERSION}, runtime ${LIVE_SNAPSHOT} — nothing to do (rm -rf work/steam-seed to refetch)"
  exit 0
fi

if [ -n "$STAGED_VERSION" ] && [ "$STAGED_VERSION" != "$LIVE_VERSION" ]; then
  log "Steam build bumped: staged ${STAGED_VERSION} -> live ${LIVE_VERSION}; restaging"
elif [ -n "$STAGED_SNAPSHOT" ] && [ "$STAGED_SNAPSHOT" != "$LIVE_SNAPSHOT" ]; then
  log "runtime snapshot bumped: staged ${STAGED_SNAPSHOT} -> live ${LIVE_SNAPSHOT}; restaging"
else
  log "staging native arm64 Steam seed into ${SEED_DIR#"$ROOT"/} (channel ${CHANNEL}, build ${LIVE_VERSION}, runtime ${LIVE_SNAPSHOT})"
fi
rm -rf "$SEED_DIR"
mkdir -p "$SEED_DIR/package"

# Channel marker so the client tracks an arm64 line (not the x86 default). We write it, but we do not
# OWN it: the client rewrites this file to match the flag it was started with, so it has to already
# agree with the launch flag below (see STEAM_SEED.pin). A disagreement surfaces in the post-install
# gate, which reports the channel the client actually ended on.
echo "${CHANNEL}" >"$SEED_DIR/package/beta"
# Reuse the manifest we already fetched (no second GET); Steam's updater reads it below.
cp "$LIVE_MANIFEST" "$STAGED_MANIFEST"

# 1. Bootstrap client: the ONLY package we hand-fetch. It contains steamrtarm64/steam — the updater we
#    then run so Steam pulls the rest (steamui, codecs, SDL3, CEF, web bundle, movies/sounds, ...) itself
#    and writes `.installed`. Pull the plain (non-vz) zip token out of the (part-binary, hence grep -a)
#    manifest, fetch from the CDN, unpack into the seed root.
boot_tok="$(grep -aoE 'bins_linuxarm64_linuxarm64\.zip\.[0-9a-f]+' "$STAGED_MANIFEST" | grep -v '\.vz\.' | head -n1)"
[ -n "$boot_tok" ] || { log "ERROR: no bootstrap package (bins_linuxarm64_linuxarm64) in manifest"; exit 1; }
log "fetching bootstrap client ${boot_tok}"
curl -fsSL -o "$boot_zip" "${CDN}/${boot_tok}"
cp "$boot_zip" "$SEED_DIR/package/${boot_tok}"
unzip -q -o "$boot_zip" -d "$SEED_DIR"
[ -f "$SEED_DIR/steamrtarm64/steam" ] || { log "ERROR: bootstrap did not install steamrtarm64/steam"; exit 1; }

# Restore exec bits on the bootstrap so steamrtarm64/steam can be launched. Valve's package zips store
# every file 0666 and rely on Steam's updater to set exec bits per its manifest — which is exactly what
# running Steam below does for everything it installs; but the bootstrap steam binary must be executable
# NOW so we can run it. Mark every ELF + *.sh under steamrtarm64 executable (harmless on .so libs).
log "restoring exec bits on the bootstrap steamrtarm64 binaries"
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

# 2. arm64 SR3 runtime (steamrt3 aarch64): the libs the native client links against. NOT part of the
#    client manifest (a separate repo.steampowered.com tarball), so we fetch it ourselves.
log "fetching arm64 steam runtime snapshot ${LIVE_SNAPSHOT}"
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

# 3. Run Steam's updater under arm64 qemu to self-install the COMPLETE tree + write `.installed`.
#    Same emulation path as packages/build-overlay.sh: register binfmt if a probe run fails, then a
#    throwaway --platform linux/arm64 container. Steam runs as an unprivileged builder (mirrors the
#    overlay's builder pattern) with the seed mounted at its $HOME/.local/share/Steam; it needs the
#    network (CDN) and a display (Xvfb). We chown the tree back to the host build user afterward.
if ! docker run --rm --platform linux/arm64 "$DEVEL_REF" /usr/bin/true >/dev/null 2>&1; then
  log "registering arm64 binfmt (qemu) via tonistiigi/binfmt"
  docker run --privileged --rm tonistiigi/binfmt --install arm64 >&2
fi

log "running Steam updater under arm64 qemu to self-install the full tree (slow — emulated + download)"
docker run --rm --platform linux/arm64 \
  -e HOSTUID="$(id -u)" -e HOSTGID="$(id -g)" \
  -e MANIFEST_NAME="$MANIFEST_NAME" -e BOOTSTRAP_TIMEOUT="$BOOTSTRAP_TIMEOUT" \
  -v "$SEED_DIR":/home/builder/.local/share/Steam \
  "$DEVEL_REF" \
  bash -euo pipefail -c '
    useradd -m builder 2>/dev/null || true
    STEAMHOME=/home/builder
    STEAM="$STEAMHOME/.local/share/Steam"
    # X server for the headless updater + the minimal X CLIENT libs the steam binary links (its own
    # runtime libs are front-loaded from steamrtarm64 via LD_LIBRARY_PATH below).
    pacman -Sy --noconfirm --needed xorg-server-xvfb libx11 libxext libxrandr >/dev/null

    # .steam compat symlinks — Steam resolves its install root through these (mirror SteamOS layout).
    install -d "$STEAMHOME/.steam"
    ln -sfn ../.local/share/Steam            "$STEAMHOME/.steam/steam"
    ln -sfn ../.local/share/Steam            "$STEAMHOME/.steam/root"
    ln -sfn ../.local/share/Steam/linuxarm64 "$STEAMHOME/.steam/sdkarm64"
    ln -sfn ../.local/share/Steam/linux32    "$STEAMHOME/.steam/sdk32"
    ln -sfn ../.local/share/Steam/linux64    "$STEAMHOME/.steam/sdk64"
    ln -sfn ../.local/share/Steam/ubuntu12_32 "$STEAMHOME/.steam/bin32"
    ln -sfn ../.local/share/Steam/ubuntu12_64 "$STEAMHOME/.steam/bin64"
    chown -R builder "$STEAMHOME"

    Xvfb :99 -screen 0 1280x800x24 >/tmp/xvfb.log 2>&1 &
    xvfb_pid=$!
    trap "kill $xvfb_pid 2>/dev/null || true" EXIT
    sleep 1

    set +e
    runuser -u builder -- env \
      HOME="$STEAMHOME" DISPLAY=:99 \
      LD_LIBRARY_PATH="$STEAM/steamrtarm64:$STEAM/lib/aarch64-linux-gnu" \
      timeout "$BOOTSTRAP_TIMEOUT" "$STEAM/steamrtarm64/steam" -steamdeck -exitsteam \
      >/tmp/steam.stdout 2>/tmp/steam.stderr
    rc=$?
    set -e
    if [ "$rc" = 124 ]; then
      echo "[fetch-steam-seed] ERROR: Steam updater timed out after ${BOOTSTRAP_TIMEOUT}s" >&2
      tail -n 30 /tmp/steam.stderr >&2 || true
      exit 1
    fi

    INSTALLED="$STEAM/package/${MANIFEST_NAME}.installed"
    if [ ! -f "$STEAM/steamrtarm64/steamui.so" ] || [ ! -f "$INSTALLED" ]; then
      echo "[fetch-steam-seed] ERROR: self-install incomplete (updater rc ${rc}): steamui.so or .installed missing;" >&2
      echo "                        the seed would re-install on first boot." >&2
      # A RENAMED .installed reads exactly like a FAILED one, so say which it is. The client rewrites
      # package/beta to match its launch flag; when that lands on a channel the pin does not name, the
      # install succeeded and only our derived name is wrong (2026-08-19: -deckard moved the client to
      # linux_arm64_beta_* while the pin still said steamdeck_publicbeta).
      echo "                        expected:      package/${MANIFEST_NAME}.installed" >&2
      echo "                        client set beta to: $(cat "$STEAM/package/beta" 2>/dev/null || echo "<none>")" >&2
      echo "                        .installed present: $(ls -1 "$STEAM"/package/*.installed 2>/dev/null | xargs -r -n1 basename | tr "\n" " ")" >&2
      echo "                        (a channel differing from the pin means the launch flag and STEAM_SEED.pin disagree)" >&2
      echo "--- steam stdout (tail) ---" >&2; tail -n 30 /tmp/steam.stdout >&2 || true
      echo "--- steam stderr (tail) ---" >&2; tail -n 30 /tmp/steam.stderr >&2 || true
      exit 1
    fi

    # Strip per-run cruft so only the installed tree is baked (mirror the SteamOS bootstrap cleanup).
    rm -rf "$STEAM/logs" "$STEAM/appcache/httpcache" "$STEAM/appcache/cefdata" "$STEAM/config/htmlcache"
    find "$STEAMHOME" \( -name "*.log" -o -name "*.pid" -o -name "*.token" -o -name "*.crash" \) -delete
    find "$STEAMHOME" \( -type s -o -type p \) -delete
    rm -f "$STEAM/registry.vdf" "$STEAM"/ssfn* \
          "$STEAMHOME/.steam/registry.vdf" "$STEAMHOME/.steam/steam.pid" "$STEAMHOME/.steam/steam.token"

    # Let Decky (Phase-3 control layer, later) attach to the Steam CEF debugger when present.
    touch "$STEAM/.cef-enable-remote-debugging"

    # Hand the fully-installed tree back to the host build user (Steam wrote it as builder).
    chown -R "$HOSTUID:$HOSTGID" "$STEAM"
    echo "[fetch-steam-seed] self-install OK (updater rc ${rc}); .installed + steamui.so present" >&2
  ' >&2

# Host-side sanity: the container guards this, but assert again so a partial mount never slips through.
[ -f "$INSTALLED" ] || { log "ERROR: no ${MANIFEST_NAME}.installed after self-install"; exit 1; }
[ -f "$SEED_DIR/steamrtarm64/steamui.so" ] || { log "ERROR: steamui.so missing after self-install"; exit 1; }

log "done — complete seed staged ($(du -sh "$SEED_DIR" | cut -f1)); Steam build ${LIVE_VERSION}, runtime ${LIVE_SNAPSHOT}; make-sdcard bakes it into /home"
