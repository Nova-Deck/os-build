#!/usr/bin/env bash
# novadeck release-card metadata — the small files that travel with a card.
#
#   images/card-meta.sh <image-file>   ->  out/images/release-meta/{sha256sums.txt,provenance/}
#
# Its own script because two paths need the identical bytes: images/publish-card.sh uploads them to
# R2 next to the card, and the non-publishing CI path uploads them as a workflow artifact. Building
# them twice from two copies of the same loop is how the two quietly drift.
#
# WHY THE SUM IS OVER THE COMPRESSED FILE. That is what a downloader has in hand before they
# decompress, so it is the only sum they can check without first writing 19G to disk.
#
# WHY PROVENANCE TRAVELS WITH THE IMAGE. Without it a card months old cannot be traced to the bytes
# it installed. images/manifest.lock answers "built from which SOURCES?" and the artifact pins
# answer "are these the reviewed BYTES?" — the two questions packages/verify-pins.sh keeps separate.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMG="${1:-}"
# NOTE the default is only usable where you can write out/ — after any container build that tree
# is ROOT-OWNED (every stage runs as uid 0 through the bind mount, which is why the Makefile's
# clean targets go through busybox). CI therefore passes a runner-owned directory explicitly.
OUT="${2:-$ROOT/out/images/release-meta}"

[ -n "$IMG" ] && [ -f "$IMG" ] || { echo "usage: $0 <image-file> [outdir]" >&2; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT/provenance/pins"

# Relative name inside the sums file, so `sha256sum -c sha256sums.txt` works in the directory a
# downloader unpacked into rather than only against this build's absolute path.
( cd "$(dirname "$IMG")" && sha256sum "$(basename "$IMG")" ) > "$OUT/sha256sums.txt"

cp "$ROOT/images/manifest.lock" "$OUT/provenance/"
# One directory level per package: every pin is named artifact.pin, so a flat copy would silently
# keep only the last one.
for f in "$ROOT"/packages/*/artifact.pin; do
  [ -e "$f" ] || continue
  cp "$f" "$OUT/provenance/pins/$(basename "$(dirname "$f")").pin"
done

echo "[card-meta] $(cat "$OUT/sha256sums.txt")" >&2
echo "[card-meta] $(find "$OUT/provenance/pins" -name '*.pin' | wc -l) artifact pin(s) + manifest.lock -> ${OUT#"$ROOT"/}" >&2
