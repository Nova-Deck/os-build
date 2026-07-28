#!/usr/bin/env bash
# Offline verification of a built A/B card image — out/images/sdcard.img.
#
# Same doctrine as images/guard-rootfs.sh: assert the BUILT ARTIFACT, not the source diff. That
# guard stops at the staged tree (it runs before mkfs), so nothing checked the partition table,
# the ESP contents, or the filesystem identities the A/B switch depends on. This closes that gap
# for the parts a slot switch can be silently wrong about.
#
# It matters most for one thing that is invisible until hardware contradicts you: the two roots
# are content-identical by design, so if they also share a btrfs fsid then mounting slot B can
# hand you slot A, and every slot test after that is meaningless. That check is why this exists.
#
# Everything here is unprivileged — dd out a superblock and ask blkid, read ext4 with debugfs,
# read the ESP with mtools. No loop mounts, no root.
#
# Run inside the build image (needs sgdisk, blkid, debugfs, mtools, cpio):
#   docker run --rm -v "$PWD":/src -w /src novadeck-build images/verify-card.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMG="${1:-$ROOT/out/images/sdcard.img}"
TABLE="$ROOT/images/partition-table.txt"
INITRAMFS="$ROOT/out/initramfs.cpio.gz"

[ -f "$IMG" ] || { echo "no card image: $IMG (run make sdcard)" >&2; exit 1; }
for t in sgdisk blkid debugfs mdir mtype cpio; do
  command -v "$t" >/dev/null 2>&1 || { echo "$t not found — run inside novadeck-build" >&2; exit 1; }
done

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export MTOOLS_SKIP_CHECK=1
FAIL=0
ok()  { printf '    ok  %s\n' "$1"; }
bad() { printf '    !!  %s\n' "$1"; FAIL=1; }

part_num() { awk -v n="$1" '/^[[:space:]]*#/||/^[[:space:]]*$/{next} {i++; if ($1==n) {print i; exit}}' "$TABLE"; }
start()    { sgdisk -i "$1" "$IMG" | sed -n 's/^First sector: \([0-9]*\).*/\1/p'; }

P_ESP=$(part_num esp)
P_ROOTA=$(part_num rootfs-a); P_ROOTB=$(part_num rootfs-b)
P_VARA=$(part_num var-a);     P_VARB=$(part_num var-b)

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
  ok "slot B is empty (NOVADECK_SLOT_B=0) — skipping the A/B identity checks"
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

# ----------------------------------------------------------------------------------------------
# 2. The independent slot witness. /run/novadeck/boot records what the initramfs THINKS it picked;
# this file records which var actually mounted. It is the only cross-check that does not share a
# failure mode with the selection code.
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
# 3. The ESP: the boot image, and the slot state the initramfs reads before anything else.
# ----------------------------------------------------------------------------------------------
echo "  3. ESP"
espoff=$(( $(start "$P_ESP") * 512 ))
mdir -i "$IMG@@$espoff" ::/KERNEL >/dev/null 2>&1 && ok "/KERNEL present" || bad "/KERNEL missing"
if mtype -i "$IMG@@$espoff" ::/NOVADECK/STATE.0 >"$T/state" 2>/dev/null && [ -s "$T/state" ]; then
  gen=$(sed -n 's/^gen=//p' "$T/state"); act=$(sed -n 's/^active=//p' "$T/state")
  pend=$(sed -n 's/^pending=//p' "$T/state")
  grep -qx end "$T/state" && ok "STATE.0 terminated by 'end' (gen=$gen active=$act pending='$pend')" \
                          || bad "STATE.0 has no 'end' terminator — the reader will reject it"
  [ "$act" = a ] || bad "a freshly built card should be active=a, not '$act'"
  [ -z "$pend" ] || bad "a freshly built card should have nothing pending, got '$pend'"
  # `kernel=` must be EMPTY here, and that is a real assertion rather than a formality: both slots
  # carry the same rootfs.img on a fresh card, so /KERNEL matches either one. A letter would make
  # the ordinary `try b` slot test warn about a kernel/modules mismatch that does not exist.
  kern=$(sed -n 's/^kernel=//p' "$T/state")
  [ -z "$kern" ] || bad "a fresh card must not claim a /KERNEL owner, got kernel='$kern'"
  # `broken=` must be PRESENT and EMPTY. Present because the initramfs writer emits a fixed field
  # list and a card seeded without it would gain the line on the first write anyway — seeding it
  # keeps the card and the writer describing the same format. Empty because nothing has installed
  # anything yet: a letter here would make `get-state` report bad for a slot straight off the build.
  if grep -q '^broken=' "$T/state"; then
    brk=$(sed -n 's/^broken=//p' "$T/state")
    [ -z "$brk" ] && ok "broken= seeded empty" \
                  || bad "a fresh card must not mark a slot broken, got broken='$brk'"
  else
    bad "STATE.0 has no broken= line — the seed and images/initramfs/init disagree about the format"
  fi
else
  bad "no readable ::/NOVADECK/STATE.0 — every boot would fall back to the cmdline root="
fi
# The seed must occupy exactly one file: the writer alternates, so leaving the other absent is
# what lets the seeded copy survive a torn FIRST write.
mtype -i "$IMG@@$espoff" ::/NOVADECK/STATE.1 >/dev/null 2>&1 \
  && bad "STATE.1 exists on a fresh card — the first write would have nowhere safe to land" \
  || ok "STATE.1 absent"

# ----------------------------------------------------------------------------------------------
# 4. The initramfs actually carries what the boot path needs. A missing umount here is not
# cosmetic: the ESP would stay mounted across switch_root and gpt-auto would mount the same vfat
# device a second time at /efi.
# ----------------------------------------------------------------------------------------------
echo "  4. initramfs"
if [ -f "$INITRAMFS" ]; then
  ( cd "$T" && gzip -dc "$INITRAMFS" | cpio -idm --quiet 2>/dev/null )
  # cp is load-bearing, not a convenience: it is what restores KERNEL.BAK over /KERNEL on a
  # rollback boot. Missing, the rollback silently degrades to "old root under the new kernel" --
  # whose /lib/modules it does not carry, so no Wi-Fi on a device with no serial console.
  for b in umount mount findfs switch_root bash cp; do
    [ -x "$T/usr/bin/$b" ] && ok "$b staged" || bad "$b is NOT in the initramfs"
  done
  [ -d "$T/esp" ] && ok "/esp mountpoint staged" || bad "/esp mountpoint missing — the ESP cannot be mounted"
  grep -q 'NOVADECK-ESP' "$T/init" && ok "init reads the ESP slot state" || bad "init has no slot logic"
else
  bad "no ${INITRAMFS#"$ROOT"/}"
fi

echo
[ "$FAIL" = 0 ] && echo "  card OK" || echo "  card FAILED verification"
exit "$FAIL"
