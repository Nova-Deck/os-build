#!/usr/bin/env bash
# novadeck Steam seed PACKER (build host) — turn work/steam-seed into the file the installer medium
# CARRIES. Phase 6 of .claude/plans/internal-install.plan.md.
#
#   steam-seed/pack-seed.sh            -> out/steam-seed/steam-seed.tar.zst
#                                      -> out/steam-seed/steam-seed.sha256   (the pin, one line)
#
# WHY THIS EXISTS AT ALL. `make sdcard` pre-seeds /home from the DIRECTORY (mkfs.ext4 -d, via
# images/lib-homestage.sh), so a card needs no artifact — it writes the tree straight into the
# filesystem it is building. The installer medium cannot: it builds /home on someone else's disk,
# hours or months later, so it has to carry the tree with it. install/mkimage.sh stages this file
# into the medium's root and writes its sha256 beside it as the pin the spine checks before it
# unpacks anything.
#
# IT WAS BRIEFLY A PUBLISHED, CONTENT-ADDRESSED ARTIFACT — named steam-seed-<sha>.tar.zst, uploaded
# to the update server, fetched at install time from a URL the medium derived from its own baked
# pin. That worked, and it bought nothing: a medium is bound to exactly one seed either way, so
# downloading it only added a publisher, a workflow, a pin handed between CI jobs, a `seed/`
# directory that could never be pruned without retiring media in the field, and 1.7 GB of tmpfs
# consumed at the exact moment the installer is streaming a ~4 GB bundle through rauc's NBD path.
# The card has always carried its seed; the medium does too now. (User's call, 2026-08-25.)
#
# THE PACK IS DETERMINISTIC, so an unchanged seed produces an unchanged medium. Sorted names, owner
# and group forced
# to 0 (the installer chowns the tree wholesale after unpacking; the MODES are what must survive) and
# a FIXED zstd thread count, because zstd's multithreaded output depends on how many jobs it split
# into — `-T0` on a 16-core runner and a 4-core laptop produce different bytes for the same input,
# and every rebuild would then produce a different medium for no change at all.
#
# ITS MEMBERS ARE THE CONTENTS OF work/steam-seed, not the directory: stage_deck_home() unpacks it
# INTO an already-created `.local/share/Steam`, while the card path copies the directory ONTO that
# path. Same bytes on both media is the point — a tarball one level off would put the client in
# .local/share/Steam/steam-seed and produce a /home that looks right and boots to nothing.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SEED_DIR="${NOVADECK_SEED_DIR:-$ROOT/work/steam-seed}"
# out/steam-seed, NOT out/images: this runs on the HOST (the seed tree is host-fetched and
# host-owned) and out/images belongs to root — every image stage writes it from inside a container,
# so a host-side packer gets EACCES there on any tree that has ever built an image. The same
# ownership fact publish-bundle.sh's header records for a different reason.
OUT_DIR="${NOVADECK_OUT_DIR:-$ROOT/out/steam-seed}"
# 19 is the level the rootfs squashfs uses, and this artifact is downloaded over the same Wi-Fi by
# the same devices. Threads are pinned rather than -T0 for the determinism reason above.
ZSTD_LEVEL="${SEED_ZSTD_LEVEL:-19}"
ZSTD_THREADS="${SEED_ZSTD_THREADS:-4}"

log() { printf '[pack-seed] %s\n' "$*" >&2; }
die() { printf '[pack-seed] %s\n' "$*" >&2; exit 1; }

[ -d "$SEED_DIR" ] || die "no staged Steam seed at ${SEED_DIR#"$ROOT"/} — run 'make steam-seed-sync' first"
# THE COMPLETENESS MARKER, and it is the fetcher's own: Steam writes
# package/<manifest>.installed only when its self-install finished. A seed without it re-installs
# itself on first boot, over the user's network — which is the whole thing the offline bake exists to
# avoid — and this would publish it as though it were finished. steamui.so is the second half of the
# fetcher's pair, because a tree can carry the marker and still be missing the client it names.
compgen -G "$SEED_DIR/package/*.installed" >/dev/null \
  || die "${SEED_DIR#"$ROOT"/} has no package/*.installed — that seed is incomplete and would self-heal on first boot"
[ -f "$SEED_DIR/steamrtarm64/steamui.so" ] \
  || die "${SEED_DIR#"$ROOT"/} has no steamrtarm64/steamui.so — that is not a usable Steam tree"
command -v zstd >/dev/null 2>&1 || die "zstd is not installed on this build host"

mkdir -p "$OUT_DIR"
# A UNIQUE TEMP NAME, not a fixed .part. Two packs running at once against one output directory used
# to write the same path, and the interleaved result is the worst possible artifact: whichever run
# renames it hashes it AFTERWARDS, so the garbage gets a valid, self-consistent, publishable name,
# and the medium's pin check — the only integrity gate this artifact has — passes on it. Observed
# here on 2026-08-25, by running the packer twice by accident.
tmp="$(mktemp "$OUT_DIR/.steam-seed.XXXXXX.tar.zst.part")"
trap 'rm -f "$tmp" "$tmp.list"' EXIT

log "packing ${SEED_DIR#"$ROOT"/} (zstd -$ZSTD_LEVEL, $ZSTD_THREADS threads) — several minutes"
# MEASURED 2026-08-25 on a 16-core host: 3.3 GB of staged tree -> 1449 MiB in 2m46s wall.
tar --sort=name --owner=0 --group=0 --numeric-owner -C "$SEED_DIR" -cf - . \
  | zstd -q "-$ZSTD_LEVEL" "-T$ZSTD_THREADS" -f -o "$tmp"

# READ IT BACK BEFORE NAMING IT. Nothing signs this artifact and nothing downstream can tell a
# truncated archive from a good one — the medium hashes what it downloads and compares against a pin
# that would match whatever we published, corrupt or not. One decompress pass (~20s) is the only
# chance to notice, and it costs a fraction of what packing it cost.
log "verifying the archive reads back"
zstd -dc "$tmp" | tar -tf - >"$tmp.list" \
  || die "the archive does not decompress and list — refusing to name bytes nobody could unpack"
grep -qx './steamrtarm64/steamui.so' "$tmp.list" \
  || die "the archive lists no ./steamrtarm64/steamui.so — it is not the Steam tree stage_deck_home unpacks"
grep -q '^\./package/.*\.installed$' "$tmp.list" \
  || die "the archive carries no package/*.installed — the completeness marker did not survive the pack"
rm -f "$tmp.list"

sha="$(sha256sum "$tmp" | cut -d' ' -f1)"
art="$OUT_DIR/steam-seed.tar.zst"
mv -f "$tmp" "$art"
trap - EXIT
printf '%s\n' "$sha" >"$OUT_DIR/steam-seed.sha256"

size="$(stat -c %s "$art")"
log "$(basename "$art")  $((size / 1024 / 1024)) MiB"
log "sha256: $sha"
log "install/mkimage.sh stages it into the medium, and writes that hash beside it as the pin"
