#!/usr/bin/env bash
# novadeck Steam seed fetcher (build host) — stage the native arm64 Steam SEED for an OFFLINE bake.
#
# Runs on the build HOST (network required), like firmware/fetch-*.sh. Fetches the native arm64
# Steam client seed + the arm64 SR3 runtime named in steam/STEAM_SEED.pin and stages the
# `.local/share/Steam` CONTENTS into work/steam-seed/. images/assemble-rootfs.sh then bakes that dir
# into the sealed RO root at /usr/share/novadeck/steam-seed/; the first-boot seeder copies it into
# the writable /home/deck with NO network (Steam's OOBE owns Wi-Fi). This is the build-time half of
# what steam-bootstrap.sh used to do at first boot — moved offline. See steam/STEAM_SEED.pin.
#
# Idempotent: re-running is a no-op once work/steam-seed/steamrtarm64/steam is present (delete the
# dir to refetch). The HOME-relative ~/.steam compat symlinks are NOT staged here — they are
# created against /home/deck by the first-boot seeder, not the bake path.
#
#   steam/fetch-steam-seed.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PIN="$ROOT/steam/STEAM_SEED.pin"
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

if [ -x "$SEED_DIR/steamrtarm64/steam" ]; then
  log "seed already staged at ${SEED_DIR#"$ROOT"/} — nothing to do (rm -rf to refetch)"
  exit 0
fi

log "staging native arm64 Steam seed into ${SEED_DIR#"$ROOT"/} (channel ${CHANNEL})"
rm -rf "$SEED_DIR"
mkdir -p "$SEED_DIR/package"

# Channel marker so the client tracks the arm64 publicbeta line (not the x86 default).
echo "${CHANNEL}" >"$SEED_DIR/package/beta"

# 1. Client seed: parse the arm64 bins package out of the publicbeta manifest, fetch + unpack.
log "fetching client manifest"
curl -fsSL -o "$SEED_DIR/package/${MANIFEST_NAME}.manifest" "$MANIFEST_URL"
# grep -a (treat the part-binary VDF manifest as text): the seed token is a plain printable run.
seed="$(grep -aoE 'bins_linuxarm64_linuxarm64\.zip\.[0-9a-f]+' \
  "$SEED_DIR/package/${MANIFEST_NAME}.manifest" | grep -v '\.vz\.' | head -n1)"
[ -n "$seed" ] || { log "ERROR: no arm64 Steam seed package in manifest"; exit 1; }
log "fetching client seed ${seed}"
curl -fsSL -o "$SEED_DIR/package/${seed}" "${CDN}/${seed}"
unzip -q -o "$SEED_DIR/package/${seed}" -d "$SEED_DIR"
[ -f "$SEED_DIR/steamrtarm64/steam" ] || { log "ERROR: seed did not install steamrtarm64/steam"; exit 1; }
chmod +x "$SEED_DIR/steamrtarm64/steam"

# 2. arm64 SR3 runtime (steamrt3 aarch64): the libs the native client links against.
log "fetching arm64 steam runtime"
rt_tar="$(mktemp)"; trap 'rm -f "$rt_tar"' EXIT
curl -fsSL -o "$rt_tar" "$RUNTIME_URL"
tar -xJf "$rt_tar" -C "$SEED_DIR"

# The native client dlopen()s libibus from a fixed path; symlink it out of the runtime (the exact
# soname version floats, so glob the newest). Mirrors ROCKNIX/Armada — without it Steam aborts.
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
