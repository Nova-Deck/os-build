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

# --- the boot-attempts counter ------------------------------------------------------------------
# steamenv_init -- NOT steamenv_boot -- is what calls process_boot_config() and increments this
# image's boot-attempts in the ESP conf (grub_cmd_steamenv_init, grub-core/commands/efi/steamenv.c).
# That counter is the BOOTLOADER half of the rollback design: novadeck-boot-good/bad demote a slot
# that boots but fails userspace, and only this catches a slot that never reaches systemd at all.
# The OS clears it again on a good boot -- novadeck-bootctl mark-good runs `steamos-bootconf
# set-mode booted`, which zeroes boot-attempts -- so a healthy slot never accumulates one.
#
# The module is compiled into grubaa64.efi either way (boot/grub.sh MODULES), so turning this on is
# a config change against a byte-identical binary, and turning it back off is deleting one line.
#
# It MUST come before the timeout block below, not after: steamenv_init overwrites timeout and
# timeout_style unconditionally, so a config that sets its own first always loses. See there.
#
# steamenv_boot is deliberately NOT used for the actual boot: it adds UEFI ChainLoader* variable
# poking (Valve firmware, meaningless on ABL), quiet/verbose cmdline juggling, and a redundant
# steamos.efi=PARTUUID= append that novadeck.efi=PARTLABEL= already replaces. Plain `linux` stays.
steamenv_init

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
else
  set default=0
fi

# --- the timeout ---------------------------------------------------------------------------------
# steamenv_init has ALREADY written timeout and timeout_style by this point, unconditionally: -1
# when stage 1 passed steamos-bootmenu, 0 otherwise. Ours therefore has to come AFTER it. Setting
# it first is exactly what broke the first attempt at this — steamenv always won, so a fresh card
# booted menu entry 0 (one specific board) instantly on every device, the wrong DTB meant the boot
# never completed, boot-attempts only climbed, and at >=3 steamcl's failsafe parked the device at
# the menu for good. The reported symptom was "stops at the GRUB board menu", and the menu was the
# LAST link in that chain rather than the first.
#
# The -1 guard is the other half: a -1 here IS stage 1's menu request, and it must survive. Only
# steamenv's timeout=0 gets overridden.
if [ "\$timeout" != "-1" ]; then
  set timeout_style=menu
  if [ -n "\${saved_entry}" ]; then
    set timeout=3
  else
    # Fresh card: nothing can tell us the board, so wait. -1 is "no timeout".
    set timeout=-1
  fi
fi

# The menu stays VISIBLE rather than hidden even once a board is saved. This device has no serial
# console and no keyboard, so a 3s visible menu is a way back after picking the wrong board. Stage
# 1's steamcl-menu flag now also reaches us, through steamenv_init's timeout=-1 above.

loadfont \$prefix/fonts/dejavu-mono.pf2
insmod gfxterm
insmod efi_gop
set gfxpayload=keep
terminal_output gfxterm

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
