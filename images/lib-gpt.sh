#!/usr/bin/env bash
# Reading a GPT that still lists partitions it no longer has — issue #56.
#
# SOURCED, never executed (hence mode 0444, like lib-slotwrite.sh). SHIPPED verbatim into
# /usr/lib/novadeck/install/ beside genpart.sh and partition-table.txt, because genpart.sh is
# shipped and sources it; images/guard-rootfs.sh diffs the two copies at build time.
#
# WHY THIS FILE EXISTS. A GPT entry whose type GUID is all zeroes is UNUSED by the spec (UEFI
# 5.3.3). The kernel does not enumerate it, `sgdisk -i N` answers "Partition #N does not exist",
# and sgdisk will happily allocate over it -- but `sgdisk -p` still RENDERS A ROW for it, carrying
# whatever start/end LBAs the slot was left with. Three of our scans read that listing and all
# three believed the row:
#
#   images/genpart.sh        the --append containment check   -> "something is in the way", refuse
#   install/select-target.sh gpt_rows(), CEIL, the ESP scan   -> a ceiling below the real one
#   install/carve.sh         gpt_rows(), effective_ceiling    -> the same, on the destructive side
#
# MEASURED on an AYANEO Pocket ACE, 2026-08-22, after an uninstall from ROCKNIX's LinuxLoader
# (QcomModulePkg/Library/BootLib/UninstallCfwMenu.c, PerformUninstallCfw): it zeroes the type GUID,
# the unique GUID and the name of every entry after userdata while KEEPING THE LBAs, then grows
# userdata back over the space. Our eight came back as:
#
#   /dev/sda11 : start=4794920, size=25355734, type=0FC63DAF-…, name="userdata"
#   /dev/sda12 : start=6892072, size=131072,   type=00000000-0000-0000-0000-000000000000
#   … through sda19, all eight, LBAs intact
#
# so the residue OVERLAPS the regrown userdata: p12 starts at 6892072 and userdata now runs to
# 30150653. There is no geometric test that separates residue from a real neighbour, and the type
# CODE cannot do it either -- real Android partitions (`super`, `vbmeta_*`) print as FFFF in
# `sgdisk -p` too, because sgdisk has no name for their GUIDs. The discriminator is the type GUID
# itself, and only `sfdisk --dump` shows it for every entry in ONE call.
#
# "Try one distro, then try another" is an ordinary thing for a user to do, so this is an ordinary
# user path: without this filter such a disk is permanently uninstallable by us, and the refusal
# lands AFTER carve.sh has already shrunk userdata.
#
# WHY NOT `sgdisk -i` PER ROW. That was the first attempt and it was reverted. It spawns a process
# per partition per call and gpt_rows() is called repeatedly -- it quadrupled the offline suites
# (~25s -> 1m44 for test-select-target.sh alone) -- and the obvious way to read its answer,
# `grep -q 'does not exist'`, ALSO matches sgdisk's "The specified file does not exist!" when it
# cannot open the disk at all, which turns an unreadable device into an apparently empty one. One
# `sfdisk --dump` per call has neither problem.

NOVADECK_DEAD_TYPE_GUID="00000000-0000-0000-0000-000000000000"

# The vendor type stock Android userdata carries. Four of the five Phase 0 boards show it (Pocket
# S2, Pocket ACE, Odin 2, Pocket Max); the fifth, the Pocket FIT, shows 0FC63DAF -- Linux
# filesystem data -- because it had already been carved by somebody else when we captured it.
NOVADECK_ANDROID_USERDATA_GUID="1B81E7E6-F50D-419B-A739-2AEEF8DA3335"

# die() is the caller's if it has one, so a refusal keeps the prefix that script's suite asserts
# (`carve: `, `select-target: `, `genpart: `). Same rule, and same reason, as lib-slotwrite.sh.
if ! declare -F die >/dev/null 2>&1; then
  die() { printf '[lib-gpt] ERROR: %s\n' "$1" >&2; exit 1; }
fi

# --- which entries does the GPT actually use? ---------------------------------------------------
# One `sfdisk --dump`, indices on stdout, one per line, ascending.
#
# IT DIES RATHER THAN RETURNING AN EMPTY SET when the dump cannot be read. That is the whole safety
# property: "no live partitions" is what every caller here reads as "nothing is in the way", so an
# unreadable disk answering the same way as a blank one would turn a read failure into permission
# to write over a full disk. A disk with a readable label and no rows IS blank and legitimately
# prints nothing -- the distinction is the header, not the row count.
gpt_live_indices() {  # <disk> -> live partition indices, one per line
  local disk="$1" dump
  dump="$(sfdisk --dump "$disk" 2>/dev/null)" \
    || die "cannot read the partition table of $disk (sfdisk --dump failed) -- refusing to treat an unreadable disk as an empty one"
  printf '%s\n' "$dump" | grep -q '^label:' \
    || die "$disk has no readable partition-table label -- refusing to treat an unreadable disk as an empty one"

  # sfdisk prints `device: <path>` and then rows named `<path><N>` (`/dev/sda11`) or `<path>p<N>`
  # (`/dev/mmcblk0p11`, `/dev/nvme0n1p11`, `/dev/loop0p11`). Taking the index off the END of the
  # device path -- rather than trusting row order -- is what makes this correct on a table with
  # gaps, which is exactly the table this function exists for.
  printf '%s\n' "$dump" | awk -v dead="$NOVADECK_DEAD_TYPE_GUID" '
    /^device:/ { dev = $2; next }
    dev == "" || index($0, dev) != 1 { next }
    $0 !~ /: *start=/ { next }
    {
      n = substr($1, length(dev) + 1); sub(/^p/, "", n)
      if (n !~ /^[0-9]+$/) next
      if (toupper($0) ~ ("TYPE=" toupper(dead))) next
      print n + 0
    }' | sort -n
}

# --- the table, as the three scans want it ------------------------------------------------------
# "index start end code name" per LIVE partition. `sgdisk -p` is still the source for the geometry
# (it is the one that reports last-usable and the sector size the same way everywhere); this only
# drops the rows the GPT does not use.
#
# Names in every Phase 0 capture are single words, so the last field is the name -- a name with
# spaces would need -i per partition and none exists. The residue rows have no name at all, which
# would break that positional read; they are exactly what is filtered out here.
gpt_rows() {  # <disk> -> "index start end code name" for entries the GPT actually uses
  local disk="$1" live
  live="$(gpt_live_indices "$disk")"
  [ -n "$live" ] || return 0
  sgdisk -p "$disk" 2>/dev/null | awk -v live="$live" '
    BEGIN { n = split(live, a, "\n"); for (i = 1; i <= n; i++) if (a[i] != "") keep[a[i] + 0] = 1 }
    /^[[:space:]]*[0-9]+[[:space:]]+[0-9]+/ { if (($1 + 0) in keep) print $1, $2, $3, $(NF-1), $NF }'
}

# --- removing the residue -----------------------------------------------------------------------
# READING PAST THE DEAD ROWS IS NOT ENOUGH, and this is the half issue #56 got wrong. The issue
# says sgdisk "will happily allocate over" an entry whose type GUID is zeroed. IT DOES NOT.
# MEASURED, gdisk 1.0.10, against a fixture rebuilt from the ACE's own post-uninstall capture:
#
#   sgdisk -i 12 <disk>                    -> "Partition #12 does not exist."
#   sgdisk -p <disk>                       -> still renders row 12, code FFFF, no name
#   sgdisk -n 12:55136576:+1048576 <disk>  -> "Could not create partition 12 from 55136576 to …"
#
# So sgdisk disowns the entry when asked about it and still treats its LBAs as occupied when asked
# to allocate them. A fix that only taught our three scans to ignore the rows would have gone green
# offline and failed on the ACE at the first `sgdisk -n` of the append -- one step later than
# before, with userdata already shrunk.
#
# NEITHER TOOL WILL DELETE THE ROW EITHER: `sgdisk -d 12` answers "Partition number 12 out of
# range!" and `sfdisk --delete 12` answers "failed to delete", both because they agree the slot is
# already empty. What works -- and what recovered the ACE by hand on 2026-08-21, with partitions
# 1..11 coming back md5-identical -- is rebuilding the table from its own `sfdisk --dump` with
# those rows left out.
#
# THIS IS THE ONE WRITE IN THIS FILE. It is safe in the specific sense that matters: it removes
# only entries the GPT itself calls unused, it takes its input from the disk it is about to write,
# and it verifies afterwards that the set of LIVE partitions is unchanged -- so a run that lost a
# real partition refuses instead of continuing. Callers run it BEFORE anything else is written, so
# a failure leaves the disk exactly as it was found.
gpt_drop_dead_entries() {  # <disk> -> rewrites the table without its unused entries
  local disk="$1" before after dropped
  before="$(gpt_live_indices "$disk")"
  dropped="$(sfdisk --dump "$disk" 2>/dev/null | grep -ci ": *start=.*type=$NOVADECK_DEAD_TYPE_GUID")" || true
  [ "${dropped:-0}" -gt 0 ] || return 0

  sfdisk --dump "$disk" 2>/dev/null \
    | awk -v dead="$NOVADECK_DEAD_TYPE_GUID" '
        $0 ~ ": *start=" && index($0, "type=" dead) > 0 { next }
        { print }' \
    | sfdisk --force "$disk" >/dev/null 2>&1 \
    || die "could not rewrite the partition table of $disk without its $dropped unused entries"

  after="$(gpt_live_indices "$disk")"
  [ "$before" = "$after" ] \
    || die "rewriting $disk to drop $dropped unused entries changed the live partitions ($before -> $after) -- STOPPING"
  printf '%s\n' "$dropped"
}

# --- does this disk carry a third-party uninstaller's residue? ----------------------------------
# Positive evidence that something rewrote this table and left the entries behind: at least one
# entry with an all-zero type GUID and a real extent. select-target.sh uses it to decide whether
# userdata's type GUID is trustworthy -- see the comment there.
gpt_has_dead_entries() {  # <disk> -> 0 if any unused entry still carries LBAs
  local disk="$1" dump
  dump="$(sfdisk --dump "$disk" 2>/dev/null)" || return 1
  printf '%s\n' "$dump" \
    | grep -qi ": *start=.*type=$NOVADECK_DEAD_TYPE_GUID"
}
