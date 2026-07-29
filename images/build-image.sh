#!/usr/bin/env bash
# novadeck Phase 1 image flow — base rootfs + device firmware + kernel -> rootfs.img.
#
# Chains the pieces into one bootable read-only Btrfs root:
#   1. bootstrap the root from packages               (images/customize-base.sh)
#   2. fetch device-proprietary firmware (pinned)     (firmware/fetch-qcom-fw.sh)
#   3. verify the firmware manifest vs the built kernel, non-fatal (firmware/manifest.sh)
#   4. assemble the read-only Btrfs root              (images/assemble-rootfs.sh)
#
# Prereq: unified kernel already built (kernel/build.sh) so out/ has Image.gz + modroot.
# Device firmware is fetched from the pinned Nova-Deck/qcom-firmwares repo — no proprietary
# blobs ship in-repo. Steps 3-4 run in the novadeck-build image.
#
#   images/build-image.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/out"
FW="$ROOT/firmware/qcom-fw"
DK=(docker run --rm -v "$ROOT":/src -w /src novadeck-build)

[ -f "$OUT/Image.gz" ] \
  || { echo "no kernel: out/Image.gz — run kernel/build.sh first" >&2; exit 1; }

# 1. the root, laid down from packages into an empty tree (pinned, idempotent): the `base`
# metapackage plus the release runtime (NetworkManager, openssh, mesa+Turnip+vulkan-tools).
# customize-base.sh prints a host absolute path; step 4 runs in a container with the repo
# bind-mounted at /src, so translate the $ROOT prefix to /src for the in-container call.
BASE="$("$ROOT/images/customize-base.sh")"
BASE_CTR="/src/${BASE#"$ROOT"/}"

# 2. device firmware — fetch the pinned device-proprietary blobs (idempotent).
"$ROOT/firmware/fetch-qcom-fw.sh"
if [ ! -d "$FW" ]; then
  echo "no device firmware ($FW missing) — firmware/fetch-qcom-fw.sh did not stage it." >&2
  exit 1
fi

# 3. verify firmware coverage vs the built kernel's DTB/module references (non-fatal).
"${DK[@]}" firmware/manifest.sh \
  || echo "  (firmware manifest verify reported gaps — review above before flashing)"

# 4. assemble the read-only Btrfs root. Forward the TEST-ONLY credential env (a no-op
# unless NOVADECK_DEV=1) so a dev card can carry Wi-Fi + SSH creds; see assemble-rootfs.sh.
# Env flags must precede the image name, so spell this docker run out rather than reuse DK.
docker run --rm -v "$ROOT":/src -w /src \
  -e NOVADECK_DEV -e NOVADECK_WIFI_SSID -e NOVADECK_WIFI_PSK -e NOVADECK_SSH_PUBKEY \
  -e NOVADECK_DEBUG \
  novadeck-build images/assemble-rootfs.sh "$BASE_CTR"

cat <<EOF

Image flow done. Read-only root at out/images/rootfs.img.
Next — boot artifact + deploy:
  ${DK[*]} boot/package.sh
  boot/deploy.sh <esp-mountpoint>     # copies the all-boards KERNEL onto the ESP
  # then write out/images/rootfs.img to the device's rootfs partition
EOF
