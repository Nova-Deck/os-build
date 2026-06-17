#!/usr/bin/env bash
# novadeck kernel build — Phase 1 scaffold (NOT yet runnable end-to-end).
#
# Builds an arm64 kernel for a target SoC: clone pinned source, apply patches,
# merge the per-SoC config fragment, build Image + dtbs.
set -euo pipefail

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

# Fetch + verify the pinned tarball (idempotent).
mkdir -p "$WORK"
[ -f "$TARBALL" ] || curl -fSL -o "$TARBALL" "$KURL"
echo "${KSHA}  ${TARBALL}" | sha256sum -c - || { echo "sha256 mismatch — refusing to build" >&2; exit 1; }
tar -C "$WORK" -xf "$TARBALL"
SRCDIR="$WORK/linux-${KVER}"

echo "[novadeck] source ready at $SRCDIR"
echo "TODO(Phase 1): apply patches from kernel/patches/"
echo "TODO(Phase 1): merge_config.sh defconfig $FRAGMENT"
echo "TODO(Phase 1): make ARCH=arm64 CROSS_COMPILE=... Image.gz dtbs modules"
echo "TODO(Phase 1): stage Image.gz + qcom/${SOC}-*.dtb for boot/ packaging (Phase 5)"
exit 0
