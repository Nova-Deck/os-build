#!/usr/bin/env bash
# novadeck firmware extraction — Phase 1 scaffold (NOT yet runnable end-to-end).
#
# Copies `device`-sourced firmware blobs (per a device manifest) out of a dump of
# the target device's vendor partitions into firmware/extracted/<soc>/ (git-ignored).
#
# Proprietary blobs are NEVER committed. This script only *stages* them locally for
# image assembly. Respect the device vendor's firmware license.
set -euo pipefail

SOC="${1:-sm8650}"
SRC="${2:-}"   # path to a mounted/extracted vendor+modem partition tree
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$ROOT/devices/$SOC/firmware-manifest.txt"
OUT="$ROOT/firmware/extracted/$SOC"

[ -n "$SRC" ] || { echo "usage: extract.sh <soc> <vendor-partition-tree>" >&2; exit 2; }
[ -f "$MANIFEST" ] || { echo "no manifest: $MANIFEST" >&2; exit 1; }

mkdir -p "$OUT"
echo "[novadeck] extracting '$SOC' firmware from $SRC -> $OUT"

# Read 'device'-tagged lines from the manifest and locate each blob in the dump.
grep -E '^device[[:space:]]' "$MANIFEST" | awk '{print $2}' | while read -r dest; do
  base="$(basename "$dest")"
  # TODO(Phase 1): map real vendor-partition locations (firmware-name/, vendor/firmware/, etc.)
  found="$(find "$SRC" -type f -name "$base" 2>/dev/null | head -1 || true)"
  if [ -n "$found" ]; then
    install -Dm0644 "$found" "$OUT/$dest"
    echo "  ok   $dest"
  else
    echo "  MISS $dest  (not found in dump — verify name/location)"
  fi
done

echo "Done. extracted/ is git-ignored; consumed by image assembly (Phase 4)."
