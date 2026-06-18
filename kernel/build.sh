#!/usr/bin/env bash
# novadeck kernel build. Requires an aarch64 build host (or CROSS_COMPILE) + toolchain.
#
# Steps: fetch+verify pinned tarball -> apply patches -> inject device trees ->
# merge config fragment -> build Image.gz + dtbs -> stage for boot packaging.
set -euo pipefail
shopt -s nullglob

SOC="${1:-sm8650}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FRAGMENT="$ROOT/kernel/config/${SOC}.config"

# Source is pinned in kernel/SOURCE.pin (tarball URL + sha256 = canonical pin).
PIN="$ROOT/kernel/SOURCE.pin"
[ -f "$PIN" ] || { echo "missing pin: $PIN" >&2; exit 1; }
pin() { sed -n "s/^$1:[[:space:]]*//p" "$PIN" | head -1; }
KVER="$(pin version)"; KURL="$(pin url)"; KSHA="$(pin sha256)"
WORK="${WORK:-$ROOT/work/kernel}"
TARBALL="$WORK/linux-${KVER}.tar.xz"

echo "[novadeck] SoC=$SOC fragment=$FRAGMENT kernel=$KVER"
[ -f "$FRAGMENT" ] || { echo "missing config fragment: $FRAGMENT" >&2; exit 1; }

# Fetch + verify the pinned tarball (idempotent), then extract a clean tree.
mkdir -p "$WORK"
[ -f "$TARBALL" ] || curl -fSL -o "$TARBALL" "$KURL"
echo "${KSHA}  ${TARBALL}" | sha256sum -c - || { echo "sha256 mismatch — refusing to build" >&2; exit 1; }
SRCDIR="$WORK/linux-${KVER}"
rm -rf "$SRCDIR"
tar -C "$WORK" -xf "$TARBALL"
echo "[novadeck] source ready at $SRCDIR"

# --- Apply out-of-tree patches in lexical order (rename files to reorder) ---
for p in "$ROOT"/kernel/patches/*.patch; do
  echo "[novadeck] applying $(basename "$p")"
  patch -p1 -d "$SRCDIR" --no-backup-if-mismatch <"$p" \
    || { echo "patch FAILED: $(basename "$p")" >&2; exit 1; }
done

# --- Inject novadeck device trees + register board dtbs in the qcom Makefile ---
QCOM_DTS="$SRCDIR/arch/arm64/boot/dts/qcom"
cp "$ROOT"/kernel/dts/qcom/*.dtsi "$ROOT"/kernel/dts/qcom/*.dts "$QCOM_DTS"/
BOARDS=(sm8650-ayaneo-ps2 sm8650-konkr-pf)
for b in "${BOARDS[@]}"; do
  grep -q "${b}\.dtb" "$QCOM_DTS/Makefile" \
    || echo "dtb-\$(CONFIG_ARCH_QCOM) += ${b}.dtb" >> "$QCOM_DTS/Makefile"
done

# --- Configure + build ---
CC=(${CROSS_COMPILE:+CROSS_COMPILE=$CROSS_COMPILE})
( cd "$SRCDIR"
  scripts/kconfig/merge_config.sh -m arch/arm64/configs/defconfig "$FRAGMENT"
  make ARCH=arm64 "${CC[@]}" olddefconfig
  make ARCH=arm64 "${CC[@]}" -j"$(nproc)" Image.gz dtbs modules
)

# --- Stage artifacts for boot packaging (Phase 5) ---
OUT="$ROOT/out/$SOC"; mkdir -p "$OUT/dtbs"
cp "$SRCDIR/arch/arm64/boot/Image.gz" "$OUT/"
for b in "${BOARDS[@]}"; do cp "$QCOM_DTS/${b}.dtb" "$OUT/dtbs/"; done

# Install loadable modules into a staging tree consumed by images/assemble-rootfs.sh.
# INSTALL_MOD_PATH yields a self-contained /lib/modules/<kver> (with depmod metadata)
# and never writes the host's /lib. The =m drivers (e.g. handheld panels needed for
# display bring-up) live here. Drop the build/source symlinks — they point back into
# this throwaway source tree and would dangle in the rootfs.
MODROOT="$OUT/modroot"
rm -rf "$MODROOT"
( cd "$SRCDIR"
  make ARCH=arm64 "${CC[@]}" INSTALL_MOD_PATH="$MODROOT" INSTALL_MOD_STRIP=1 modules_install
)
find "$MODROOT/lib/modules" -maxdepth 2 -type l \( -name build -o -name source \) -delete
echo "[novadeck] staged Image.gz + ${#BOARDS[@]} dtbs + modules in $OUT"
