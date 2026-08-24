#!/usr/bin/env bash
# Offline tests for the INSTALLER MEDIUM — Phase 6 of .claude/plans/internal-install.plan.md.
#
#   install/test-mkimage.sh
#
# Host-only: no docker, no root, no built tree, no network. Run via `make test`. Peer of
# install/test-mkroot.sh, which covers the ROOT; this covers what gets written around it — the
# two-partition table, the boot chain and the generated grub.cfg.
#
# THE ONE THAT EARNS ITS KEEP IS THE DTB PARITY CHECK. install/gen-grub-cfg.sh and
# boot/gen-grub-cfg.sh read the SAME board catalog (boot/boards.map) but emit different configs,
# and the derivation rule for a catalog-less .dts is subtle: the parent is found by stripping the
# literal `-top-dpad` suffix, not by dropping the last dash-segment, and the menu title comes from
# the .dts `model =` line. I hand-copied that wrong while writing the installer generator and it
# failed on the single board it exists for. A divergence that does NOT fail the build is worse: a
# board that boots from a card and not from the installer, found on hardware, on the tool you reach
# for when the device is already broken. So the two generators are required to name the same DTBs.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TABLE="$ROOT/install/medium-table.txt"
GENCFG="$ROOT/install/gen-grub-cfg.sh"
MKIMAGE="$ROOT/install/mkimage.sh"
SHIPPED_GENCFG="$ROOT/boot/gen-grub-cfg.sh"
DTS="$ROOT/kernel/dts/qcom"

PASS=0; FAIL=0; SKIP=0; CASE=""
ok()   { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }
skip() { SKIP=$((SKIP+1)); printf '  skip %s -- %s\n' "$CASE" "$1"; }

for f in "$TABLE" "$GENCFG" "$MKIMAGE" "$SHIPPED_GENCFG"; do
  [ -e "$f" ] || { echo "missing input: $f" >&2; exit 1; }
done
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

rows() { grep -vE '^[[:space:]]*(#|$)' "$TABLE"; }

# ---------------------------------------------------------------------------------------------
CASE="medium-table"
n=$(rows | wc -l)
[ "$n" -eq 2 ] && ok "declares exactly 2 partitions" \
  || bad "declares $n partitions — the medium has no slots and needs no more"

read -r _ esp_size esp_type esp_fs esp_label _ < <(rows | sed -n 1p)
read -r rt_name rt_size rt_type _ rt_label _ < <(rows | sed -n 2p)

[ "$esp_type" = ef00 ] && ok "p1 is ef00 (ABL finds the ESP by type GUID)" \
  || bad "p1 type is $esp_type, not ef00 — ABL would not find it"
[ "$esp_fs" = vfat ] && ok "p1 is vfat" || bad "p1 fs is $esp_fs"
[ "$rt_name" = root ] && ok "p2 is the root" || bad "p2 is named $rt_name"
[ "$rt_size" = rest ] && ok "p2 takes the rest of the medium" \
  || bad "p2 is fixed at $rt_size — the root is sized by what got built"

# 11 characters is all a FAT label has room for; a longer one is silently truncated by mkfs.vfat,
# and then nothing that searches for it finds it.
[ "${#esp_label}" -le 11 ] && ok "the ESP label fits FAT ($esp_label, ${#esp_label} chars)" \
  || bad "the ESP label $esp_label is ${#esp_label} chars — FAT holds 11"
# It must NOT be one of the install's own labels: a dev card and an internal install already share
# those, and an installer whose /esp matched the TARGET's would write its failure log onto the disk
# it just failed to install.
case "$esp_label" in
  [Nn][Oo][Vv][Aa][Dd][Ee][Cc][Kk]*) bad "the ESP label is a novadeck-* one — it would collide with the target" ;;
  *) ok "the ESP label does not collide with an install's labels" ;;
esac
grep -q 'NDINSTALLER' "$ROOT/install/mkroot.sh" \
  && ok "mkroot.sh's fstab entry names the same label" \
  || bad "mkroot.sh does not mention NDINSTALLER — /esp would never mount"

# ---------------------------------------------------------------------------------------------
CASE="grub.cfg"
UUID=deadbeef-0000-1111-2222-333344445555
if ! "$GENCFG" "$UUID" "$T/installer.cfg" >/dev/null 2>"$T/err"; then
  bad "the generator failed: $(head -1 "$T/err")"
else
  ok "generates against a partition uuid"
  cfg="$T/installer.cfg"
  entries=$(grep -c '^menuentry ' "$cfg")
  [ "$entries" -gt 0 ] && ok "emits $entries menuentries" || bad "emits no menuentries"

  # Every board gets a normal entry and a debug twin, so the count is even and the halves match.
  normal=$(grep -c "^menuentry .* --id [a-z0-9-]*[^g] {$" "$cfg")
  debug=$(grep -c -- '--id .*-debug {$' "$cfg")
  [ "$debug" -gt 0 ] && ok "$debug debug-console entries" || bad "no debug entries"
  [ $((entries % 2)) -eq 0 ] && [ "$debug" -eq $((entries / 2)) ] \
    && ok "every board has exactly one debug twin" \
    || bad "$entries entries but $debug debug ones — the halves do not match"

  # The debug arg is what hands the panel to a getty instead of gamescope. It must be on the debug
  # entries and on NOTHING else, or every boot skips the GUI.
  d_with=$(grep -c 'novadeck.install.debug' "$cfg")
  [ "$d_with" -eq "$debug" ] \
    && ok "novadeck.install.debug appears on exactly the debug entries" \
    || bad "$d_with lines carry novadeck.install.debug but there are $debug debug entries"

  for want in "rootfstype=squashfs" "systemd.volatile=state" "root=PARTUUID=$UUID" "rootwait" " ro "; do
    grep -q -- "$want" "$cfg" && ok "the kernel line carries '$want'" \
      || bad "the kernel line is missing '$want'"
  done
  # Slot machinery must NOT leak in from the shipped generator: there is one root here, and a
  # novadeck.slot= on the cmdline would have the OS looking for a slot that does not exist.
  for unwanted in "novadeck.slot=" "novadeck.var=" "novadeck.efi=" "rootfstype=btrfs" "slotroot"; do
    grep -q -- "$unwanted" "$cfg" \
      && bad "the config carries '$unwanted' — that is slot machinery, and this medium has no slots" \
      || ok "no '$unwanted'"
  done
  # Boot-attempt counting demotes a slot that cannot boot. There is nothing to demote to here, so
  # it could only ever stop the recovery medium from starting.
  grep -q 'novadeck_bootattempts' "$cfg" \
    && bad "the config counts boot attempts — the medium would refuse itself" \
    || ok "no boot-attempt counting"

  # rotation is read ONCE, when the video driver builds the render target. Set after
  # terminal_output it is a silent no-op and the menu paints sideways on every board.
  rot=$(grep -n '^set rotation=' "$cfg" | head -1 | cut -d: -f1)
  tout=$(grep -n '^terminal_output gfxterm' "$cfg" | head -1 | cut -d: -f1)
  if [ -n "$rot" ] && [ -n "$tout" ] && [ "$rot" -lt "$tout" ]; then
    ok "rotation is set before terminal_output (line $rot < $tout)"
  else
    bad "rotation must be set BEFORE terminal_output (rotation=$rot terminal_output=$tout)"
  fi
  # savedefault is not a builtin; a config that calls it without defining it saves nothing and the
  # user re-picks their board on every boot.
  grep -q '^function savedefault' "$cfg" && ok "savedefault is defined, not just called" \
    || bad "savedefault is called but never defined — the board choice would never persist"

  # Every dtb the config names must exist as a source .dts, or the entry is unbootable.
  missing=0
  while read -r d; do
    [ -f "$DTS/$d.dts" ] || { bad "menuentry references $d.dtb, which has no .dts"; missing=1; }
  done < <(grep -o 'devicetree /dtbs/[^ ]*\.dtb' "$cfg" | sed 's|.*/||; s|\.dtb$||' | sort -u)
  [ "$missing" -eq 0 ] && ok "every referenced dtb has a source .dts"
fi

# ---------------------------------------------------------------------------------------------
CASE="dtb parity with the shipped generator"
# See the header: the catalog is shared data, the derivation rule is subtle, and a divergence is a
# board that boots from a card but not from the installer.
if "$SHIPPED_GENCFG" A "$T/shipped.cfg" >/dev/null 2>"$T/err2"; then
  grep -o 'devicetree [^ ]*/dtbs/[^ ]*\.dtb' "$T/shipped.cfg"   | sed 's|.*/||; s|\.dtb$||' | sort -u >"$T/shipped.dtbs"
  grep -o 'devicetree /dtbs/[^ ]*\.dtb' "$T/installer.cfg" | sed 's|.*/||; s|\.dtb$||' | sort -u >"$T/installer.dtbs"
  s=$(wc -l <"$T/shipped.dtbs"); i=$(wc -l <"$T/installer.dtbs")
  if diff -q "$T/shipped.dtbs" "$T/installer.dtbs" >/dev/null; then
    ok "both generators name the same $i DTBs"
  else
    bad "DTB sets differ (shipped $s, installer $i): $(diff "$T/shipped.dtbs" "$T/installer.dtbs" | tr '\n' ' ')"
  fi
else
  skip "the shipped generator did not run here: $(head -1 "$T/err2")"
fi

# ---------------------------------------------------------------------------------------------
CASE="mkimage guards"
# The argument is positional and both trees are directories full of a Linux system, so picking the
# wrong one is a one-word mistake that would produce an "installer" with no install code on it.
grep -q 'ID=novadeck-installer' "$MKIMAGE" \
  && ok "refuses a tree that does not identify as the installer" \
  || bad "mkimage.sh does not check which tree it was handed"
grep -q 'usr/lib/novadeck/pkgs' "$MKIMAGE" \
  && ok "refuses a half-finished bootstrap (checks the completion marker)" \
  || bad "mkimage.sh does not check the bootstrap completed"
grep -q 'NOVADECK_PARTITION_TABLE' "$MKIMAGE" \
  && ok "points genpart.sh at the medium table, not the shipped one" \
  || bad "mkimage.sh does not override the partition table — it would lay the 8-partition layout"
# steamcl is the A/B slot chooser. On a one-root medium its conf files would be fiction.
grep -qi 'steamcl' "$MKIMAGE" && grep -q 'mcopy.*steamcl' "$MKIMAGE" \
  && bad "mkimage.sh installs steamcl — there are no slots for it to choose between" \
  || ok "no steamcl on the medium (GRUB goes straight in at bootaa64.efi)"
grep -q 'EFI/BOOT/bootaa64.efi' "$MKIMAGE" \
  && ok "GRUB is at the removable-media path ABL loads" \
  || bad "nothing is written to /EFI/BOOT/bootaa64.efi — ABL would find nothing to boot"
# GRUB's prefix is baked in at build time as /EFI/steamos, relative to the partition it loads from.
grep -q 'EFI/steamos/grub.cfg' "$MKIMAGE" \
  && ok "the config is at \$prefix (/EFI/steamos/grub.cfg)" \
  || bad "the config is not at the prefix boot/grub.sh builds in"
grep -q 'grub-editenv' "$MKIMAGE" \
  && ok "a pristine grubenv is created (else the board choice cannot be saved)" \
  || bad "no grubenv — save_env would fail and the board would be re-picked every boot"

printf '\ntest-mkimage.sh: %d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
