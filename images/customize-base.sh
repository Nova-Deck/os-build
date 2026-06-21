#!/usr/bin/env bash
# novadeck base customization — install the RELEASE runtime into the aarch64 base.
#
# The upstream holo-core base is minimal: no Wi-Fi supplicant, no SSH server, no
# Vulkan/Mesa userspace. This layers the runtime that ships in every build —
#   wpa_supplicant   Wi-Fi WPA auth (systemd-networkd does the DHCP)
#   openssh          SSH server (dropbear isn't in the pinned holo repo)
#   wireless-regdb   regulatory database — REQUIRED for 5 GHz (else channels are no-TX)
#   mesa + vulkan-freedreno (Turnip) + vulkan-tools   GPU / Vulkan
# Runtime deps of precompiled packages (e.g. libiio for InputPlumber) are NOT hardcoded here —
# each packages/<name>/prebuilt.pin declares its own `deps:`, aggregated into the install list.
# — by running the pinned base under arm64 emulation and pacman-installing from the
# holo repo, then exporting the augmented rootfs to work/base/<soc> (the directory
# images/assemble-rootfs.sh consumes).
#
# Components NOT in the holo repo (e.g. InputPlumber, the handheld input daemon) ship as
# precompiled-package PINS: each packages/<name>/prebuilt.pin declares a tarball by
# url + sha256 (+ tar strip-components). They are fetched + verified on the host and
# extracted into the base here; add one by dropping a new pin file — no code change.
# Per-component config / service enablement (if any) is injected later by assemble-rootfs.sh.
#
# This installs PACKAGES only — it writes NO network/SSH config and enables NO services.
# First-boot networking is the SteamOS UI's responsibility on release. All Wi-Fi/SSH
# scaffolding (.link/.network, regdom, wpa creds, sshd + host keys, enable-symlinks) is a
# TEST-ONLY injection done later by assemble-rootfs.sh under NOVADECK_TEST=1 (see it).
#
# Unlike fetch-base.sh (a file copy, no qemu), this EXECUTES arm64 userspace, so it
# needs qemu binfmt — registered on demand via tonistiigi/binfmt. Network required.
#
#   images/customize-base.sh <soc>
#
# Prints the exported rootfs path on stdout (like fetch-base.sh). FORCE=1 re-runs.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOC="${1:-}"
[ -n "$SOC" ] || { echo "usage: ${0##*/} <soc>" >&2; exit 2; }
PINFILE="$ROOT/base.digest"
DEST="$ROOT/work/base/$SOC"

# Release runtime packages — credentials are NEVER installed here (test-only at assemble).
PKGS=(wpa_supplicant wireless-regdb openssh vulkan-icd-loader vulkan-freedreno vulkan-tools mesa)

# Test-only packages — installed ONLY under NOVADECK_TEST=1, NEVER in a release base.
# On-device bring-up tools; evtest reads raw /dev/input events to verify the gamepad.
TEST_PKGS=(evtest)

# Precompiled external packages: every packages/<name>/prebuilt.pin (url + sha256 + strip)
# is fetched on the host and extracted into the base. PREBUILT_DIR stages the verified
# tarballs + a manifest; the manifest is also stored in the base as the reuse cache key.
PREBUILT_DIR="$ROOT/work/prebuilt"
PREBUILT_PINS=("$ROOT"/packages/*/prebuilt.pin)
pin_field() { sed -n "s/^$2:[[:space:]]*//p" "$1" | head -1; }
# "name sha256 strip deps..." per pin, sorted — identifies exactly which prebuilts a base
# carries AND the holo-repo runtime deps they declare, so a deps change also busts the reuse
# cache. The container reads only the first three fields for extraction; trailing deps tokens
# are captured into a throwaway var there (see the extraction loop), never used as a tar path.
prebuilt_manifest() {
  local pin
  for pin in "${PREBUILT_PINS[@]}"; do
    [ -e "$pin" ] || continue
    printf '%s %s %s %s\n' "$(pin_field "$pin" name)" "$(pin_field "$pin" sha256)" \
                           "$(pin_field "$pin" strip)" "$(pin_field "$pin" deps)"
  done | sort
}
EXPECTED_MANIFEST="$(prebuilt_manifest)"

# Aggregate the holo-repo runtime deps each prebuilt declares (deps: in its pin). They ship in
# every base that carries the prebuilt (release), so they extend the release install list —
# e.g. InputPlumber links libiio.so.0, declared `deps: libiio` in its pin, not hardcoded above.
PREBUILT_DEPS=()
for pin in "${PREBUILT_PINS[@]}"; do
  [ -e "$pin" ] || continue
  pin_deps="$(pin_field "$pin" deps)"
  if [ -n "$pin_deps" ]; then PREBUILT_DEPS+=($pin_deps); fi   # word-split: deps is space-separated
done

# Test packages change the base contents, so the reuse cache must tell a test base apart
# from a release one — else evtest leaks into a release base, or is missing from a test
# rebuild. Track that with a SEPARATE marker file (/usr/lib/novadeck/test-pkgs): the
# prebuilt.manifest must stay pure because the container also reads it as the tar-extraction
# list, so a non-prebuilt line there would break extraction.
INSTALL_PKGS=("${PKGS[@]}" "${PREBUILT_DEPS[@]}")
EXPECTED_TESTPKGS=""
if [ "${NOVADECK_TEST:-}" = "1" ]; then
  INSTALL_PKGS+=("${TEST_PKGS[@]}")
  EXPECTED_TESTPKGS="${TEST_PKGS[*]}"
fi

[ -f "$PINFILE" ] || { echo "no base pin: $PINFILE" >&2; exit 1; }
# Pin = last non-comment, non-blank line: an image ref ending in @sha256:<digest>.
REF="$(grep -vE '^[[:space:]]*(#|$)' "$PINFILE" | tail -1)"
case "$REF" in
  *@sha256:*) ;;
  *) echo "refusing unpinned base ref (need ...@sha256:<digest>): '$REF'" >&2; exit 1 ;;
esac
command -v docker >/dev/null 2>&1 || { echo "docker required for base customization" >&2; exit 1; }

# Already customized? Reuse unless FORCE=1 (the emulated pacman run is slow). The stored
# prebuilt manifest must match the current pins, else a pin bump/add would be silently missed.
if [ -z "${FORCE:-}" ] && [ -f "$DEST/usr/bin/sshd" ] && [ -f "$DEST/usr/lib/firmware/regulatory.db" ] \
   && [ "$(cat "$DEST/usr/lib/novadeck/prebuilt.manifest" 2>/dev/null)" = "$EXPECTED_MANIFEST" ] \
   && [ "$(cat "$DEST/usr/lib/novadeck/test-pkgs" 2>/dev/null)" = "$EXPECTED_TESTPKGS" ]; then
  echo "[novadeck] customized base present: ${DEST#"$ROOT"/} (FORCE=1 to rebuild)" >&2
  echo "$DEST"; exit 0
fi

echo "[novadeck] pulling pinned base: $REF" >&2
docker pull "$REF" >&2

# Ensure arm64 binfmt is registered so the base's own pacman runs under emulation.
if ! docker run --rm --platform linux/arm64 "$REF" /usr/bin/true >/dev/null 2>&1; then
  echo "[novadeck] registering arm64 binfmt (qemu) via tonistiigi/binfmt" >&2
  docker run --privileged --rm tonistiigi/binfmt --install arm64 >&2
fi

# Fetch + verify every pinned prebuilt on the host (network here); staged into PREBUILT_DIR,
# mounted read-only into the customization container below so they land in the exported base.
rm -rf "$PREBUILT_DIR"; mkdir -p "$PREBUILT_DIR"
for pin in "${PREBUILT_PINS[@]}"; do
  [ -e "$pin" ] || continue
  name="$(pin_field "$pin" name)"; ver="$(pin_field "$pin" version)"
  url="$(pin_field "$pin" url)";  sha="$(pin_field "$pin" sha256)"
  : "${name:?$pin: missing name}"; : "${url:?$pin: missing url}"; : "${sha:?$pin: missing sha256}"
  echo "[novadeck] fetching prebuilt $name $ver: $url" >&2
  curl -fsSL "$url" -o "$PREBUILT_DIR/$name.tar.gz"
  echo "$sha  $PREBUILT_DIR/$name.tar.gz" | sha256sum -c - \
    || { echo "$name sha256 mismatch — refusing" >&2; exit 1; }
done
printf '%s\n' "$EXPECTED_MANIFEST" >"$PREBUILT_DIR/prebuilt.manifest"
# Test-package marker (reuse-cache key only; NOT a tar list) — empty string for release.
printf '%s' "$EXPECTED_TESTPKGS" >"$PREBUILT_DIR/test-pkgs"

cid="nova-custom-$SOC-$$"
trap 'docker rm -f "$cid" >/dev/null 2>&1 || true' EXIT

echo "[novadeck] installing runtime under arm64: ${INSTALL_PKGS[*]}" >&2
docker run --name "$cid" --platform linux/arm64 -v "$PREBUILT_DIR":/prebuilt:ro "$REF" \
  bash -euo pipefail -c '
  pacman -Sy --noconfirm --needed --disable-download-timeout '"${INSTALL_PKGS[*]}"'

  # Precompiled external packages staged + verified by the host (packages/*/prebuilt.pin):
  # extract each into the rootfs with its pinned strip-components, then record the manifest
  # in the base so the host reuse-check detects pin changes. Archive roots differ, so strip
  # is per-package (InputPlumber is rooted at inputplumber/usr -> strip 1 lands at /usr).
  if [ -s /prebuilt/prebuilt.manifest ]; then
    while read -r p_name p_sha p_strip p_deps; do
      [ -n "$p_name" ] || continue
      : "${p_deps:-}"  # deps are pacman-installed via the host INSTALL_PKGS list, not here
      tar -C / --strip-components="${p_strip:-0}" -xzf "/prebuilt/$p_name.tar.gz"
    done < /prebuilt/prebuilt.manifest
    install -Dm0644 /prebuilt/prebuilt.manifest /usr/lib/novadeck/prebuilt.manifest
  fi
  # Record the test-package marker (empty for release) so the host reuse-check can tell a
  # test base from a release one without re-running the slow emulated pacman.
  install -Dm0644 /prebuilt/test-pkgs /usr/lib/novadeck/test-pkgs

  # Release base ships the runtime PACKAGES only — no network/SSH config or service
  # enablement. First-boot networking is the SteamOS UI'\''s responsibility; all Wi-Fi/SSH
  # scaffolding (.link/.network, regdom, wpa creds, sshd + host keys, enable-symlinks) is
  # injected test-only by images/assemble-rootfs.sh under NOVADECK_TEST=1.

  # Headless-boot fix (GENERAL, not network/test): the image ships an empty /etc/machine-id
  # (ConditionFirstBoot=yes), so systemd-firstboot.service runs and, with console=tty0 and no
  # usable console input, prompts for locale/root-password and blocks sysinit.target forever
  # — the device never reaches multi-user. (systemd.firstboot=off on the cmdline only disables
  # PID1'\''s builtin query, NOT this unit.) Mask it; machine-id is still generated on first
  # boot and preset-all still runs, so service enablement is unaffected.
  ln -sf /dev/null /etc/systemd/system/systemd-firstboot.service

  pacman -Scc --noconfirm >/dev/null 2>&1 || true
' >&2
# ^ redirect the container'\''s stdout (pacman progress) to stderr: this script'\''s stdout must
#   carry ONLY the exported rootfs path (echo "$DEST" below), which build-image.sh captures.

echo "[novadeck] exporting customized base -> ${DEST#"$ROOT"/}" >&2
# Extract AS ROOT inside a container so the base tree keeps the image's real ownership
# (root + service users). A host-side `tar -x` runs as the unprivileged build user and
# squashes the whole tree to that uid — which makes sshd refuse its non-root privsep dir
# (/usr/share/empty.sshd) and is wrong for everything else too. Remove any prior export as
# root as well (after this fix it is root-owned, so the build user can't unlink it).
mkdir -p "$ROOT/work/base"
docker run --rm -v "$ROOT/work/base":/wb "$REF" rm -rf "/wb/$SOC"
mkdir -p "$DEST"
docker export "$cid" | docker run --rm -i -v "$DEST":/dest "$REF" \
  tar -C /dest --numeric-owner -xf -

echo "[novadeck] customized base ready ($(du -sh "$DEST" | cut -f1) at ${DEST#"$ROOT"/})" >&2
echo "$DEST"
