#!/usr/bin/env bash
# Offline verification of a built A/B card image — out/images/sdcard.img.
#
# Same doctrine as images/guard-rootfs.sh: assert the BUILT ARTIFACT, not the source diff. That
# guard stops at the staged tree (it runs before mkfs), so nothing checked the partition table,
# the ESP contents, or the filesystem identities the A/B switch depends on. This closes that gap
# for the parts a slot switch can be silently wrong about.
#
# Phase 5 shape (docs/phase5.md): the card boots ABL → steamcl (stage 1, on the ESP) → per-slot
# GRUB (stage 2, on the slot's efi-a/b partition) → kernel. So beyond the filesystem identities
# this asserts the two boot homes: the ESP carries steamcl + the boot confs + the grubenv, and
# each efi partition carries its stage-2 GRUB + identity partsets keyed to the disk's partuuids.
# There is deliberately no /KERNEL and no /NOVADECK/ to check anymore.
#
# It matters most for one thing that is invisible until hardware contradicts you: the two roots
# are content-identical by design, so if they also share a btrfs fsid then mounting slot B can
# hand you slot A, and every slot test after that is meaningless. That check is why this exists.
#
# Everything here is unprivileged — dd out a superblock and ask blkid, read ext4 with debugfs,
# read the ESP/efi partitions with mtools. No loop mounts, no root.
#
# Run inside the build image (needs sgdisk, blkid, debugfs, mtools, cpio):
#   docker run --rm -v "$PWD":/src -w /src novadeck-build images/verify-card.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMG="${1:-$ROOT/out/images/sdcard.img}"
TABLE="$ROOT/images/partition-table.txt"
INITRAMFS="$ROOT/out/initramfs.cpio.gz"

[ -f "$IMG" ] || { echo "no card image: $IMG (run make sdcard)" >&2; exit 1; }
for t in sgdisk blkid debugfs mdir mtype mlabel cpio; do
  command -v "$t" >/dev/null 2>&1 || { echo "$t not found — run inside novadeck-build" >&2; exit 1; }
done

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export MTOOLS_SKIP_CHECK=1
FAIL=0
ok()  { printf '    ok  %s\n' "$1"; }
bad() { printf '    !!  %s\n' "$1"; FAIL=1; }

part_num() { awk -v n="$1" '/^[[:space:]]*#/||/^[[:space:]]*$/{next} {i++; if ($1==n) {print i; exit}}' "$TABLE"; }
start()    { sgdisk -i "$1" "$IMG" | sed -n 's/^First sector: \([0-9]*\).*/\1/p'; }
part_uuid() { sgdisk -i "$1" "$IMG" | sed -n 's/^Partition unique GUID: \(.*\)/\1/p' | tr '[:upper:]' '[:lower:]'; }

P_ESP=$(part_num esp)
P_EFIA=$(part_num efi-a); P_EFIB=$(part_num efi-b)
P_ROOTA=$(part_num rootfs-a); P_ROOTB=$(part_num rootfs-b)
P_VARA=$(part_num var-a);     P_VARB=$(part_num var-b)
P_HOME=$(part_num home)

ESP_UUID=$(part_uuid "$P_ESP")
EFIA_UUID=$(part_uuid "$P_EFIA")
EFIB_UUID=$(part_uuid "$P_EFIB")

echo "[novadeck] verifying ${IMG#"$ROOT"/}"

# ----------------------------------------------------------------------------------------------
# 1. Filesystem identity. Two btrfs filesystems on one disk sharing an fsid AND devid=1 are the
# pair btrfs keys its in-kernel device list on: the second scanned is treated as the first having
# MOVED, and silently replaces its path.
# ----------------------------------------------------------------------------------------------
echo "  1. filesystem identity"
declare -A U TY
for p in "$P_ROOTA" "$P_ROOTB" "$P_VARA" "$P_VARB"; do
  s=$(start "$p")
  [ -n "$s" ] || { bad "cannot read start sector of partition $p"; continue; }
  dd if="$IMG" of="$T/p$p.sb" bs=512 skip="$s" count=8192 status=none
  U[$p]=$(blkid -p -o value -s UUID "$T/p$p.sb" 2>/dev/null)
  TY[$p]=$(blkid -p -o value -s TYPE "$T/p$p.sb" 2>/dev/null)
done

if [ -z "${U[$P_ROOTB]:-}" ]; then
  ok "slot B is empty (release card, or NOVADECK_SLOT_B=0) — skipping the A/B identity checks"
  SLOT_B=0
else
  SLOT_B=1
  [ "${TY[$P_ROOTA]}" = btrfs ] && [ "${TY[$P_ROOTB]}" = btrfs ] \
    && ok "both roots are btrfs" || bad "root types: ${TY[$P_ROOTA]} / ${TY[$P_ROOTB]}"
  [ -n "${U[$P_ROOTA]}" ] && [ "${U[$P_ROOTA]}" != "${U[$P_ROOTB]}" ] \
    && ok "rootfs-a / rootfs-b fsids differ (${U[$P_ROOTA]:0:8} vs ${U[$P_ROOTB]:0:8})" \
    || bad "rootfs-a and rootfs-b SHARE an fsid — a slot switch cannot be trusted"
  [ -n "${U[$P_VARA]}" ] && [ "${U[$P_VARA]}" != "${U[$P_VARB]}" ] \
    && ok "var-a / var-b UUIDs differ" \
    || bad "var-a and var-b share a UUID"
fi

# Per-slot filesystem LABELS. Not how stage 2 normally finds the root -- it goes by partition
# index -- but they are its documented fallback, they are what `blkid` on a mounted card reports,
# and they are the thing a RAUC raw write silently gets wrong (the bundle image is slot A's, so an
# install leaves the target labelled novadeck-root-A until the post-install hook re-labels it).
for pair in "$P_ROOTA:novadeck-root-A" "$P_ROOTB:novadeck-root-B"; do
  pn=${pair%%:*}; want=${pair#*:}
  [ "$SLOT_B" = 0 ] && [ "$pn" = "$P_ROOTB" ] && continue
  got=$(blkid -p -o value -s LABEL "$T/p$pn.sb" 2>/dev/null)
  [ "$got" = "$want" ] && ok "p$pn btrfs label = $want" || bad "p$pn btrfs label: expected '$want', got '$got'"
done

# ----------------------------------------------------------------------------------------------
# 2. The independent slot witness. /var/lib/novadeck/slot records which var actually mounted;
# it is written per-slot at image build and re-written by post-install.sh. It is the only
# cross-check that does not share a failure mode with the selection code.
# ----------------------------------------------------------------------------------------------
echo "  2. slot witness"
check_slot() {  # <partnum> <expected letter>
  local s got
  s=$(start "$1")
  dd if="$IMG" of="$T/var$1.img" bs=512 skip="$s" count=524288 status=none
  got=$(debugfs -R "cat /lib/novadeck/slot" "$T/var$1.img" 2>/dev/null | tr -d '\n\r')
  [ "$got" = "$2" ] && ok "p$1 /var/lib/novadeck/slot = $2" \
                    || bad "p$1 slot witness: expected '$2', got '$got'"
}
check_slot "$P_VARA" a
[ "$SLOT_B" = 1 ] && check_slot "$P_VARB" b

# ----------------------------------------------------------------------------------------------
# 3. The ESP (stage 1 home). steamcl at /EFI/BOOT/bootaa64.efi is the only thing ABL can find,
# so a card with no /KERNEL still boots. The boot state is the confs + the seeded grubenv.
# ----------------------------------------------------------------------------------------------
echo "  3. ESP (stage 1)"
espoff=$(( $(start "$P_ESP") * 512 ))
need_file() {  # <msdos path> <what>
  mtype -i "$IMG@@$espoff" "$1" >"$T/f" 2>/dev/null && ok "$2 present" || bad "$2 missing"
}
# The FAT label. Nothing in the boot chain RESOLVES by it (stage 2 goes by partition index, with a
# content search for /SteamOS/conf/<slot>.conf as the fallback), which is exactly why it is worth
# asserting: when it did matter, it drifted from what grub.cfg searched for and nothing failed.
# mlabel, not blkid: a FAT32 volume label lives in a root-directory entry out in the data area,
# so probing a short dd of the superblock reports nothing at all.
# mlabel prints " Volume label is NOVADECK   " -- leading space, and the label space-padded to the
# full 11 bytes FAT stores. Both have to be stripped or this compares against padding.
esp_fslabel=$(mlabel -i "$IMG@@$espoff" -s :: 2>/dev/null \
  | sed -n 's/^[[:space:]]*Volume label is //p' | sed 's/[[:space:]]*$//')
[ -n "$esp_fslabel" ] && [ "${#esp_fslabel}" -le 11 ] \
  && ok "ESP FAT label '$esp_fslabel' (<= 11 chars)" \
  || bad "ESP FAT label is empty or over the 11-char FAT limit: '$esp_fslabel'"
need_file ::/EFI/BOOT/bootaa64.efi         "steamcl at /EFI/BOOT/bootaa64.efi"
need_file ::/EFI/BOOT/steamcl-version     "/EFI/BOOT/steamcl-version"
need_file ::/EFI/BOOT/steamcl-restricted  "/EFI/BOOT/steamcl-restricted"
need_file ::/EFI/BOOT/fonts/default.pf2   "/EFI/BOOT/fonts/default.pf2"
need_file ::/EFI/steamos/grubenv          "/EFI/steamos/grubenv"
need_file ::/SteamOS/conf/A.conf          "/SteamOS/conf/A.conf"
# B.conf must be PRESENT when B is populated and ABSENT when it is not -- the absence is what stops
# steamcl's set_menu_conf() alt-entry pick from handing a 6-times-failed A over to a slot with no
# kernel (images/make-sdcard.sh documents the mechanism). A B.conf on a card with an empty B is a
# real defect, not a leftover, so assert it rather than skipping the check.
if [ "$SLOT_B" = 1 ]; then
  need_file ::/SteamOS/conf/B.conf        "/SteamOS/conf/B.conf"
else
  mtype -i "$IMG@@$espoff" ::/SteamOS/conf/B.conf >/dev/null 2>&1 \
    && bad "B.conf present on a card with an empty slot B — steamcl would offer B as a boot candidate" \
    || ok "no B.conf (empty slot B is not a boot candidate)"
fi
# steamcl-restricted must be present and EMPTY (it gates steamcl's own-device-only behaviour;
# presence matters, content does not).
mtype -i "$IMG@@$espoff" ::/EFI/BOOT/steamcl-restricted >"$T/f" 2>/dev/null \
  && { [ -s "$T/f" ] && bad "steamcl-restricted should be empty" || ok "steamcl-restricted present and empty"; } \
  || bad "/EFI/BOOT/steamcl-restricted missing"
# A stale /KERNEL or /NOVADECK would mean this card was laid by the pre-Phase-5 assembler; catch it here so it cannot be flashed by habit.
mdir -i "$IMG@@$espoff" ::/KERNEL >/dev/null 2>&1 && bad "/KERNEL present on a Phase 5 card" \
                                                   || ok "no /KERNEL"
mdir -i "$IMG@@$espoff" ::/NOVADECK >/dev/null 2>&1 && bad "/NOVADECK present on a Phase 5 card" \
                                                      || ok "no /NOVADECK"
# confs: A is seeded with the newest boot-requested-at so the first boot picks A; B is 0. Both
# must be the bootconf key: value format (any non-empty value line parses; these are the seeds).
mtype -i "$IMG@@$espoff" ::/SteamOS/conf/A.conf >"$T/conf_a" 2>/dev/null || true
a_stamp=$(sed -n 's/^boot-requested-at: //p' "$T/conf_a")
case "$a_stamp" in [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9])
  ok "A.conf boot-requested-at = $a_stamp" ;;
*) bad "A.conf has no valid boot-requested-at (got '$a_stamp')" ;; esac
if [ "$SLOT_B" = 1 ]; then
  mtype -i "$IMG@@$espoff" ::/SteamOS/conf/B.conf >"$T/conf_b" 2>/dev/null || true
  b_stamp=$(sed -n 's/^boot-requested-at: //p' "$T/conf_b")
  [ "$b_stamp" = 0 ] && ok "B.conf boot-requested-at = 0" || bad "B.conf boot-requested-at should be 0, got '$b_stamp'"
  [ "$a_stamp" -gt "$b_stamp" ] 2>/dev/null && ok "A is the newer image (first boot picks A)" \
                                            || bad "A is not the newer image"
fi
# the seeded grubenv is a real GRUB env block, so GRUB's first save_env has a file to write.
mtype -i "$IMG@@$espoff" ::/EFI/steamos/grubenv >"$T/grubenv" 2>/dev/null || true
grep -aq "GRUB Environment Block" "$T/grubenv" && ok "grubenv is a valid GRUB env block" \
                                              || bad "grubenv has no GRUB magic header"

# ----------------------------------------------------------------------------------------------
# 4. efi-a / efi-b (stage 2 homes). steamcl chainloads \EFI\steamos\grubaa64.efi on the slot's
# efi partition, matching its own partition uuid against partsets/self and reading the ESP uuid
# from partsets/all. A wrong uuid anywhere here breaks the boot handoff.
# ----------------------------------------------------------------------------------------------
echo "  4. efi-a / efi-b (stage 2)"
check_efi() {  # <partnum> <letter> <self> <other>
  local p=$1 letter=$2 self=$3 other=$4 off
  off=$(( $(start "$p") * 512 ))
  for f in ::/EFI/steamos/grubaa64.efi ::/EFI/steamos/grub.cfg \
           ::/EFI/steamos/fonts/dejavu-mono.pf2 ::/EFI/steamos/parts.env; do
    mtype -i "$IMG@@$off" "$f" >"$T/f" 2>/dev/null && ok "p$p$f present" || bad "p$p$f missing"
  done

  # parts.env: where our eight partitions are on THIS medium, read by the stage-2 grub.cfg before it
  # can address anything. On a card the values equal the generator's build-time defaults, so a wrong
  # one is invisible at boot — which is exactly why it is asserted here against the same table both
  # sides derive from. A card whose map disagrees with its own GPT is a card that would boot fine and
  # then teach the installer's reader the wrong lesson.
  mtype -i "$IMG@@$off" ::/EFI/steamos/parts.env >"$T/parts-$letter.env" 2>/dev/null || true
  grep -aq "GRUB Environment Block" "$T/parts-$letter.env" \
    && ok "p$p parts.env is a valid GRUB env block" \
    || bad "p$p parts.env has no GRUB magic header"
  for kv in "nd_esp=$P_ESP" "nd_efi_a=$P_EFIA" "nd_efi_b=$P_EFIB" \
            "nd_root_a=$P_ROOTA" "nd_root_b=$P_ROOTB" \
            "nd_var_a=$P_VARA" "nd_var_b=$P_VARB" "nd_home=$P_HOME"; do
    grep -aqx -- "$kv" "$T/parts-$letter.env" && ok "p$p parts.env $kv" \
      || bad "p$p parts.env does not carry $kv (the card's map disagrees with ${TABLE#"$ROOT"/})"
  done
  # The shipped grub.cfg must be EXACTLY what boot/gen-grub-cfg.sh produces for THIS slot. One
  # comparison covers the whole class: a stale out/boot from an older build, slot A's config
  # written onto slot B's partition, or a generator change that never reached the card. What the
  # config has to CONTAIN is asserted by images/test-stage2-grub.sh; this asserts it arrived.
  if [ -x "$ROOT/boot/gen-grub-cfg.sh" ]; then
    if "$ROOT/boot/gen-grub-cfg.sh" "$letter" "$T/expect-$letter.cfg" >/dev/null 2>&1; then
      mtype -i "$IMG@@$off" ::/EFI/steamos/grub.cfg >"$T/oncard-$letter.cfg" 2>/dev/null || true
      cmp -s "$T/expect-$letter.cfg" "$T/oncard-$letter.cfg" \
        && ok "p$p grub.cfg is the current slot-$letter config" \
        || bad "p$p grub.cfg differs from boot/gen-grub-cfg.sh $letter (stale build, or the wrong slot's config)"
    else
      bad "boot/gen-grub-cfg.sh $letter failed"
    fi
  else
    ok "p$p grub.cfg content check skipped (no boot/gen-grub-cfg.sh)"
  fi

  # partsets are 'key value' whitespace-separated (steamcl's format).
  partset() { mtype -i "$IMG@@$off" "::/SteamOS/partsets/$1" 2>/dev/null; }
  for n in A B all shared self other; do
    partset "$n" >/dev/null 2>&1 && ok "p$p partsets/$n present" || bad "p$p partsets/$n missing"
  done
  # The identity matrix. self must name THIS partition; other the sibling; all/shared the ESP;
  # A/B the two efi uuids — on both slots, so the partsets are slot-invariant except self/other.
  [ "$(partset self)"  = "efi $self" ]  && ok "p$p self = $self"  || bad "p$p self: expected 'efi $self', got '$(partset self)'"
  [ "$(partset other)" = "efi $other" ] && ok "p$p other = $other" || bad "p$p other: expected 'efi $other', got '$(partset other)'"
  [ "$(partset all)"   = "esp $ESP_UUID" ] && ok "p$p all = esp $ESP_UUID"  || bad "p$p all is wrong"
  [ "$(partset shared)" = "esp $ESP_UUID" ] && ok "p$p shared = esp $ESP_UUID" || bad "p$p shared is wrong"
  [ "$(partset A)"      = "efi $EFIA_UUID" ] && ok "p$p A = $EFIA_UUID" || bad "p$p A is wrong"
  [ "$(partset B)"      = "efi $EFIB_UUID" ] && ok "p$p B = $EFIB_UUID" || bad "p$p B is wrong"
}
check_efi "$P_EFIA" A "$EFIA_UUID" "$EFIB_UUID"
check_efi "$P_EFIB" B "$EFIB_UUID" "$EFIA_UUID"

# ----------------------------------------------------------------------------------------------
# 5. The initramfs actually carries what the boot path needs. The phase-5 init mounts root (ro) +
# var + the slot's efi partition at /efi (inside the btrfs root, so the mount survives
# switch_root), stacks the /etc overlay and hands off to systemd. The ESP is NOT mounted here —
# the booted system mounts it at /esp from /etc/fstab.
# ----------------------------------------------------------------------------------------------
echo "  5. initramfs"
if [ -f "$INITRAMFS" ]; then
  ( cd "$T" && gzip -dc "$INITRAMFS" | cpio -idm --quiet 2>/dev/null )
  for b in mount findfs switch_root; do
    [ -x "$T/usr/bin/$b" ] && ok "$b staged" || bad "$b is NOT in the initramfs"
  done
  grep -q 'steamos.efi=' "$T/init" && ok "init mounts /efi from steamos.efi=PARTUUID=" \
                                    || bad "init has no /efi handoff (steamos.efi=)"
  grep -q 'switch_root "\$SYSROOT"' "$T/init" && ok "init hands off via switch_root" \
                                                || bad "init has no switch_root"
else
  bad "no ${INITRAMFS#"$ROOT"/}"
fi

echo
[ "$FAIL" = 0 ] && echo "  card OK" || echo "  card FAILED verification"
exit "$FAIL"
