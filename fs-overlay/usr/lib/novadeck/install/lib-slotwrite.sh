# novadeck slot-write primitives — Phase 2 of .claude/plans/internal-install.plan.md.
#
# SOURCED, never executed (hence mode 0644, like gamescope-display.sh and power-ops.sh).
#
# WHY THIS FILE EXISTS: everything a RAUC bundle does NOT carry has to be written twice -- once by
# the OTA path (fs-overlay/usr/lib/rauc/post-install.sh) and once by the internal installer, which
# writes the same artifacts onto a disk that has no novadeck on it yet. Two copies of that logic
# would drift, and the direction they drift in is "the installed system boots, the updated one does
# not" or the reverse -- discoverable only on hardware, on a device with no serial console. So the
# shared half lives here and post-install.sh sources it.
#
# The functions take explicit arguments and touch nothing implicitly: the OTA path addresses a
# running system's /esp and /efi, the installer addresses mountpoints under /run on a foreign disk,
# and a primitive that reached for a global would be right for exactly one of them.
#
# ONE ACKNOWLEDGED EXCEPTION: $SHA256, read by refresh_if_diff. It is a global because it is the
# seam the offline suite drives to make the comparator ABSENT -- a parameter could not be made to
# vanish from a caller the suite does not control. Named here so the rule above reads as having one
# carve-out rather than as being quietly untrue.

# die() and log() are the caller's if it has them -- post-install.sh's prefix [post-install.sh] and
# its offline suite asserts that shape, so a primitive that printed its own name would make the
# hook's output read as if two programs were talking. Only define fallbacks when sourced by
# something that has not got them.
if ! declare -F die >/dev/null 2>&1; then
  die() { printf '[lib-slotwrite] ERROR: %s\n' "$1" >&2; exit 1; }
fi
if ! declare -F log >/dev/null 2>&1; then
  log() { printf '[lib-slotwrite] %s\n' "$1"; }
fi

# The hasher used by refresh_if_diff below, a seam for the same reason post-install.sh's BC is one:
# an offline suite runs with the HOST's PATH appended and so cannot make a tool absent, which would
# leave the "the comparator is missing" path untestable. post-install.sh defines this before it
# sources us and asserts the tool exists ahead of anything destructive; the default here is for
# callers that do neither.
SHA256=${SHA256:-sha256sum}

# --- addressing a partition by index, without spelling a device name ----------------------------
# THE ONE RULE THE INSTALLER'S EVERY WRITE DEPENDS ON. genpart.sh --append hands back indices, and
# the tempting way to turn an index into something mkfs can open is `${disk}${n}` or `${disk}p${n}`.
# Do not. The `p` infix depends on the disk's KIND -- `mmcblk0p11` against `sda11` -- so a spine
# written against one is broken on the other, and we cannot test the difference: every device in the
# fleet is UFS (five captures plus a Thor Lite, all UFS 3.1; the only mmcblk anywhere is the boot
# SD). A naming bug of this shape would first appear on a customer's eMMC board, mid-install, on a
# disk whose userdata is already gone. Nothing on the device concatenates a disk and an index today
# and nothing new may start.
#
# LOWER-CASED, and that is not cosmetic either: sgdisk prints partition GUIDs upper case, steamcl
# string-compares them against the partsets, and mint_partsets below refuses anything else. One
# lowercasing site, so a uuid used as a device path and the same uuid written into a partset cannot
# disagree.
#
# TWO SEAMS, and they are the same pair every script in this install documents: an unprivileged
# offline suite has no block device to offer and no /dev/disk/by-partuuid to populate, so the
# assertions that matter -- that the answer is lower-cased and that it never contains the disk name
# -- would otherwise be unreachable. Neither has a use on a device. Named here so the rule above
# reads as having declared carve-outs rather than as being quietly untrue.
PARTUUID_DIR=${PARTUUID_DIR:-/dev/disk/by-partuuid}
DISKTEST=${DISKTEST:--b}

part_uuid() {  # <disk> <index> -> lowercase partition GUID
  sgdisk -i "$2" "$1" 2>/dev/null \
    | sed -n 's/^Partition unique GUID: \([0-9A-Fa-f-]*\).*/\1/p' | tr 'A-Z' 'a-z'
}

# Returns NON-ZERO for an image file, which has no partition nodes at all. Callers must treat that
# as "there is nothing to open here" rather than falling back to a name they built themselves --
# guessing a device node to write to is precisely the guess this rule exists to refuse.
part_dev() {  # <disk> <index> -> /dev/disk/by-partuuid/<uuid>
  local uuid
  # shellcheck disable=SC2086  # DISKTEST is a predicate, not a path
  [ $DISKTEST "$1" ] || return 1
  uuid="$(part_uuid "$1" "$2")"
  [ -n "$uuid" ] || return 1
  printf '%s/%s\n' "$PARTUUID_DIR" "$uuid"
}

# --- parts.env (phase 1b) -----------------------------------------------------------------------
# The map stage 2 reads before it can address anything: where our eight partitions ARE on this
# medium. On a card they are 1..8; on an internal install genpart.sh --append discovers them from
# the OEM's GPT and they are neither row order nor contiguous (an ESP at p3 while sitting physically
# last is a real observed case). This is the one file that tells stage 2 which is which.
#
# WRITTEN BY HAND rather than with grub-editenv, and that is deliberate. Unlike every other artifact
# in the install, parts.env's CONTENTS ARE PER-DISK -- they come from what --append just laid down on
# this specific device -- so the trick used for the ESP's grubenv (build a pristine block at image
# build time, have the device cp it) does not transfer. It has to be generated on the device, and
# grub-editenv is not on the shipped image: no grub in customize-base.sh's PKGS, no
# /usr/bin/grub-editenv in the built base (confirmed 2026-08-06). Adding it to the INSTALLER's
# package list would be free, but the format is trivial and fixed, and the installer already has to
# add gptfdisk and dosfstools -- this is one fewer.
#
# The format, verified against grub-editenv's own output rather than from the docs:
#
#   "# GRUB Environment Block\n"   the signature: 24 characters + \n. envblk.c memcmp's it, so it
#                                  is the one load-bearing part and must match byte for byte.
#   "# WARNING: ...\n"             what grub-editenv writes. A comment, so inert to the reader --
#                                  reproduced anyway so a card's parts.env and an install's are the
#                                  same shape, and one file can be diffed against the other.
#   "key=value\n"                  one per line. grub_envblk_iterate starts after the signature and
#                                  skips any line beginning with '#'.
#   "####..."                      '#' padding, no trailing newline, out to EXACTLY 1024 bytes.
GRUB_ENVBLK_SIGNATURE='# GRUB Environment Block'
GRUB_ENVBLK_WARNING='# WARNING: Do not edit this file by tools other than grub-editenv!!!'
GRUB_ENVBLK_SIZE=1024

# Pure: emits the block on stdout, touches nothing. Everything that can be asserted about the
# format is asserted about THIS, which is why it is separate from the function that writes a file.
parts_env_block() {  # <key=value>...
  local body pad
  body="$GRUB_ENVBLK_SIGNATURE"$'\n'"$GRUB_ENVBLK_WARNING"$'\n'
  local kv
  for kv in "$@"; do
    case "$kv" in
      *=*) ;;
      *) die "parts.env entry '$kv' is not key=value" ;;
    esac
    body+="$kv"$'\n'
  done

  # THE ASSERTION THAT MATTERS. grub_envblk_open only requires the SIGNATURE to fit, so a block of
  # the wrong length still reads back correctly with grub-editenv and would differ from what
  # make-sdcard.sh writes on a card. Nothing downstream would complain; the file would simply not be
  # the same object the card carries. Check the length here, where it is cheap.
  pad=$(( GRUB_ENVBLK_SIZE - ${#body} ))
  [ "$pad" -ge 0 ] \
    || die "parts.env content is ${#body} bytes, over the $GRUB_ENVBLK_SIZE-byte block"

  printf '%s' "$body"
  # No trailing newline after the padding -- grub-editenv's block ends on '#'.
  [ "$pad" -gt 0 ] && printf '%*s' "$pad" '' | tr ' ' '#'
  return 0
}

# Writes the block to the slot's efi partition. <mnt> is where that partition is mounted -- /efi on
# a running system, a /run mountpoint on the disk being installed.
write_parts_env() {  # <mnt> <key=value>...
  local mnt="$1"; shift
  [ -d "$mnt" ] || die "no efi mountpoint at $mnt for parts.env"
  mkdir -p "$mnt/EFI/steamos" || die "cannot create $mnt/EFI/steamos"
  parts_env_block "$@" >"$mnt/EFI/steamos/parts.env" \
    || die "cannot write $mnt/EFI/steamos/parts.env"
}

# genpart.sh --append prints `<gpt-name>=<index>`; stage 2 reads `nd_<role>`. This is the only place
# that knows the correspondence, so a rename in partition-table.txt breaks HERE, loudly, rather than
# producing a parts.env that is well-formed and names nothing.
parts_env_from_genpart_map() {  # reads the map on stdin, emits key=value on stdout
  local name idx key
  while IFS='=' read -r name idx; do
    [ -n "$name" ] || continue
    case "$name" in
      NOVADECK-ESP)    key=nd_esp ;;
      novadeck-efi-A)  key=nd_efi_a ;;
      novadeck-efi-B)  key=nd_efi_b ;;
      novadeck-root-A) key=nd_root_a ;;
      novadeck-root-B) key=nd_root_b ;;
      novadeck-var-A)  key=nd_var_a ;;
      novadeck-var-B)  key=nd_var_b ;;
      novadeck-home)   key=nd_home ;;
      *) die "genpart map names '$name', which parts.env has no key for" ;;
    esac
    case "$idx" in
      ''|*[!0-9]*) die "genpart map gives '$name' a non-numeric index '$idx'" ;;
    esac
    printf '%s=%s\n' "$key" "$idx"
  done
}

# --- per-slot /var ------------------------------------------------------------------------------
# Reformat the slot's var partition and populate it, then stamp the two pieces of identity that
# distinguish this slot from the one the content came from.
#
# THE POPULATION IS WHOLESALE, and that shape is load-bearing. It used to be a hand-picked whitelist
# (machine-id, then NetworkManager connections, then SSH host keys...) and that was wrong: every new
# piece of per-device state has to be REMEMBERED, and forgetting one fails SILENTLY -- the update
# succeeds, the slot boots, and something is subtly a different device. On hardware with no serial
# console that is the worst failure shape available. A full copy inverts it: state survives by
# default, and anything we do NOT want has to be excluded on purpose, in writing, below. (SteamOS
# reaches the same conclusion; cf. _reference/steamos-teardown/docs/system-updates.md §4, which
# rsyncs the whole partition after reformatting it.)
#
# The reformat stays: the target's /var is whatever the PREVIOUS install left there, and stale state
# is what makes a slot behave differently from the one that was tested.
#
# <source> IS EITHER A DIRECTORY OR A TARBALL, and which one is what separates the two callers. The
# OTA path passes the RUNNING /var -- there is a live system to copy from and copying it is the
# whole point. The installer passes /usr/lib/novadeck/var-seed.tar.zst out of the root it just
# wrote, because on a disk with no novadeck on it there is nothing to copy: the running system is
# the installer image, whose /var describes the INSTALLER, not the device being built. Everything
# after the population is identical, which is why it is one function and not two.
seed_var() {  # <dev> <slot> <mnt> <source>
  local dev="$1" slot="$2" mnt="$3" src="$4"
  local SLOT="${slot^^}"
  case "$SLOT" in A|B) ;; *) die "seed_var: '$slot' is not an image name (A or B)" ;; esac

  # Resolve WHICH KIND of source this is before the reformat, not at the point of use. Both checks
  # are free, and the reformat is destructive: an installer handed a seed tarball path that does not
  # exist would otherwise discover it with the target's /var already emptied, turning a bad argument
  # into a slot that has to be redone.
  local mode
  if   [ -d "$src" ]; then mode=dir
  elif [ -f "$src" ]; then mode=tar
  else die "no /var source at $src -- neither a directory to copy nor a seed tarball"
  fi

  mkfs.ext4 -q -F -L "novadeck-var-$SLOT" "$dev" || die "cannot reformat $dev"

  mkdir -p "$mnt"
  mount "$dev" "$mnt" || die "cannot mount the target /var ($dev)"
  # OURS IS ADDITIVE, and that matters more than it looks. The caller may already own an EXIT trap:
  # post-install.sh does not at this point, but Phase 4's installer holds mountpoints under /run on
  # a foreign disk and will carry one across its whole run. A bare `trap ... EXIT` here would
  # overwrite it and the success path's `trap - EXIT` would then disarm the caller entirely --
  # silently, with the symptom being leaked mounts on exactly the failure paths where cleanup
  # matters. So: chain the previous handler behind ours, and restore it verbatim on the way out.
  #
  # Expanded at trap-SET time, not at trap-fire time: $mnt is a local, and by the time an EXIT trap
  # runs on the die() path this function has gone.
  local prev_cmd
  prev_cmd="$(trap -p EXIT | sed -n "s/^trap -- '\(.*\)' EXIT\$/\1/p")"
  trap "umount $(printf %q "$mnt") 2>/dev/null || true${prev_cmd:+; $prev_cmd}" EXIT

  if [ "$mode" = dir ]; then
    # rsync, in the image for exactly this (rootfs/customize-base.sh PKGS). -aHAX preserves modes,
    # owners, hard links, ACLs and xattrs. Modes matter more than they look: sshd refuses to start
    # if a private host key is group/world-readable, so a mode-losing copy would take SSH down on
    # the updated slot and nowhere else. --numeric-ids because we are copying between two roots
    # rather than resolving names through THIS one's passwd.
    #
    # --one-file-system is LOAD-BEARING. /var/log, /var/tmp, /var/cache/pacman, /var/lib/flatpak and
    # /var/lib/systemd/coredump are bind mounts from the SHARED /home offload tree, i.e. not in this
    # partition at all. Without it we would copy shared data into a 256M partition -- /var/log alone
    # can exceed it -- and duplicate what both slots already share. The mount points themselves need
    # no special handling: systemd creates a .mount unit's target directory if it is missing.
    #
    # Trailing slash on the source: copy its CONTENTS into $mnt, not a /var/var.
    rsync -aHAX --numeric-ids --one-file-system "${src%/}/" "$mnt/" \
      || die "cannot copy $src to the target slot"
    log "copied $src wholesale ($(du -sh -x "$src" 2>/dev/null | cut -f1), offload bind mounts skipped)"
  else
    # The flags MIRROR the rsync above, and have to: -p --numeric-owner --xattrs --acls is what
    # `rsync -aHAX --numeric-ids` promises, and tar preserves hard links natively. An installed slot
    # and an updated one must reach the same /var, and the modes are the sharp end -- sshd refuses
    # to start if a private host key is group/world-readable, so a mode-losing unpack takes SSH down
    # on installed devices and nowhere else. rootfs/assemble-rootfs.sh packs with the same set.
    #
    # -p IS NOT REDUNDANT, even though this runs as root and tar defaults to it there. Measured:
    # without -p the sticky bit on /var/tmp comes back 0777 instead of 1777 -- the bit IS in the
    # archive, tar simply masks it off when it does not think it is preserving permissions. rsync -a
    # has no such mode, so leaving it implicit would make the two paths agree only by accident of
    # who is running them, which is the exact drift this file exists to prevent.
    tar -p --numeric-owner --xattrs --acls -xf "$src" -C "$mnt" \
      || die "cannot unpack the /var seed $src onto $dev"
    log "seeded /var from $src"
  fi

  # The overlay dirs must exist before the target boots -- the initramfs mounts /etc from them, so a
  # slot missing them does not come up at all. A directory source brings them; this is a guard
  # against the one case that would be unrecoverable, and the seed tarball's own guarantee.
  mkdir -p "$mnt/lib/overlays/etc/upper" "$mnt/lib/overlays/etc/work" "$mnt/lib/novadeck"

  # THE ONE FILE THAT MUST NOT SURVIVE THE POPULATION VERBATIM. Everything else in /var describes
  # the DEVICE and is correct on either slot; this describes WHICH SLOT it is. Written last,
  # deliberately after the copy that would otherwise clobber it.
  printf '%s\n' "$SLOT" >"$mnt/lib/novadeck/slot"

  # THE SECOND THING THE COPY MUST NOT KEEP: /var/lib/novadeck/mac-wifi, the write-once record of
  # this device's derived Wi-Fi MAC. Deleted so the target re-derives it from the machine-id that
  # the copy above just carried over (gen-mac.sh: sha256(machine-id)).
  #
  # On a healthy device this is a no-op in effect -- same machine-id in, same MAC out, so the
  # address is stable across the update, which is the requirement. It matters for the devices where
  # it is NOT a no-op: a unit flashed before the MAC-collision fix has a COLLIDING address persisted
  # here, and because the file is write-once and outranks the derivation, that unit keeps the bad
  # MAC forever.
  rm -f "$mnt/lib/novadeck/mac-wifi"

  # Put the caller's handler back exactly as it was -- `trap - EXIT` only when there was nothing.
  umount "$mnt"
  if [ -n "$prev_cmd" ]; then trap "$prev_cmd" EXIT; else trap - EXIT; fi
}

# --- stage 2 on a slot's efi partition ------------------------------------------------------------
# <bootdir> is /usr/lib/novadeck/boot of the INSTALLED ROOT -- the one whose bytes were just written,
# mounted somewhere readable -- and never this running system's.
#
# WHY THE FILES COME OUT OF THE NEW ROOT AND NOT THE BUNDLE (or, for the installer, not the medium):
# grubaa64.efi and grub-<slot>.cfg are boot software owned by the same build that ships /boot/Image
# and /lib/modules/<ver> inside that rootfs. Taking them from the root makes the pairing true by
# construction -- there is no second layout to keep in sync, and no way to install a root whose
# stage 2 does not boot it.
#
# The efi partition is COPIED ONTO, NEVER WIPED, and that is load-bearing rather than incidental.
# Since the phase-1b work it also carries /EFI/steamos/parts.env -- where our eight partitions
# actually are on THIS medium, written once by whoever created them and read by the stage-2 grub.cfg
# before it can address anything. An update must leave it alone: the running system cannot know the
# layout of the disk it is updating any better than the installer that laid it down did, and a mkfs
# or an rsync --delete here would take an internal install's map away and leave stage 2 falling back
# to the SD card's 1..8. Refresh by name, and add nothing that deletes.
write_efi_partition() {  # <mnt> <slot> <bootdir>
  local mnt="$1" slot="$2" bootdir="$3"
  local lower="${slot,,}"
  case "$lower" in a|b) ;; *) die "write_efi_partition: '$slot' is not an image name (A or B)" ;; esac

  local grub_efi="$bootdir/grubaa64.efi"
  local grub_cfg="$bootdir/grub-$lower.cfg"
  local grub_font="$bootdir/fonts/dejavu-mono.pf2"
  # The paths named in these messages are the ones an operator sees on the device, so they are
  # spelled absolutely rather than as $bootdir, which is a mountpoint under /run.
  [ -f "$grub_efi" ] || die "the installed root carries no stage-2 GRUB at /usr/lib/novadeck/boot/grubaa64.efi"
  [ -f "$grub_cfg" ] || die "the installed root carries no /usr/lib/novadeck/boot/grub-$lower.cfg"
  [ -f "$grub_font" ] || die "the installed root carries no boot font at /usr/lib/novadeck/boot/fonts/dejavu-mono.pf2"

  mkdir -p "$mnt/EFI/steamos/fonts" || die "cannot create $mnt/EFI/steamos/fonts"
  cp "$grub_efi"  "$mnt/EFI/steamos/grubaa64.efi" || die "cannot install grubaa64.efi on the target efi"
  cp "$grub_cfg"  "$mnt/EFI/steamos/grub.cfg"     || die "cannot install grub.cfg on the target efi"
  cp "$grub_font" "$mnt/EFI/steamos/fonts/dejavu-mono.pf2" || die "cannot install the boot font"
}

# --- partsets -------------------------------------------------------------------------------------
# The identity files steamcl matches against: it resolves the efi partition it was loaded from to an
# image name via SteamOS/partsets/self, reads partsets/all for the ESP, and bootconf reads self too.
# all/shared/A/B are disk-derived and identical on both efi partitions; only self/other name THIS
# partition and the other one.
#
# The OTA path does NOT use this -- it copies the partsets off the running /efi, because they
# describe the disk it is already running from and cannot be rebuilt from nothing there. The
# installer must MINT them: it is writing a disk that has no novadeck on it, so the uuids come from
# the GPT it just laid down. Same file format, and this is where it is written down once.
mint_partsets() {  # <mnt> <self-image> <esp-uuid> <efi-a-uuid> <efi-b-uuid>
  local mnt="$1" self="$2" esp_uuid="$3" efia="$4" efib="$5"
  local self_uuid other_uuid u

  case "${self^^}" in
    A) self_uuid="$efia"; other_uuid="$efib" ;;
    B) self_uuid="$efib"; other_uuid="$efia" ;;
    *) die "mint_partsets: '$self' is not an image name (A or B)" ;;
  esac

  # LOWERCASE, and asserted. sgdisk prints partition GUIDs in upper case and steamcl compares these
  # strings against the uuid of the partition it booted from; a set minted from raw sgdisk output
  # would be well-formed, would match nothing, and the symptom is a disk that does not boot -- found
  # only on hardware. image/make-sdcard.sh lowercases at the same seam for the same reason.
  for u in "$esp_uuid" "$efia" "$efib"; do
    [[ "$u" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
      || die "mint_partsets: '$u' is not a lowercase partition uuid"
  done

  mkdir -p "$mnt/SteamOS/partsets" || die "cannot create $mnt/SteamOS/partsets"
  printf 'efi %s\n' "$efia"       >"$mnt/SteamOS/partsets/A"      || die "cannot write partsets/A"
  printf 'efi %s\n' "$efib"       >"$mnt/SteamOS/partsets/B"      || die "cannot write partsets/B"
  printf 'esp %s\n' "$esp_uuid"   >"$mnt/SteamOS/partsets/all"    || die "cannot write partsets/all"
  printf 'esp %s\n' "$esp_uuid"   >"$mnt/SteamOS/partsets/shared" || die "cannot write partsets/shared"
  printf 'efi %s\n' "$self_uuid"  >"$mnt/SteamOS/partsets/self"   || die "cannot write partsets/self"
  printf 'efi %s\n' "$other_uuid" >"$mnt/SteamOS/partsets/other"  || die "cannot write partsets/other"
}

# --- the shared ESP ---------------------------------------------------------------------------
# Stage 1. ABL chainloads /EFI/BOOT/bootaa64.efi, so that is the copy that matters; the companions
# in /EFI/BOOT/ are resolved by steamcl's resolve_path() relative to the chainloader location.
#
# WHY sha256sum AND NOT cmp: cmp(1) is diffutils, which this image does not carry and never has. The
# skip below is not an optimisation -- the shared ESP is the only write in an update with no A/B
# copy behind it, so `cp -f` over the file ABL chainloads is the one step a power cut can leave
# unbootable with nothing to roll back to. Comparing first is what keeps that window closed on the
# updates where these files did not change, which is most of them. Read from stdin so the output is
# the digest alone. A comparator that is merely ABSENT does not announce itself -- `cmp -s` was used
# until 2026-08-05 and "command not found" reads exactly like "the files differ", so the ESP refresh
# degraded to unconditional copy for three releases -- which is why callers assert $SHA256 exists
# before they touch anything, rather than discovering it here.
refresh_if_diff() {  # <src> <dst>
  if [ ! -e "$2" ] || [ "$("$SHA256" <"$1")" != "$("$SHA256" <"$2")" ]; then
    cp -f "$1" "$2" || die "cannot refresh $2"
    sync
    log "refreshed $2"
  fi
}

refresh_esp_stage1() {  # <esp> <bootdir>
  local esp="$1" bootdir="$2"
  local steamcl="$bootdir/steamcl.efi"
  local steamcl_ver="$bootdir/steamcl-version"
  local stage_font="$bootdir/fonts/default.pf2"
  [ -f "$steamcl" ] || die "the installed root carries no /usr/lib/novadeck/boot/steamcl.efi"

  mkdir -p "$esp/EFI/BOOT" "$esp/EFI/BOOT/fonts" || die "cannot create $esp/EFI/BOOT"
  refresh_if_diff "$steamcl_ver" "$esp/EFI/BOOT/steamcl-version"
  refresh_if_diff "$stage_font" "$esp/EFI/BOOT/fonts/default.pf2"
  # An empty flag file; steamcl reads its existence, not its contents. It restricts chainloading to
  # the same physical device, which is what stops an installer medium from being used to boot
  # something off another disk.
  : >"$esp/EFI/BOOT/steamcl-restricted" || die "cannot write $esp/EFI/BOOT/steamcl-restricted"
  sync
  # bootaa64.efi LAST, and the order is the whole point rather than tidiness. ABL's test is
  # CONTENT-based -- it chainloads /EFI/BOOT/bootaa64.efi if that file is there -- so on an internal
  # install this one copy is what flips the device from booting the installer medium to booting the
  # disk being built (measured 2026-08-21: an empty internal ESP does not divert ABL at all). Write
  # it first and an install interrupted a second later leaves a device that boots internal steamcl
  # with no steamcl-version, no font and no restricted flag beside it; write it last and every
  # earlier interruption still boots the medium and a re-run is free. The companions are resolved by
  # steamcl's resolve_path() relative to the chainloader, so they must already be there when it runs.
  #
  # The OTA path gets the same property for the same reason: the shared ESP is the one write in an
  # update with no A/B copy behind it, so the file with nothing to roll back to goes last.
  refresh_if_diff "$steamcl" "$esp/EFI/BOOT/bootaa64.efi"
  sync
}

# NOTHING RESOLVES THE ESP BY THIS LABEL: ABL finds it by type GUID (ef00), the OS mounts it by
# PARTLABEL from /etc/fstab, and the stage-2 grub.cfg addresses it by partition index. It is a human
# convenience on a mounted disk, and it is deliberately NOT the GPT name -- a FAT label caps at 11
# characters and NOVADECK-ESP is twelve. Kept identical to image/make-sdcard.sh's so a card and an
# internal install present the same object.
ESP_FAT_LABEL=NOVADECK

# THE FAT WIDTH IS CHOSEN FROM THE DISK, NEVER FORCED. A FAT32 must have at least 65525 data
# clusters to be one, and cluster count scales with SECTORS -- so a partition sized in bytes is a
# different filesystem on 512-byte and 4096-byte media. Every SD card is 512e and every internal UFS
# here is 4Kn, which is why a hardcoded `-F 32` was valid on every card ever flashed and invalid on
# every internal install.
#
# MEASURED on an AYANEO Pocket ACE, 2026-08-21. It surfaces twice, and the two look unrelated:
# the ESP fails inside ABL (its FatPkg returns EFI_VOLUME_CORRUPTED, never publishes a
# SimpleFileSystem handle, and LoadEFI reports "Failed to load EFI: Not Found"), and efi-A/B fail
# one layer later inside steamcl, which mounts them through the SAME EFI FAT driver and so finds no
# boot candidate at all. See the block above the rows in image/partition-table.txt.
#
# The rule is deliberately OURS rather than mkfs.fat's. Dropping the flag entirely also produces a
# valid filesystem, but the width would then be picked by a size-threshold table inside the tool,
# which can move on a version bump and would silently reformat a card's ESP from FAT32 to FAT16.
#
# FAT_SECTOR_SIZE is a TEST SEAM and nothing else. blockdev answers only for a block device, and the
# 4Kn path exists on no card and in no image file -- so without it the one geometry that breaks is
# the one no suite can reach. tests/test-partition-table.sh sets it to drive the rule at 4096
# against the real table; the installer never sets it, and on a device blockdev is authoritative.
fat_type_for() {  # <dev> -> 32 or 16
  local dev="$1" ss bytes sectors
  ss="${FAT_SECTOR_SIZE:-$(blockdev --getss "$dev" 2>/dev/null || true)}"
  bytes="$(blockdev --getsize64 "$dev" 2>/dev/null || stat -c %s "$dev" 2>/dev/null || true)"
  # Unknown geometry keeps the historical answer rather than inventing one: on a card this is right,
  # and on a device that cannot answer blockdev the mkfs below fails loudly either way.
  { [ -n "$ss" ] && [ -n "$bytes" ]; } || { printf 32; return 0; }
  sectors=$(( bytes / ss ))
  # 65525 clusters at one sector per cluster, plus reserved sectors and two FATs. Below this a
  # FAT32 cannot exist here whatever mkfs is asked for.
  if [ "$sectors" -ge 66000 ]; then printf 32; else printf 16; fi
}

# Read the width back off the superblock and refuse a filesystem outside its own valid range. This
# is what turns the failure above from "the device does not boot, with no clue why" into a message
# at the point of creation -- neither the offline suites nor a card build can reach the 4Kn path.
#
# FAT_ASSERT=0 is the sandbox seam, and it is the same trade DEVTEST makes. tests/test-install.sh
# stubs mkfs.vfat to a recorder, so there is no superblock to read back and this could only ever
# fail there. The assertion IS exercised against real filesystems, at both sector sizes, by
# tests/test-partition-table.sh -- which is also the suite that would have caught the defect it
# exists for. Nothing on a device sets it.
assert_fat_valid() {  # <dev> <label-for-messages>
  local dev="$1" what="$2" bps spc rsv nf t16 t32 re fsz tot rootsec cl lo hi
  [ "${FAT_ASSERT:-1}" = 1 ] || return 0
  g() { dd if="$dev" bs=1 skip="$1" count="$2" 2>/dev/null | od -An -tu"$2" | tr -d ' '; }
  bps=$(g 11 2); spc=$(g 13 1); rsv=$(g 14 2); nf=$(g 16 1)
  t16=$(g 19 2); t32=$(g 32 4); re=$(g 17 2); fsz=$(g 22 2)
  [ "${fsz:-0}" != 0 ] || fsz=$(g 36 4)
  tot=$t16; [ "${tot:-0}" != 0 ] || tot=$t32
  { [ -n "$bps" ] && [ "${spc:-0}" -gt 0 ] && [ "${tot:-0}" -gt 0 ]; } \
    || die "$what on $dev: unreadable FAT superblock after mkfs"
  rootsec=$(( (re * 32 + bps - 1) / bps ))
  cl=$(( (tot - (rsv + nf * fsz + rootsec)) / spc ))
  if [ "$re" = 0 ]; then lo=65525; hi=268435445; else lo=4085; hi=65524; fi
  { [ "$cl" -ge "$lo" ] && [ "$cl" -le "$hi" ]; } \
    || die "$what on $dev has $cl clusters, outside ${lo}..${hi} -- the firmware will refuse to mount it"
}

# Installer-only: an update never creates a filesystem on the shared ESP, it refreshes files on the
# one that is already there.
mkfs_esp() {  # <dev>
  local dev="$1"
  mkfs.vfat -F "$(fat_type_for "$dev")" -n "$ESP_FAT_LABEL" "$dev" >/dev/null \
    || die "cannot create the ESP filesystem on $dev"
  assert_fat_valid "$dev" "the ESP"
}

# The remaining two filesystems the installer creates and an update never does. They live here, next
# to mkfs_esp and to the writers that fill them, so that a card and an internal install produce the
# same objects: image/make-sdcard.sh is the other writer, and its labels are what these repeat.
#
# NOTHING RESOLVES AN efi PARTITION BY THIS LABEL either -- steamcl matches the partition uuid it
# booted from against SteamOS/partsets/self, and the stage-2 grub.cfg addresses partitions by the
# index parts.env gives it. `GRUB-A`/`GRUB-B` is a human convenience on a mounted disk, and it is
# again not the GPT name: a FAT label caps at 11 characters.
mkfs_efi() {  # <dev> <slot>
  local dev="$1" slot="${2^^}"
  case "$slot" in A|B) ;; *) die "mkfs_efi: '$2' is not an image name (A or B)" ;; esac
  mkfs.vfat -F "$(fat_type_for "$dev")" -n "GRUB-$slot" "$dev" >/dev/null \
    || die "cannot create the efi-${slot,,} filesystem on $dev"
  assert_fat_valid "$dev" "efi-${slot,,}"
}

# -m0: no reserved-for-root blocks. /home is user data on a device with no admin, so the 5% default
# is 5% of the disk nobody can ever use. make-sdcard.sh passes the same.
mkfs_home() {  # <dev>
  local dev="$1"
  mkfs.ext4 -q -F -L novadeck-home -m0 "$dev" \
    || die "cannot create the /home filesystem on $dev"
}
