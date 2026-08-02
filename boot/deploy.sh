#!/usr/bin/env bash
# novadeck dev deploy — install the stage-1 steamcl tree onto a mounted ESP (Phase 5).
#
# ABL chainloads /EFI/BOOT/bootaa64.efi when it is present. This is the dev-side quick flash for
# iterating on stage 1 only: it writes the same ESP layout that images/make-sdcard.sh seeds and the
# RAUC post-install hook refreshes. It does NOT touch the slot's efi-a/b partitions (stage 2) or
# the boot confs — for those, rebuild the card (`make sdcard`) or install a bundle.
#
#   boot/deploy.sh <esp-mountpoint>
#
# e.g. (host side, ESP already mounted):
#   boot/deploy.sh /run/media/$USER/NOVADECK
#
# The ESP layout this writes is decided by steamcl's own path resolution, not by us: the flag files
# and the font are opened RELATIVE to the chainloader (chainloader/util.c resolve_path), so they
# live beside bootaa64.efi in /EFI/BOOT. Only the boot confs are an absolute path (\SteamOS\conf,
# util.h NEWCONFPATH) and they are not this script's business. /EFI/steamos/grubenv is stage 2's
# env block: SEEDED if absent, otherwise left alone, because it holds the user's board choice.
set -euo pipefail
shopt -s nullglob

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ESP="${1:-}"
OUT="$ROOT/out/boot"

[ -n "$ESP" ] || { echo "usage: boot/deploy.sh <esp-mountpoint>" >&2; exit 2; }
[ -d "$ESP" ] || { echo "ESP mountpoint is not a directory: $ESP" >&2; exit 2; }
mountpoint -q "$ESP" 2>/dev/null \
  || echo "warning: $ESP is not a mountpoint — is the ESP actually mounted there?" >&2

for f in steamcl.efi steamcl-version fonts/default.pf2; do
  [ -f "$OUT/$f" ] || { echo "no boot artifact: ${OUT#"$ROOT"/}/$f (run boot/steamcl.sh first)" >&2; exit 1; }
done

mkdir -p "$ESP/EFI/BOOT/fonts" "$ESP/EFI/steamos"

# Per-file copies, deliberately NOT a directory rename: `mv <dir> <existing-dir>` moves the source
# INSIDE the target rather than replacing it, which is how an earlier version of this script
# silently produced /EFI/BOOT/BOOT/ and then hid the mistake behind `|| true`. vfat has no atomic
# rename across power loss anyway, and this is a dev helper — make-sdcard.sh is the release path.
install -m0644 "$OUT/steamcl.efi"       "$ESP/EFI/BOOT/bootaa64.efi"
install -m0644 "$OUT/steamcl-version"   "$ESP/EFI/BOOT/steamcl-version"
install -m0644 "$OUT/fonts/default.pf2" "$ESP/EFI/BOOT/fonts/default.pf2"
# Empty flag file: its PRESENCE tells steamcl to chainload only from the device it was itself
# loaded from (chainloader/bootload.c, is_restricted). The content is never read.
: >"$ESP/EFI/BOOT/steamcl-restricted"

if [ -s "$ESP/EFI/steamos/grubenv" ]; then
  echo "  keep /EFI/steamos/grubenv (it holds the saved board choice)"
elif command -v grub-editenv >/dev/null 2>&1; then
  grub-editenv "$ESP/EFI/steamos/grubenv" create
  echo "  seeded /EFI/steamos/grubenv"
else
  echo "warning: no grub-editenv on this host — /EFI/steamos/grubenv not seeded, so stage 2" >&2
  echo "         cannot save a board choice until one exists (make sdcard writes it)" >&2
fi

sync "$ESP" 2>/dev/null || sync
echo "  ok   stage-1 steamcl written to $ESP/EFI/BOOT/bootaa64.efi. ABL chainloads it."
