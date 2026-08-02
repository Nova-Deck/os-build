#!/usr/bin/env bash
# novadeck stage-2 grub.cfg generator.
#
#   boot/gen-grub-cfg.sh <A|B> <outfile>
#
# Emits the grub.cfg installed as /EFI/steamos/grub.cfg on that slot's efi partition. Pure text:
# no toolchain, no cross-build, no network — so images/test-stage2-grub.sh can generate and assert
# the real artifact on a bare host. boot/grub.sh calls it twice after building grubaa64.efi.
#
# Two input files, both of which are the single source of truth for what they carry:
#   boot/boards.map              build-time board catalog (id / menu name / dtb / board bootargs)
#   images/partition-table.txt   partition ORDER and GPT labels
#
# THE ONE THING THIS FILE EXISTS TO GET RIGHT is telling GRUB where things are. Stage 2 was
# chainloaded by steamcl off THIS slot's efi partition, so at the top of the script $root is that
# partition — and every other partition we need is on the same disk at a fixed index. Deriving
# from $root beats searching by filesystem label, which is what this used to do:
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
L_ROOT=$(part_label "rootfs-$slot_lc")
L_VAR=$(part_label "var-$slot_lc")
L_EFI=$(part_label "efi-$slot_lc")
for v in P_ESP P_ROOT L_ROOT L_VAR L_EFI; do
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
# Board-specific args come from boards.map; root=/novadeck.var=/novadeck.efi= are per-slot and
# added per menuentry. This replaces the old boot/cmdline file, which the android-bootimg backend
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
  linux (\$slotroot)/boot/Image $BOOT_CMDLINE $ebootargs root=PARTLABEL=$L_ROOT rootfstype=btrfs rootwait ro novadeck.var=PARTLABEL=$L_VAR novadeck.efi=PARTLABEL=$L_EFI
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
  set esp="\$bootdisk,gpt$P_ESP"
  set slotroot="\$bootdisk,gpt$P_ROOT"
else
  echo "novadeck: cannot derive the boot disk from '\$root' — falling back to a filesystem search"
  search --no-floppy --file $ESP_MARKER --set esp
  search --no-floppy --label $L_ROOT --set slotroot
  sleep 3
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
# arm exists to hold that error on screen for the 5s before the menu paints over it.
insmod novadeck
if novadeck_bootattempts $SLOT; then
  true
else
  echo "novadeck: boot-attempts NOT counted for slot $SLOT — this slot cannot fail safe"
  sleep 5
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
