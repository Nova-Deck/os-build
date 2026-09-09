#!/usr/bin/env bash
# novadeck read-only root assembler — RAUC keyring, boot mirror and installer GPT (stage 4b, pass 2).
#
# SOURCED by rootfs/assemble-rootfs.sh, never executed. Split out of it for issue #43; the code
# and its rationale are unchanged, and the stage banner below is the same one the assembler
# carried (tests/test-mkroot.sh reads the stage IDs out of this file set).
#
# Runs at top level, in place: sourcing it IS the stage.
#
# Reads the assembler's globals rather than taking arguments -- $stage (the staged tree), $ROOT
# (repo root), $OUT (build outputs). Turning ~20 implicit globals into positional parameters is
# where a verbatim move stops being verbatim, so it is deliberately not done.

# --- RAUC: the device keyring and the slot's own kernel (Phase 4b pass 2) ----------------------
# Two things the overlay tree cannot carry, because both are BUILD OUTPUTS rather than static files.
#
# 1. The keyring. /etc/rauc/system.conf points at /etc/rauc/keyring.pem; it is installed here from
#    the committed CA so there is ONE copy in the repo (ota/rauc/novadeck-ca.pem, which
#    ota/gen-signing-ca.sh also signs bundles against) rather than a duplicate under rootfs/overlay that could drift.
#
# 2. The boot software, mirrored under /usr/lib/novadeck/boot (Phase 5; docs/phase5.md). The stage-1
#    steamcl and both per-slot stage-2 GRUB builds are owned by the same build that ships /boot/Image
#    and /lib/modules/<ver> inside this root, so carrying them here makes the pairing true by
#    construction: the RAUC post-install hook refreshes the ESP and the slot's efi partition FROM
#    this directory, so an update can never install a root whose boot chain does not boot it. This
#    directory replaces the old /usr/lib/novadeck/boot.img (Phase 1 /KERNEL flow).
#    steamos-bootconf (holo-bootconf) is installed as /usr/bin/steamos-bootconf — the boot state
#    reader both the RAUC backend (novadeck-bootctl) and the health service call.
CA_SRC="$ROOT/ota/rauc/novadeck-ca.pem"
BOOTDIR_SRC="$OUT/boot"
[ -f "$CA_SRC" ] || { echo "no RAUC CA at ${CA_SRC#"$ROOT"/} (run ota/gen-signing-ca.sh)" >&2; exit 1; }
for f in steamcl.efi steamcl-version holo-bootconf fonts/default.pf2 \
         grubaa64.efi grub-a.cfg grub-b.cfg fonts/dejavu-mono.pf2 grubenv; do
  [ -f "$BOOTDIR_SRC/$f" ] || { echo "no boot artifact: ${BOOTDIR_SRC#"$ROOT"/}/$f (run boot/steamcl.sh + boot/grub.sh)" >&2; exit 1; }
done
install -D -m0444 "$CA_SRC"      "$stage/etc/rauc/keyring.pem"
install -D -m0755 "$BOOTDIR_SRC/holo-bootconf" "$stage/usr/bin/steamos-bootconf"
install -d -m0755 "$stage/usr/lib/novadeck/boot/fonts"
install -D -m0444 "$BOOTDIR_SRC/steamcl.efi"      "$stage/usr/lib/novadeck/boot/steamcl.efi"
install -D -m0444 "$BOOTDIR_SRC/steamcl-version"  "$stage/usr/lib/novadeck/boot/steamcl-version"
install -D -m0444 "$BOOTDIR_SRC/fonts/default.pf2" "$stage/usr/lib/novadeck/boot/fonts/default.pf2"
install -D -m0444 "$BOOTDIR_SRC/grubaa64.efi"     "$stage/usr/lib/novadeck/boot/grubaa64.efi"
install -D -m0444 "$BOOTDIR_SRC/grub-a.cfg"       "$stage/usr/lib/novadeck/boot/grub-a.cfg"
install -D -m0444 "$BOOTDIR_SRC/grub-b.cfg"       "$stage/usr/lib/novadeck/boot/grub-b.cfg"
install -D -m0444 "$BOOTDIR_SRC/fonts/dejavu-mono.pf2" "$stage/usr/lib/novadeck/boot/fonts/dejavu-mono.pf2"
# The pristine stage-2 env block. Unlike everything above it, no A/B update ever reads this: the ESP
# is shared, so its grubenv survives updates by not being touched, and overwriting it would throw
# away the board choice the user saved. It is here for the INTERNAL INSTALLER, which writes an ESP
# that does not exist yet and cannot create one -- grub-editenv is not on this image (see
# boot/grub.sh, which emits it for exactly this).
install -D -m0444 "$BOOTDIR_SRC/grubenv"          "$stage/usr/lib/novadeck/boot/grubenv"

# The GPT, shipped VERBATIM beside the slot-write primitives (Phase 2 of
# .claude/plans/internal-install.plan.md). image/genpart.sh --append lays our eight partitions into
# an OEM disk's free space and reports where they landed; partition-table.txt is the single source
# of the sizes, types and GPT names it works from, and the same file image/make-sdcard.sh uses for
# a card.
#
# VERBATIM IS THE POINT, and guard-rootfs.sh diffs the two copies rather than trusting this line.
# An installer working from a stale table would produce a disk whose partition SIZES differ from the
# card the release was tested on, and the first symptom is a rootfs image that does not fit a slot --
# after the OEM's userdata has already been destroyed, which is not a state to discover a drift in.
# genpart.sh resolves the table next to itself for exactly this reason, so it needs no argument here
# and behaves identically from image/ in the repo and from /usr/lib/novadeck/install/ on a device.
install -D -m0555 "$ROOT/image/genpart.sh"          "$stage/usr/lib/novadeck/install/genpart.sh"
install -D -m0444 "$ROOT/image/partition-table.txt" "$stage/usr/lib/novadeck/install/partition-table.txt"
# lib-gpt.sh is sourced by the script genpart.sh emits, so it ships beside it or the append mode
# refuses. 0444: sourced, never executed, like lib-slotwrite.sh.
install -D -m0444 "$ROOT/image/lib-gpt.sh"          "$stage/usr/lib/novadeck/install/lib-gpt.sh"
echo "  RAUC: keyring.pem + stage-1/2 boot software + /usr/bin/steamos-bootconf installed"

