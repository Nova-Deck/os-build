#!/usr/bin/env bash
# novadeck qcom-firmware fetch — stage the DEVICE-PROPRIETARY firmware blobs the target
# needs at runtime (GPU zap shaders, adsp/cdsp DSP images, AudioReach tplg, ath12k Wi-Fi/BT,
# Renesas xHCI). These are Qualcomm/vendor blobs republished from each device's Android vendor
# image to the Nova-Deck/qcom-firmwares repo, pinned by commit in firmware/QCOM_FW.pin.
#
# Open firmware (Adreno microcode, qca BT, Iris VPU) is fetched separately by
# firmware/fetch-linux-fw.sh from the official linux-firmware repo.
#
#   firmware/fetch-qcom-fw.sh
#
# SoC-agnostic: the firmware repo mirrors /lib/firmware (blobs are self-namespaced by their
# on-device path, e.g. qcom/sm8650/...), so one fetch serves every board. Exports to
# firmware/qcom-fw/ (git-ignored). Runs on the host (needs network), like fetch-linux-fw.sh.
# Idempotent — a staged tree whose .commit marker matches the pinned commit AND verifies
# against its sha256sums.txt is left untouched; to force a re-fetch, delete firmware/qcom-fw/.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PIN="$ROOT/firmware/QCOM_FW.pin"
DEST="$ROOT/firmware/qcom-fw"

[ -f "$PIN" ] || { echo "missing pin: $PIN" >&2; exit 1; }
pin_hdr() { sed -n "s/^$1:[[:space:]]*//p" "$PIN" | head -1; }
REPO="$(pin_hdr repo)"; COMMIT="$(pin_hdr commit)"
[ -n "$REPO" ] && [ -n "$COMMIT" ] || { echo "pin missing repo/commit header" >&2; exit 1; }

# Idempotent: skip ONLY if the staged tree matches the PINNED commit AND verifies
# against its sha sidecar. The .commit marker guards against a stale tree: without it,
# a pin bump would be silently ignored (the old tree still verifies against its own old
# sha256sums.txt), building against out-of-date firmware.
if [ -f "$DEST/.commit" ] && [ -f "$DEST/sha256sums.txt" ] \
   && [ "$(cat "$DEST/.commit" 2>/dev/null)" = "$COMMIT" ] \
   && ( cd "$DEST" && sha256sum -c sha256sums.txt >/dev/null 2>&1 ); then
  echo "[novadeck] qcom-firmware @ ${COMMIT:0:12} already staged -> ${DEST#"$ROOT"/}"
  exit 0
fi

echo "[novadeck] qcom-firmware @ ${COMMIT:0:12} <- $REPO"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
url="$REPO/archive/$COMMIT.tar.gz"
curl -fsSL -o "$tmp/fw.tar.gz" "$url" \
  || { echo "download failed: $url" >&2; exit 1; }
tar -xzf "$tmp/fw.tar.gz" -C "$tmp"
# GitHub source archives extract to <repo-name>-<commit>/
src="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d -name "*-$COMMIT" | head -1)"
[ -n "$src" ] && [ -f "$src/sha256sums.txt" ] \
  || { echo "fetched archive has no sha256sums.txt (wrong commit/repo?)" >&2; exit 1; }
# Per-file integrity against the repo's own manifest.
( cd "$src" && sha256sum -c sha256sums.txt ) \
  || { echo "sha256 mismatch in fetched qcom-firmware — refusing (pin stale? repo tampered?)" >&2; exit 1; }

rm -f "$src/README.md"   # repo doc, not firmware
rm -rf "$DEST"; mkdir -p "$DEST"
cp -a "$src"/. "$DEST"/
n="$(find "$DEST" -type f ! -name sha256sums.txt | wc -l)"
printf '%s\n' "$COMMIT" > "$DEST/.commit"   # marker: staged commit, checked by the guard above
echo "[novadeck] $n firmware file(s) staged in ${DEST#"$ROOT"/}"
