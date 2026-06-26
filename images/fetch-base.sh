#!/usr/bin/env bash
# novadeck base rootfs fetch — export the pinned Holo aarch64 preview into a tree.
#
# images/assemble-rootfs.sh needs a base userspace directory. The upstream base is
# Valve/Collabora's aarch64 Arch "holo-core" preview, pinned BY DIGEST in base.digest
# (see docs/base-pin.md). This pulls that image and exports its filesystem — no
# container is *run*, so `docker export` of a created container works on an x86 host
# with no qemu (it only moves files, never executes the arm64 userspace).
#
#   images/fetch-base.sh
#
# Exports to work/base/ (git-ignored) and prints that path on stdout so an
# orchestrator can capture it. Idempotent; set FORCE=1 to re-export.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PINFILE="$ROOT/base.digest"
DEST="$ROOT/work/base"

[ -f "$PINFILE" ] || { echo "no base pin: $PINFILE" >&2; exit 1; }
# Pin = last non-comment, non-blank line: an image ref ending in @sha256:<digest>.
REF="$(grep -vE '^[[:space:]]*(#|$)' "$PINFILE" | tail -1)"
case "$REF" in
  *@sha256:*) ;;
  *) echo "refusing unpinned base ref (need ...@sha256:<digest>): '$REF'" >&2; exit 1 ;;
esac
command -v docker >/dev/null 2>&1 || { echo "docker required for base fetch" >&2; exit 1; }

# Already exported? Reuse unless FORCE=1 (the arm64 base is large).
if [ -z "${FORCE:-}" ] && [ -d "$DEST/usr" ]; then
  echo "[novadeck] base rootfs present: ${DEST#"$ROOT"/} (FORCE=1 to re-export)" >&2
  echo "$DEST"; exit 0
fi

echo "[novadeck] pulling pinned base: $REF" >&2
docker pull "$REF" >&2

echo "[novadeck] exporting base rootfs -> ${DEST#"$ROOT"/}" >&2
rm -rf "$DEST"; mkdir -p "$DEST"
cid="$(docker create "$REF")"
trap 'docker rm -f "$cid" >/dev/null 2>&1 || true' EXIT
docker export "$cid" | tar -C "$DEST" -xf -

echo "[novadeck] base rootfs ready ($(du -sh "$DEST" | cut -f1) at ${DEST#"$ROOT"/})" >&2
echo "$DEST"
