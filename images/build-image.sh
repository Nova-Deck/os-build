#!/usr/bin/env bash
# novadeck Phase 1 image flow — base rootfs + device firmware + kernel -> rootfs.img.
#
# Chains the pieces into one bootable read-only Btrfs root:
#   1. fetch the pinned upstream base userspace      (images/fetch-base.sh)
#   2. stage device firmware — extract from a vendor dump if one is given here,
#      else require a prior firmware/extract.sh run   (firmware/extract.sh)
#   3. verify the firmware manifest vs the built kernel, non-fatal (firmware/manifest.sh)
#   4. assemble the read-only Btrfs root              (images/assemble-rootfs.sh)
#
# Prereq: kernel already built (kernel/build.sh <soc>) so out/<soc>/ has Image.gz +
# modroot. Firmware extraction needs a dump of YOUR device's vendor partitions — no
# proprietary blobs ship in-repo. Steps 3-4 run in the novadeck-build image.
#
#   images/build-image.sh <soc> [vendor-partition-tree]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOC="${1:-}"
[ -n "$SOC" ] || { echo "usage: ${0##*/} <soc>" >&2; exit 2; }
VENDOR="${2:-}"
OUT="$ROOT/out/$SOC"
FW="$ROOT/firmware/extracted/$SOC"
DK=(docker run --rm -v "$ROOT":/src -w /src novadeck-build)

[ -f "$OUT/Image.gz" ] \
  || { echo "no kernel: out/$SOC/Image.gz — run kernel/build.sh $SOC first" >&2; exit 1; }

# 1. base userspace (pinned, idempotent) with the release runtime layered in (iwd,
# dropbear, mesa+Turnip+vulkan-tools). customize-base.sh prints a host absolute path;
# step 4 runs in a container with the repo bind-mounted at /src, so translate the $ROOT
# prefix to /src for the in-container call. (For a bare base with no runtime added, use
# images/fetch-base.sh instead.)
BASE="$("$ROOT/images/customize-base.sh" "$SOC")"
BASE_CTR="/src/${BASE#"$ROOT"/}"

# 2. device firmware. Extract now if a vendor dump was supplied; otherwise a prior
#    extract must have populated firmware/extracted/<soc>/.
if [ -n "$VENDOR" ]; then
  echo "[novadeck] extracting firmware from $VENDOR"
  "$ROOT/firmware/extract.sh" "$SOC" "$VENDOR"
fi
if [ ! -d "$FW" ]; then
  echo "no extracted firmware for $SOC (firmware/extracted/$SOC missing)." >&2
  echo "  supply a vendor-partition dump:  images/build-image.sh $SOC <vendor-tree>" >&2
  echo "  (proprietary blobs come from YOUR device; none are shipped in-repo)" >&2
  exit 1
fi

# 3. verify firmware coverage vs the built kernel's DTB/module references (non-fatal).
"${DK[@]}" firmware/manifest.sh "$SOC" \
  || echo "  (firmware manifest verify reported gaps — review above before flashing)"

# 4. assemble the read-only Btrfs root. Forward the TEST-ONLY credential env (a no-op
# unless NOVADECK_TEST=1) so a test card can carry Wi-Fi + SSH creds; see assemble-rootfs.sh.
# Env flags must precede the image name, so spell this docker run out rather than reuse DK.
docker run --rm -v "$ROOT":/src -w /src \
  -e NOVADECK_TEST -e NOVADECK_WIFI_SSID -e NOVADECK_WIFI_PSK -e NOVADECK_SSH_PUBKEY \
  novadeck-build images/assemble-rootfs.sh "$SOC" "$BASE_CTR"

cat <<EOF

Image flow done. Read-only root at out/$SOC/images/rootfs.img.
Next — boot artifact + deploy:
  ${DK[*]} boot/package.sh $SOC
  boot/deploy.sh $SOC <esp-mountpoint>     # copies the all-boards KERNEL onto the ESP
  # then write out/$SOC/images/rootfs.img to the device's rootfs partition
EOF
