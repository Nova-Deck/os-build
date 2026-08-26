#!/usr/bin/env bash
# novadeck INSTALLER grub.cfg generator. Phase 6 of .claude/plans/internal-install.plan.md.
#
#   installer/gen-grub-cfg.sh <root-partuuid> <outfile>
#
# Emits the single grub.cfg that lives on the installer medium's ESP at /EFI/steamos/grub.cfg —
# the path GRUB looks in because boot/grub.sh builds the EFI binary with `-p /EFI/steamos`, and
# that prefix is relative to the partition GRUB was loaded from.
#
# WHY THIS IS A SEPARATE GENERATOR FROM boot/gen-grub-cfg.sh, and where the line is drawn. The
# shipped one is slot machinery from top to bottom: it resolves ($slotroot) for A or B, writes
# per-slot root/var/efi specs onto the kernel line, counts a boot attempt into the slot's conf so a
# bad slot can fail safe, and reads the eight-partition table to do it. The installer has ONE root,
# no slots, no var partition, no efi partition, nothing to roll back to and nothing to count. An
# --installer mode there would have been a conditional through nearly every block.
#
# What the two DO share is the thing that actually drifts: **boot/boards.map**, the board catalog.
# Adding a board must not mean remembering to add it twice, so this reads the same file, byte for
# byte, and inherits the same rule that every board DTB is covered by a row or derived from one.
# The console block below is a deliberate ~20-line duplicate; the catalog is not duplicated at all.
#
# THE MENU IS THE BOARD PICKER, and unlike the shipped card it REMEMBERS NOTHING. One image serves
# every board and the DTB is the one thing no autodetection here can settle, so the operator picks —
# every time, with no timeout.
#
# WHY NOT SAVE THE CHOICE, when the shipped card does (user's call, 2026-08-24). The shipped card
# lives in ONE device for its whole life, so a saved board is right there. An installer medium is
# the opposite: it is carried BETWEEN boards, which is the entire point of it. A card that installed
# a Pocket S2 and is then booted on an ACE would preselect the S2's devicetree and boot it after the
# 3s timeout, most likely before the person holding it reacted — and a wrong DTB is a worse outcome
# than a wait. So: no `savedefault`, no `load_env`, no grubenv on the medium at all (nothing else
# here uses one — there is no boot-attempt counting on a medium with nothing to fall back to).
#
# The cost is one d-pad press per boot, which is the correct price for not guessing a stranger's
# hardware. There is no keyboard on these devices, so the d-pad drives the menu.
#
# NO BOOT-ATTEMPT COUNTING. The shipped config increments boot-attempts so a slot that cannot boot
# gets demoted. Nothing here can be demoted TO, so the counter would only be a way for the recovery
# medium to refuse to start.
set -euo pipefail

PARTUUID="${1:-}"
OUTFILE="${2:-}"
[ -n "$PARTUUID" ] && [ -n "$OUTFILE" ] \
  || { echo "usage: installer/gen-grub-cfg.sh <root-partuuid> <outfile>" >&2; exit 2; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BOARDS="$ROOT/boot/boards.map"
DTS="$ROOT/kernel/dts/qcom"
[ -f "$BOARDS" ] || { echo "missing board catalog: ${BOARDS#"$ROOT"/}" >&2; exit 1; }

# --- the common kernel command line ---------------------------------------------------------------
# The first four are the shipped image's BOOT_CMDLINE verbatim (boot/gen-grub-cfg.sh): the EFI stub
# OVERWRITES /chosen/bootargs with GRUB's command line, so anything not on the `linux` line is not
# applied at all. video=efifb:off in particular is load-bearing on these panels.
#
# Then three that are the installer's own, and each buys something specific:
#
#   rootfstype=squashfs   the root is a squashfs image dd'd into p2. CONFIG_SQUASHFS=y and
#                         CONFIG_SQUASHFS_ZSTD=y are both built in, so the kernel mounts it with no
#                         initramfs at all — which is why this medium has none.
#   systemd.volatile=state  /var as a tmpfs over the read-only root. Without it journald, NM's state
#                         directory and everything else under /var is unwritable. /etc is handled
#                         differently (three writers pointed at /run — see installer/mkroot.sh);
#                         `state` is the volatile mode that does NOT need an initrd, which is the
#                         whole reason the pair is split like this rather than using =overlay.
#   systemd.firstboot=off  belt to the braces of the masked systemd-firstboot.service: this kills
#                         PID1's own builtin locale/root-password query, which the mask does not.
BOOT_CMDLINE="quiet video=efifb:off console=tty0 cgroup.memory=nokmem,nosocket nosoftlockup panic=5"
INSTALLER_CMDLINE="root=PARTUUID=$PARTUUID rootfstype=squashfs rootwait ro systemd.volatile=state systemd.firstboot=off"

# --- board catalog, read from the SHARED file -------------------------------------------------------
declare -a pids=() pnames=() pdtbs=() pbootargs=()
while IFS=$'\t' read -r id name dtb bootargs; do
  case "$id" in ''|'#'*) continue ;; esac
  [ -n "$dtb" ] || continue
  pids+=( "$id" ); pnames+=( "$name" ); pdtbs+=( "$dtb" ); pbootargs+=( "$bootargs" )
done < "$BOARDS"
[ "${#pids[@]}" -gt 0 ] || { echo "no board rows in ${BOARDS#"$ROOT"/}" >&2; exit 1; }

# Both the kernel and the dtbs live on the ESP, at the root of the FAT filesystem. On the shipped
# card they live in the slot root's /boot and GRUB reads them out of btrfs; here the root is the
# squashfs we are about to boot, and putting the kernel on FAT keeps GRUB's job to one filesystem
# driver it certainly has.
emit_entry() {  # <id> <name> <dtb> <board bootargs> <suffix> <title-suffix> <extra args>
  local eid=$1 ename=$2 edtb=$3 ebootargs=$4 esuffix=$5 etitle=$6 eextra=$7
  cat >>"$OUTFILE" <<EOF

menuentry '${ename:-$eid}${etitle}' --id ${eid}${esuffix} {
  linux /Image $BOOT_CMDLINE $ebootargs $INSTALLER_CMDLINE $eextra
  devicetree /dtbs/${edtb}.dtb
}
EOF
}

: >"$OUTFILE"
cat >>"$OUTFILE" <<EOF
# novadeck INSTALLER stage-2 GRUB configuration — GENERATED by installer/gen-grub-cfg.sh.
# Do not edit on the medium; rebuild the image.

# NOTHING IS REMEMBERED, deliberately. This medium travels between boards, so a saved choice is a
# card that installed one device silently preselecting its devicetree on the next, different one.
# The menu therefore waits indefinitely, every boot: -1 is "no timeout", and there is no grubenv,
# no load_env and no savedefault anywhere in this file. See the header.
set default=0
set timeout_style=menu
set timeout=-1

# rotation MUST be set before terminal_output brings gfxterm up. Patch 0001 reads it exactly once,
# when the video driver builds the framebuffer render target; setting it afterwards is a silent
# no-op. 270 is the panel's mounting on every board in the catalog — portrait-native display held
# landscape, so an unrotated menu paints sideways.
set rotation=270
set menu_color_normal=cyan/blue
set menu_color_highlight=white/blue

loadfont \$prefix/fonts/dejavu-mono.pf2
insmod gfxterm
insmod efi_gop
set gfxpayload=keep
terminal_output gfxterm
EOF

# Two entries per board: the normal one, and a debug one that skips the GUI.
#
# THE DEBUG ENTRY IS NOT A CONVENIENCE, it is the only way to pass that argument on this hardware.
# novadeck-installer.service carries ConditionKernelCommandLine=!novadeck.install.debug, so the arg
# hands the panel to a plain getty instead of gamescope — the documented escape hatch when the GUI
# is what is broken. Editing a menuentry with `e` needs a keyboard, and these devices have none;
# there is no serial console either ([[sm8650-no-uart]]). So it has to be a menu entry, and it has
# to be per board, because it still needs the right DTB to reach a console at all.
for i in "${!pids[@]}"; do
  emit_entry "${pids[$i]}" "${pnames[$i]}" "${pdtbs[$i]}" "${pbootargs[$i]}" "" "" ""
done
for i in "${!pids[@]}"; do
  emit_entry "${pids[$i]}" "${pnames[$i]}" "${pdtbs[$i]}" "${pbootargs[$i]}" \
             "-debug" "  (debug console, no GUI)" "novadeck.install.debug"
done

# Filename-derived entries: any board .dts with no catalog row. The RP6's top-dpad variant is a
# hardware revision with its own DTB but the same board otherwise, so it inherits its parent's
# bootargs by stripping the suffix. Anything else is a catalog gap and fails the build rather than
# shipping a board nobody can select.
#
# THE RULE IS `-top-dpad`, NOT a generic last-segment strip, and the derived NAME comes from the
# .dts `model =` line rather than being synthesized. Both mirror boot/gen-grub-cfg.sh exactly. I
# hand-copied this wrong the first time and it failed on the one board it exists for, which is why
# tests/test-mkroot.sh now asserts the two generators emit the SAME set of DTB names — the
# catalog is shared data, so a divergence here is a board that boots from a card and not from the
# installer, discovered on hardware.
for dts in "$DTS"/*.dts; do
  [ -e "$dts" ] || continue
  base="$(basename "$dts" .dts)"
  printf '%s\n' "${pdtbs[@]}" | grep -qx "$base" && continue
  parent="${base%-top-dpad}"
  parent_idx=""
  for i in "${!pdtbs[@]}"; do
    [ "${pdtbs[$i]}" = "$parent" ] && parent_idx=$i
  done
  [ -n "$parent_idx" ] \
    || { echo "no catalog row for DTB $base and no parent to derive from — add it to boot/boards.map" >&2; exit 1; }
  derived_name="$(sed -n 's/^[[:space:]]*model = "\(.*\)";/\1/p' "$dts" | head -1)"
  [ -n "$derived_name" ] || derived_name="${pnames[$parent_idx]} (${base#*-})"
  emit_entry "$base" "$derived_name" "$base" "${pbootargs[$parent_idx]}" "" "" ""
  emit_entry "$base" "$derived_name" "$base" "${pbootargs[$parent_idx]}" \
             "-debug" "  (debug console, no GUI)" "novadeck.install.debug"
done

echo "  ok   installer grub.cfg -> ${OUTFILE#"$ROOT"/}  ($(grep -c '^menuentry ' "$OUTFILE") entries, root=PARTUUID=$PARTUUID)" >&2
