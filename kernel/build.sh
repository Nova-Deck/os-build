#!/usr/bin/env bash
# novadeck kernel build — Phase 1 scaffold (NOT yet runnable end-to-end).
#
# Builds an arm64 kernel for a target SoC: clone pinned source, apply patches,
# merge the per-SoC config fragment, build Image + dtbs.
set -euo pipefail

SOC="${1:-sm8650}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FRAGMENT="$ROOT/kernel/config/${SOC}.config"

# TODO(Phase 1): pin a real source. Candidates:
#   - mainline stable (kernel.org)            — best upstream hygiene
#   - Linaro release/qcomlt (qcom-next)       — freshest Qualcomm enablement
# Pin by tag/commit + sha256; record in kernel/SOURCE.pin (to be created).
KERNEL_SRC_URL="${KERNEL_SRC_URL:-https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git}"
KERNEL_REF="${KERNEL_REF:-TODO-pin-a-tag}"

echo "[novadeck] SoC=$SOC fragment=$FRAGMENT"
[ -f "$FRAGMENT" ] || { echo "missing config fragment: $FRAGMENT" >&2; exit 1; }

echo "TODO(Phase 1): clone $KERNEL_SRC_URL @ $KERNEL_REF"
echo "TODO(Phase 1): apply patches from kernel/patches/"
echo "TODO(Phase 1): merge_config.sh defconfig $FRAGMENT"
echo "TODO(Phase 1): make ARCH=arm64 CROSS_COMPILE=... Image.gz dtbs modules"
echo "TODO(Phase 1): stage Image.gz + qcom/${SOC}-*.dtb for boot/ packaging (Phase 5)"
exit 0
