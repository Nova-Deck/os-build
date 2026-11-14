#!/usr/bin/env bash
# Cross-build tools/hdr-test/hdrtest for aarch64 in the novadeck-build container.
#
#   tools/hdr-test/build.sh        -> work/hdr-test/hdrtest
#
# The container has the aarch64 cross gcc but no Vulkan headers, so they come from the Mesa source
# tree an overlay build leaves under work/ (any Vulkan-Headers 1.3+ tree would do; the program
# loads libvulkan with dlopen and needs only the declarations). Run `make overlay` first if the
# tree is missing.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HDRS=$(cd "$ROOT" && ls -d work/overlay-build/aarch64/mesa/src/mesa-*/include 2>/dev/null | sort -V | tail -1)
[ -n "$HDRS" ] && [ -f "$ROOT/$HDRS/vulkan/vulkan_core.h" ] || {
    echo "build.sh: no Mesa Vulkan headers under work/overlay-build -- run make overlay first" >&2
    exit 1
}
mkdir -p "$ROOT/work/hdr-test"
docker run --rm -v "$ROOT:/src" -w /src novadeck-build -c \
    "aarch64-linux-gnu-gcc -O2 -std=c11 -D_POSIX_C_SOURCE=200809L -Wall -Wextra -Werror \
        -I '$HDRS' -o work/hdr-test/hdrtest tools/hdr-test/hdrtest.c -ldl -lm"
echo "built work/hdr-test/hdrtest (headers: $HDRS)"
