#!/usr/bin/env bash
# novadeck linux-firmware fetch — stage the OPEN firmware blobs the SM8650 needs at
# runtime (Adreno GPU, WCN7850 Wi-Fi/BT, Iris VPU). The upstream Holo aarch64 base ships
# no /lib/firmware, so these must be delivered by us. Sourced from the official
# linux-firmware repo, pinned by commit + per-file sha256 in firmware/LINUX_FW.pin.
#
# Device-proprietary blobs (GPU zap, adsp/cdsp) are NOT fetched here — those come from the
# pinned Nova-Deck/qcom-firmwares repo via firmware/fetch-qcom-fw.sh.
#
#   firmware/fetch-linux-fw.sh
#
# Exports to firmware/linux-fw/ (git-ignored). Runs on the host (needs network),
# like images/fetch-base.sh. Idempotent and staleness-proof by construction: each file is
# verified against its per-file sha256 in the pin, so a pin bump (new file or changed sha)
# re-fetches exactly the affected files. The open blobs are SoC-agnostic (the unified
# kernel embeds the union), so this is a single flat tree, not per-SoC.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PIN="$ROOT/firmware/LINUX_FW.pin"
DEST="$ROOT/firmware/linux-fw"

[ -f "$PIN" ] || { echo "missing pin: $PIN" >&2; exit 1; }
pin_hdr() { sed -n "s/^$1:[[:space:]]*//p" "$PIN" | head -1; }
COMMIT="$(pin_hdr commit)"; BASE="$(pin_hdr base)"
[ -n "$COMMIT" ] && [ -n "$BASE" ] || { echo "pin missing commit/base header" >&2; exit 1; }

echo "[novadeck] linux-firmware @ ${COMMIT:0:12} -> ${DEST#"$ROOT"/}"
mkdir -p "$DEST"
n=0 fetched=0
while read -r src dst sha _rest; do
  case "$src" in ''|'#'* |commit:|base:) continue ;; esac
  [ -n "$dst" ] && [ -n "$sha" ] || { echo "bad pin line: '$src $dst $sha'" >&2; exit 1; }
  out="$DEST/$dst"
  n=$((n + 1))
  if [ -f "$out" ] && echo "$sha  $out" | sha256sum -c - >/dev/null 2>&1; then
    continue
  fi
  tmp="$(mktemp)"
  # Retry, because this loop makes one request per pinned file and a single transient 5xx from
  # the cgit frontend would otherwise abort a build 30+ minutes in (seen: a 503 on qca/htnv20.bin
  # during the ota/v0.2.4 release). curl's default exponential backoff, capped so a genuinely
  # dead upstream still fails the build promptly instead of stalling the job.
  curl -fsSL --retry 5 --retry-all-errors --retry-max-time 120 \
    -o "$tmp" "${BASE}/${src}?id=${COMMIT}" \
    || { echo "download failed: $src" >&2; rm -f "$tmp"; exit 1; }
  echo "${sha}  ${tmp}" | sha256sum -c - >/dev/null \
    || { echo "sha256 mismatch for $src — refusing (pin stale? wrong commit?)" >&2; rm -f "$tmp"; exit 1; }
  install -Dm0644 "$tmp" "$out"; rm -f "$tmp"
  echo "  ok   $src -> $dst"
  fetched=$((fetched + 1))
done < "$PIN"
echo "[novadeck] $n firmware file(s) present in ${DEST#"$ROOT"/} ($fetched fetched this run)"
