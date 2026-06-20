#!/usr/bin/env bash
# novadeck kernel build. Requires an aarch64 build host (or CROSS_COMPILE) + toolchain.
#
# Steps: fetch+verify pinned tarball -> apply patches -> inject device trees ->
# merge config fragment -> build Image.gz + dtbs -> stage for boot packaging.
set -euo pipefail
shopt -s nullglob

SOC="${1:-}"
[ -n "$SOC" ] || { echo "usage: ${0##*/} <soc>" >&2; exit 2; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Per-SoC home: config fragment, out-of-tree patches and device trees all live under
# kernel/<soc>/ since different platforms need different patches and DTs.
SOCDIR="$ROOT/kernel/$SOC"
FRAGMENT="$SOCDIR/${SOC}.config"
# BASE_CONFIG: path to a complete .config to use verbatim (copied in, then olddefconfig).
# When set, the defconfig+fragment merge is skipped entirely — used to build a known-good
# vendor config (e.g. ROCKNIX) exactly as-is rather than as a fragment overlay.
BASE_CONFIG="${BASE_CONFIG:-}"

# Source is pinned in kernel/SOURCE.pin (tarball URL + sha256 = canonical pin).
PIN="$ROOT/kernel/SOURCE.pin"
[ -f "$PIN" ] || { echo "missing pin: $PIN" >&2; exit 1; }
pin() { sed -n "s/^$1:[[:space:]]*//p" "$PIN" | head -1; }
KVER="$(pin version)"; KURL="$(pin url)"; KSHA="$(pin sha256)"
WORK="${WORK:-$ROOT/work/kernel}"
TARBALL="$WORK/linux-${KVER}.tar.xz"

if [ -n "$BASE_CONFIG" ]; then
  echo "[novadeck] SoC=$SOC base-config=$BASE_CONFIG (verbatim) kernel=$KVER"
  [ -f "$BASE_CONFIG" ] || { echo "missing base config: $BASE_CONFIG" >&2; exit 1; }
else
  echo "[novadeck] SoC=$SOC fragment=$FRAGMENT kernel=$KVER"
  [ -f "$FRAGMENT" ] || { echo "missing config fragment: $FRAGMENT" >&2; exit 1; }
fi

# Fetch + verify the pinned tarball (idempotent), then extract a clean tree.
mkdir -p "$WORK"
[ -f "$TARBALL" ] || curl -fSL -o "$TARBALL" "$KURL"
echo "${KSHA}  ${TARBALL}" | sha256sum -c - || { echo "sha256 mismatch — refusing to build" >&2; exit 1; }
SRCDIR="$WORK/linux-${KVER}"
rm -rf "$SRCDIR"
tar -C "$WORK" -xf "$TARBALL"
echo "[novadeck] source ready at $SRCDIR"

# --- Apply out-of-tree patches in lexical order (rename files to reorder) ---
for p in "$SOCDIR"/patches/*.patch; do
  echo "[novadeck] applying $(basename "$p")"
  patch -p1 -d "$SRCDIR" --no-backup-if-mismatch <"$p" \
    || { echo "patch FAILED: $(basename "$p")" >&2; exit 1; }
done

# --- Inject novadeck device trees + register board dtbs in the qcom Makefile ---
QCOM_DTS="$SRCDIR/arch/arm64/boot/dts/qcom"
cp "$SOCDIR"/dts/qcom/*.dtsi "$SOCDIR"/dts/qcom/*.dts "$QCOM_DTS"/
BOARDS=(sm8650-ayaneo-ps2 sm8650-konkr-pf)
for b in "${BOARDS[@]}"; do
  grep -q "${b}\.dtb" "$QCOM_DTS/Makefile" \
    || echo "dtb-\$(CONFIG_ARCH_QCOM) += ${b}.dtb" >> "$QCOM_DTS/Makefile"
done

# --- Stage built-in firmware (CONFIG_EXTRA_FIRMWARE) ---
# Like ROCKNIX, bake the Adreno GPU firmware (+ both boards' signed zap shaders) into the
# Image so the GPU/display stack has its blobs before the SD-card rootfs mounts. The
# config fragment lists these via CONFIG_EXTRA_FIRMWARE with the default
# CONFIG_EXTRA_FIRMWARE_DIR="firmware", so copy them into the kernel tree's firmware/ dir
# under the exact /lib/firmware-relative path the drivers request. Open Adreno blobs come
# from the pinned linux-firmware (firmware/fetch-linux-fw.sh); the per-board zap shaders
# come from the extracted device firmware (firmware/extract.sh).
LFW="$ROOT/firmware/linux-fw/$SOC"
FWX="$ROOT/firmware/extracted/$SOC"
EMBED=(
  "$LFW/qcom/gen70900_aqe.fw"
  "$LFW/qcom/gen70900_sqe.fw"
  "$LFW/qcom/gmu_gen70900.bin"
  "$FWX/qcom/sm8650/ayaneo/ps2/gen70900_zap.mbn"
  "$FWX/qcom/sm8650/konkr/pf/gen70900_zap.mbn"
)
echo "[novadeck] staging built-in firmware (CONFIG_EXTRA_FIRMWARE) into firmware/"
for f in "${EMBED[@]}"; do
  [ -f "$f" ] || {
    echo "missing embed firmware: ${f#"$ROOT"/}" >&2
    echo "  run firmware/fetch-linux-fw.sh $SOC (open blobs) + firmware/extract.sh $SOC <dump> (zap)" >&2
    exit 1
  }
  rel="${f#"$LFW"/}"; rel="${rel#"$FWX"/}"   # path relative to its firmware root = /lib/firmware path
  install -Dm0644 "$f" "$SRCDIR/firmware/$rel"
done

# --- Configure + build ---
# Cross-compile unless the build host is itself aarch64. Default to the standard GNU
# aarch64 prefix when unset, and fail fast if the toolchain is missing — otherwise the
# build silently uses the host gcc and dies deep in with a cryptic '-mlittle-endian'
# error. Override CROSS_COMPILE to use a different toolchain.
if [ "$(uname -m)" != "aarch64" ]; then
  CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
fi
if [ -n "${CROSS_COMPILE:-}" ]; then
  command -v "${CROSS_COMPILE}gcc" >/dev/null 2>&1 || {
    echo "cross compiler not found: ${CROSS_COMPILE}gcc" >&2
    echo "  install the aarch64 toolchain or set CROSS_COMPILE to its prefix" >&2
    exit 1
  }
  echo "[novadeck] cross-compiling with ${CROSS_COMPILE}gcc"
fi
CC=(${CROSS_COMPILE:+CROSS_COMPILE=$CROSS_COMPILE})
( cd "$SRCDIR"
  if [ -n "$BASE_CONFIG" ]; then
    # Verbatim full config: copy it in and let olddefconfig resolve any symbols that
    # differ between the vendor build and this pinned tree (new/removed Kconfig options).
    cp "$BASE_CONFIG" .config
    make ARCH=arm64 "${CC[@]}" olddefconfig
  else
    scripts/kconfig/merge_config.sh -m arch/arm64/configs/defconfig "$FRAGMENT"
    make ARCH=arm64 "${CC[@]}" olddefconfig
  fi
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
