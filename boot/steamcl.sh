#!/usr/bin/env bash
# novadeck steamos-efi (stage-1 steamcl) build.
#
# Builds Valve's stage-1 bootloader for aarch64 from the pinned source: steamcl.efi (the PE32+ that
# ABL chainloads as \EFI\BOOT\bootaa64.efi) plus holo-bootconf, the boot-state reader the OS side
# installs as /usr/bin/steamos-bootconf. Emits:
#   out/boot/{steamcl.efi, holo-bootconf, steamcl-version, fonts/default.pf2}
#
#   boot/steamcl.sh
#
# Run inside the build image (needs the arm64 toolchain, gnu-efi:arm64, the autotools, fontconfig
# and grub-mkfont — see build/Dockerfile):
#   docker run --rm -v "$PWD":/src -w /src novadeck-build boot/steamcl.sh
set -euo pipefail
shopt -s nullglob

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/out/boot"
WORK="${WORK:-$ROOT/work/steamos-efi}"
mkdir -p "$OUT" "$WORK"

# Source is pinned in boot/steamos-efi.pin (tarball URL + sha256 = canonical pin).
PIN="$ROOT/boot/steamos-efi.pin"
[ -f "$PIN" ] || { echo "missing pin: $PIN" >&2; exit 1; }
pin() { sed -n "s/^$1:[[:space:]]*//p" "$PIN" | head -1; }
SEVER="$(pin version)"; SEURL="$(pin url)"; SESHA="$(pin sha256)"; SECOMMIT="$(pin git_commit)"
TARBALL="$WORK/steamos-efi-${SEVER}.tar.gz"

# --with-release-version is baked into steamcl.efi and reported by `steamcl-version`, so it decides
# whether two builds of the same source produce the same bytes. It is derived from the PIN, never
# from the clock: a datestamp here would make every build a different binary, which in turn would
# make the RAUC post-install hook rewrite the ESP's live boot files on every single update (it
# skips the copy when the content is identical) for no change at all.
RELEASE="${RELEASE_VERSION:-novadeck-${SEVER}-${SECOMMIT:0:12}}"

[ -f "$TARBALL" ] || curl -fSL -o "$TARBALL" "$SEURL"
echo "${SESHA}  ${TARBALL}" | sha256sum -c - || { echo "sha256 mismatch — refusing to build" >&2; exit 1; }

SRCDIR="$WORK/src"
rm -rf "$SRCDIR"
mkdir -p "$SRCDIR"
tar -C "$SRCDIR" --strip-components=1 -xf "$TARBALL"

echo "[steamcl] building steamos-efi $SEVER ($RELEASE)"
cd "$SRCDIR"
autoreconf -ivf
./configure --host=aarch64-linux-gnu --prefix=/usr --with-release-version="$RELEASE"
make -j"$(nproc)"

echo "[steamcl] staging boot artifacts"
install -Dm0755 steamcl.efi "$OUT/steamcl.efi"
install -Dm0755 holo-bootconf "$OUT/holo-bootconf"
install -Dm0644 data/steamcl-version "$OUT/steamcl-version"
install -Dm0644 fonts/default.pf2 "$OUT/fonts/default.pf2"

file steamcl.efi holo-bootconf
file steamcl.efi | grep -q "ARM64" || { echo "steamcl.efi not ARM64" >&2; exit 1; }
file holo-bootconf | grep -q "statically linked" || { echo "holo-bootconf not static" >&2; exit 1; }
echo "[steamcl] done -> $OUT"
