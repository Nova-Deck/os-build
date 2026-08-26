#!/usr/bin/env bash
# novadeck stage-2 grub.cfg generator.
#
#   boot/gen-grub-cfg.sh <A|B> <outfile>
#
# Emits the grub.cfg installed as /EFI/steamos/grub.cfg on that slot's efi partition. Pure text:
# no toolchain, no cross-build, no network — so tests/test-stage2-grub.sh can generate and assert
# the real artifact on a bare host. boot/grub.sh calls it twice after building grubaa64.efi.
#
# Two input files, both of which are the single source of truth for what they carry:
#   boot/boards.map              build-time board catalog (id / menu name / dtb / board bootargs)
#   images/partition-table.txt   partition ORDER and GPT labels
#
# THE ONE THING THIS FILE EXISTS TO GET RIGHT is telling GRUB where things are. Stage 2 was
# chainloaded by steamcl off THIS slot's efi partition, so at the top of the script $root is that
# partition — and every other partition we need is on the same disk, at an index that comes from
# parts.env when the medium carries one and from the build-time table when it does not (see the
# "where our eight partitions actually are" block). Deriving from $root beats searching by
# filesystem label, which is what this used to do:
#
#   * A RAUC install writes the bundle's rootfs image to the inactive slot VERBATIM. Until the
#     post-install hook runs, both roots carry the SAME btrfs label and the same fsid, so
#     `search --label novadeck-root-B` is ambiguous exactly when a slot switch is in flight.
#   * A label search silently falls through to whatever else matches. The FAT label of the ESP
#     drifted from NOVADECK to ESP once already and nothing failed loudly; the grubenv simply
#     stopped being found, so the saved board choice never persisted.
#
# The label search is kept as a FALLBACK only, and it is loud when it is used.
#
# For the same reason the cmdline names partitions by PARTUUID rather than PARTLABEL: the eight GPT
# names are identical on every novadeck medium, so with two attached — a card left in after an
# install to internal storage — findfs resolves whichever it enumerates first. The UUIDs are read
# out of the GPT at boot with `probe --part-uuid`, off the disk we were chainloaded from, so they
# are per-disk by construction and survive an update untouched. PARTLABEL remains as the announced
# fallback.
#
# EVERY FALLBACK ARM BELOW PAUSES 10 SECONDS, not 3. These messages are the entire diagnostic on a
# device with no serial console, and gfxterm draws them in the boot font — which is already at the
# only scale lever we have (`grub-mkfont -s 32`, boot/grub.sh) and is still small on a 1080p handheld
# panel held at arm's length. HW-confirmed 2026-08-06 on a Pocket S2: the text was legible but 3s was
# not long enough to read it before the menu painted over.
#
# Waiting for a keypress instead was considered and rejected. `sleep --interruptible` aborts on ESC
# only (grub-core/commands/sleep.c), the power button is wired to the PMIC and never reaches GRUB's
# EFI console input, and — decisively — these arms fire on a USER's device in the field. Blocking on
# input on a machine with no keyboard turns a degraded-but-bootable device into one that looks
# bricked. Loud, then carry on; never wedged.
#
# THE SECOND THING is where the boot-attempts call sits: AFTER terminal_output gfxterm, not before.
# Its predecessor was Valve's steamenv_init, which had to run before any menuentry was defined
# because it overwrote $timeout — so when it wedged on this hardware nothing had been painted and
# nothing could be, and the only symptom was a black screen. novadeck_bootattempts touches no GRUB
# variable, which is what buys the freedom to call it where its output is visible.
set -euo pipefail
shopt -s nullglob

SLOT="${1:-}"
OUTFILE="${2:-}"
case "$SLOT" in
  A|B) ;;
  *) echo "usage: boot/gen-grub-cfg.sh <A|B> <outfile>" >&2; exit 2 ;;
esac
[ -n "$OUTFILE" ] || { echo "usage: boot/gen-grub-cfg.sh <A|B> <outfile>" >&2; exit 2; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BOARDS="$ROOT/boot/boards.map"
TABLE="$ROOT/images/partition-table.txt"
DTS="$ROOT/kernel/dts/qcom"
slot_lc="${SLOT,,}"

for f in "$BOARDS" "$TABLE"; do
  [ -f "$f" ] || { echo "missing input: $f" >&2; exit 1; }
done

# --- partition table lookups ------------------------------------------------------------------
# Row order IS the partition number (images/genpart.sh emits the sgdisk script from the same
# file, so these cannot disagree without genpart.sh disagreeing too).
part_num()   { awk -v n="$1" '/^[[:space:]]*#/||/^[[:space:]]*$/{next} {i++; if ($1==n) {print i; exit}}' "$TABLE"; }
part_label() { awk -v n="$1" '/^[[:space:]]*#/||/^[[:space:]]*$/{next} {if ($1==n) {print $5; exit}}' "$TABLE"; }

P_ESP=$(part_num esp)
P_ROOT=$(part_num "rootfs-$slot_lc")
P_VAR=$(part_num "var-$slot_lc")
L_ROOT=$(part_label "rootfs-$slot_lc")
L_VAR=$(part_label "var-$slot_lc")
L_EFI=$(part_label "efi-$slot_lc")
for v in P_ESP P_ROOT P_VAR L_ROOT L_VAR L_EFI; do
  [ -n "${!v}" ] || { echo "cannot resolve $v from ${TABLE#"$ROOT"/}" >&2; exit 1; }
done

# The ESP fallback searches by CONTENT, not by label. The labels in partition-table.txt are GPT
# partition names, and `search --label` matches the FILESYSTEM label — two different things that
# cannot even hold the same value here, since a FAT label is capped at 11 characters and
# NOVADECK-ESP is twelve. Searching for a file the ESP is the only partition to carry needs no
# agreement between this generator and the card assembler at all, which is the point: the last
# version of this config searched for a FAT label that images/make-sdcard.sh had stopped writing,
# and nothing failed — the grubenv simply went missing.
ESP_MARKER="/SteamOS/conf/$SLOT.conf"

# --- the common kernel command line -------------------------------------------------------------
# Board-specific args come from boards.map; root=/novadeck.var=/novadeck.efi=/novadeck.slot= are
# per-slot and added per menuentry. This replaces the old boot/cmdline file, which the android-bootimg backend
# baked into the image header: with a UEFI chain the EFI stub OVERWRITES /chosen/bootargs with
# GRUB's command line, so every argument has to be on the `linux` line or it is not applied.
BOOT_CMDLINE="quiet video=efifb:off console=tty0 cgroup.memory=nokmem,nosocket nosoftlockup panic=5"

# --- board catalog ------------------------------------------------------------------------------
declare -a pids=() pnames=() pdtbs=() pbootargs=()
while IFS=$'\t' read -r id name dtb bootargs; do
  [ -n "$id" ] || continue
  [[ $id == \#* ]] && continue
  [ -n "$dtb" ] || continue
  pids+=( "$id" ); pnames+=( "$name" ); pdtbs+=( "$dtb" ); pbootargs+=( "$bootargs" )
done < "$BOARDS"
[ "${#pids[@]}" -gt 0 ] || { echo "no board rows in ${BOARDS#"$ROOT"/}" >&2; exit 1; }

emit_entry() {  # <id> <name> <dtb> <board bootargs>
  local eid=$1 ename=$2 edtb=$3 ebootargs=$4
  cat <<EOF
menuentry '${ename:-$eid}' --id $eid {
  savedefault
  linux (\$slotroot)/boot/Image $BOOT_CMDLINE $ebootargs root=\$rootspec rootfstype=btrfs rootwait ro novadeck.var=\$varspec novadeck.efi=\$efispec novadeck.slot=$SLOT
  initrd (\$slotroot)/boot/initramfs-novadeck.img
  devicetree (\$slotroot)/boot/dtbs/${edtb}.dtb
}

EOF
}

{
cat <<EOF
# novadeck stage-2 grub.cfg — slot $SLOT. GENERATED by boot/gen-grub-cfg.sh; do not edit.
# Installed as /EFI/steamos/grub.cfg on the $L_EFI partition, chainloaded by steamcl.

insmod part_gpt
insmod fat
insmod btrfs
insmod loadenv
insmod regexp

# --- where our eight partitions actually are ----------------------------------------------------
# The indices are the one thing in this config an install to internal storage can invalidate. On a
# card images/genpart.sh owns the whole medium and lays us down at 1..8, so the build-time constants
# below are right by construction. An internal install APPENDS our eight to the OEM's existing GPT
# instead, and where that lands is a per-vendor fact — userdata is sda11 on the AYANEO-family boards
# and sda17 on the Odin 2 — so a baked gpt1 would address an OEM partition.
#
# Stage 2 cannot work them out for itself. Searching by label is the exact ambiguity the PARTUUID
# work below exists to kill; \`probe --part-uuid\` needs the index before it can return anything and
# has no --part-label to go the other way; and GRUB script has no arithmetic. So whoever CREATED the
# partitions writes the numbers down — images/make-sdcard.sh for a card, the installer for an
# internal install — and this reads them back.
#
# THE FILE IS ON THIS SLOT'S EFI PARTITION, NOT THE SHARED ESP, and that is forced rather than
# chosen: locating the ESP is itself one of the numbers, so an ESP-resident map cannot be read
# without already knowing what it says. (\$root) is the partition steamcl chainloaded us from, which
# makes it the one place reachable with no index at all. It survives an update because the efi
# partition is not a RAUC slot and fs-overlay/usr/lib/rauc/post-install.sh only copies files onto
# it — unlike /var, which that hook reformats.
#
# Defaults first and the env second, mirroring the PARTLABEL→PARTUUID upgrade further down. The
# upgrade is ALL-OR-NOTHING: a file missing a key must never produce a map half from the install and
# half from this build, because a root from one layout with a /var from another is worse than either
# on its own. That is also why the loaded names differ from the consumed ones — load_env cannot
# rename, so loading straight into esp_idx would destroy the default before it could be judged. A
# MISSING file is silent: that is every card built before this landed, and it is not an error.
set esp_idx=$P_ESP
set root_idx=$P_ROOT
set var_idx=$P_VAR
if [ -f (\$root)/EFI/steamos/parts.env ]; then
  load_env -f (\$root)/EFI/steamos/parts.env nd_esp nd_efi_a nd_efi_b nd_root_a nd_root_b nd_var_a nd_var_b nd_home
  if [ -n "\$nd_esp" -a -n "\$nd_root_$slot_lc" -a -n "\$nd_var_$slot_lc" ]; then
    set esp_idx="\$nd_esp"
    set root_idx="\$nd_root_$slot_lc"
    set var_idx="\$nd_var_$slot_lc"
  else
    echo "novadeck: parts.env on this efi partition is incomplete."
    echo "novadeck: Using the built-in partition indices, which are right only on"
    echo "novadeck: a medium novadeck laid out by itself."
    sleep 10
  fi
fi

# --- locate the ESP and this slot's root --------------------------------------------------------
# \$root is the efi partition steamcl chainloaded us from, and it is the BARE device name --
# hd0,gpt$((P_ESP + 1)), with NO parentheses. That is why every path below writes (\$root)/... :
# grub_set_prefix_and_root() wraps the device in parens only when it builds \$prefix
# (kern/main.c: grub_env_set "root" gets the bare device). Matching \(...\) here never fires,
# which cost one hardware boot: the derivation silently failed, the fallback search ran, and the
# only symptom was a message and a 3s pause before the menu. The optional parens are kept so this
# works either way.
regexp -s bootdisk '^\\(?([^,)]+),gpt[0-9]+\\)?\$' "\$root"
if [ -n "\$bootdisk" ]; then
  set esp="\$bootdisk,gpt\$esp_idx"
  set slotroot="\$bootdisk,gpt\$root_idx"
  probe --part-uuid --set=rootuuid (\$slotroot)
  probe --part-uuid --set=varuuid  (\$bootdisk,gpt\$var_idx)
  probe --part-uuid --set=efiuuid  (\$root)
else
  echo "novadeck: cannot derive the boot disk from '\$root' — falling back to a filesystem search"
  search --no-floppy --file $ESP_MARKER --set esp
  search --no-floppy --label $L_ROOT --set slotroot
  sleep 10
fi

# --- how the kernel is told which partitions to mount -------------------------------------------
# PARTLABEL is the FALLBACK, not the answer. Every novadeck disk carries the same eight GPT names,
# so the moment a second one is attached — a card left inserted after an install to internal
# storage, or a card being imaged on a running device — findfs picks one of them and the choice is
# nondeterministic. The PARTUUIDs above are unique per partition and are derived from the disk
# GRUB was chainloaded off, at boot, so they cannot name the wrong disk and no update has to
# rewrite them.
#
# Three ways this can come back empty and they all end here: probe absent from the embedded module
# set (boot/grub.sh MODULES), the boot-disk derivation above having failed, or a device that has
# no partition at all — the last of which sets the literal string "none" rather than failing, which
# is why the test below checks for it by name. The fallback is the exact cmdline that shipped
# before, so it is known-good; it is announced and paused because "ambiguous when two novadeck
# disks are present" is not a state to enter silently on a device with no serial console.
set rootspec="PARTLABEL=$L_ROOT"
set varspec="PARTLABEL=$L_VAR"
set efispec="PARTLABEL=$L_EFI"
if [ -n "\$rootuuid" -a "\$rootuuid" != "none" -a -n "\$varuuid" -a "\$varuuid" != "none" -a -n "\$efiuuid" -a "\$efiuuid" != "none" ]; then
  set rootspec="PARTUUID=\$rootuuid"
  set varspec="PARTUUID=\$varuuid"
  set efispec="PARTUUID=\$efiuuid"
else
  echo "novadeck: PARTUUID derivation failed — falling back to PARTLABEL."
  echo "novadeck: With another novadeck medium attached this can boot the WRONG one:"
  echo "novadeck: remove all but one and reboot."
  sleep 10
fi

# --- the saved board choice ---------------------------------------------------------------------
# One image serves every board, so the DTB — and therefore the menu entry — is the ONE thing the
# user has to tell us. It is saved on the shared ESP rather than on this slot's efi partition so it
# survives a slot switch and an update.
#
# savedefault is NOT a GRUB builtin. grub-mkconfig emits it as a shell function in the config it
# generates, and a config that calls it without defining it just prints "unknown command" per
# menuentry and saves nothing.
load_env -f (\$esp)/EFI/steamos/grubenv saved_entry
function savedefault {
  saved_entry="\${chosen}"
  save_env -f (\$esp)/EFI/steamos/grubenv saved_entry
}

if [ -n "\${saved_entry}" ]; then
  set default="\${saved_entry}"
  set timeout_style=menu
  set timeout=3
else
  # Fresh card: nothing can tell us the board, so wait. -1 is "no timeout".
  set default=0
  set timeout_style=menu
  set timeout=-1
fi

# The menu stays VISIBLE rather than hidden even once a board is saved. This device has no serial
# console and no keyboard, and stage 1's steamcl-menu flag does not reach stage 2 at all — so a 3s
# visible menu is the only way back after picking the wrong board.

# --- the console ----------------------------------------------------------------------------------
# rotation MUST be set before terminal_output brings gfxterm up. Patch 0001 reads it exactly once,
# in grub_video_fb_create_render_target_from_pointer, when the video driver builds the framebuffer
# render target — setting it after that point is a silent no-op. 270 is the panel's mounting on
# every board in the catalog: the display is portrait-native and the device is held landscape, so
# an unrotated menu paints sideways.
#
# The colours are read by the normal module each time it paints the menu, so their placement does
# not matter the way rotation's does; they are here to keep the whole console block in one place.
set rotation=270
set menu_color_normal=cyan/blue
set menu_color_highlight=white/blue

loadfont \$prefix/fonts/dejavu-mono.pf2
insmod gfxterm
insmod efi_gop
set gfxpayload=keep
terminal_output gfxterm

# --- count this boot attempt ---------------------------------------------------------------------
# Increments boot-attempts: in (\$esp)/SteamOS/conf/$SLOT.conf. novadeck-boot-good clears it once
# the session proves healthy; novadeck-bootctl and RAUC read it to decide a slot is bad. GRUB's own
# fat driver is read-only, so writing the ESP needs a module.
#
# The module prints old -> new on success and an error naming what it tried on failure. The else
# arm exists to hold that error on screen before the menu paints over it.
insmod novadeck
if novadeck_bootattempts $SLOT; then
  true
else
  echo "novadeck: boot-attempts NOT counted for slot $SLOT — this slot cannot fail safe"
  sleep 10
fi

EOF

for i in "${!pids[@]}"; do
  emit_entry "${pids[$i]}" "${pnames[$i]}" "${pdtbs[$i]}" "${pbootargs[$i]}"
done

# Filename-derived entries: any board .dts with no catalog row. The RP6's top-dpad variant is a
# hardware revision with its own DTB but the same board otherwise, so it inherits its parent's
# bootargs by stripping the suffix. Anything else is a catalog gap and fails the build rather than
# shipping a board nobody can select.
for dts in "$DTS"/*.dts; do
  base="$(basename "$dts" .dts)"
  printf '%s\n' "${pdtbs[@]}" | grep -qx "$base" && continue
  parent="${base%-top-dpad}"
  parent_idx=""
  for i in "${!pdtbs[@]}"; do
    [ "${pdtbs[$i]}" = "$parent" ] && parent_idx=$i
  done
  [ -n "$parent_idx" ] || {
    echo "no catalog row for DTB $base and no parent to derive from — add it to boot/boards.map" >&2
    exit 1
  }
  derived_name="$(sed -n 's/^[[:space:]]*model = "\(.*\)";/\1/p' "$dts" | head -1)"
  [ -n "$derived_name" ] || derived_name="${pnames[$parent_idx]} (${base#*-})"
  emit_entry "$base" "$derived_name" "$base" "${pbootargs[$parent_idx]}"
done
} > "$OUTFILE"

echo "  ok   grub.cfg ($SLOT) -> ${OUTFILE#"$ROOT"/}  ($(grep -c '^menuentry ' "$OUTFILE") entries, root=$L_ROOT)"
