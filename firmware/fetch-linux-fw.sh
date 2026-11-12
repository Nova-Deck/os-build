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
COMMIT="$(pin_hdr commit)"; BASE="$(pin_hdr base)"; MIRROR="$(pin_hdr mirror)"
[ -n "$COMMIT" ] && [ -n "$BASE" ] && [ -n "$MIRROR" ] \
  || { echo "pin missing commit/base/mirror header" >&2; exit 1; }

# Retry, because this loop makes one request per pinned file and a single transient 5xx from
# the cgit frontend would otherwise abort a build 30+ minutes in (seen: a 503 on qca/htnv20.bin
# during the ota/v0.2.4 release). curl's default exponential backoff, capped so a genuinely
# dead host still fails promptly instead of stalling the job. The connect timeout is what makes
# the retries reachable at all: without it a SYN that is never answered waits out the kernel's
# ~130 s TCP timeout, which alone exceeds --retry-max-time, so curl never retries.
get() { curl -fsSL --connect-timeout 20 --retry 5 --retry-all-errors --retry-max-time 120 -o "$1" "$2"; }

# Once upstream has failed, stay on the mirror: a runner that cannot reach git.kernel.org fails
# every row, and paying the full retry budget per row would cost an hour across the pin.
use_mirror=0
fetch() {  # <src> <out-tmp>
  if [ "$use_mirror" = 0 ]; then
    get "$2" "${BASE}/${1}?id=${COMMIT}" && return 0
    echo "  upstream failed for $1 — switching to the mirror for the rest of this run" >&2
    use_mirror=1
  fi
  get "$2" "${MIRROR}/${COMMIT}/${1}"
}

echo "[novadeck] linux-firmware @ ${COMMIT:0:12} -> ${DEST#"$ROOT"/}"
mkdir -p "$DEST"
n=0 fetched=0
while read -r src dst sha _rest; do
  case "$src" in ''|'#'* |commit:|base:|mirror:) continue ;; esac
  [ -n "$dst" ] && [ -n "$sha" ] || { echo "bad pin line: '$src $dst $sha'" >&2; exit 1; }
  out="$DEST/$dst"
  n=$((n + 1))
  if [ -f "$out" ] && echo "$sha  $out" | sha256sum -c - >/dev/null 2>&1; then
    continue
  fi
  tmp="$(mktemp)"
  fetch "$src" "$tmp" \
    || { echo "download failed at upstream AND mirror: $src" >&2; rm -f "$tmp"; exit 1; }
  echo "${sha}  ${tmp}" | sha256sum -c - >/dev/null \
    || { echo "sha256 mismatch for $src — refusing (pin stale? wrong commit?)" >&2; rm -f "$tmp"; exit 1; }
  install -Dm0644 "$tmp" "$out"; rm -f "$tmp"
  echo "  ok   $src -> $dst"
  fetched=$((fetched + 1))
done < "$PIN"
echo "[novadeck] $n firmware file(s) present in ${DEST#"$ROOT"/} ($fetched fetched this run)"
