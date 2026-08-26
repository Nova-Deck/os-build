#!/usr/bin/env bash
# Shared GPT-fixture builder for the installer suites — Phase 3 of
# .claude/plans/internal-install.plan.md.
#
# Sourced by tests/test-select-target.sh and tests/test-carve.sh. It exists because both suites
# need the same thing: the boards in docs/internal-storage.md rebuilt as REAL GPTs, with real
# names, real sizes, real order and real type GUIDs. A rule tightened for one board and silently
# broken for another is the failure these suites exist to catch, so they run against every captured
# disk rather than a representative one -- and a second copy of this awk would be the obvious place
# for the two suites to drift apart.
#
# Callers must set CAPTURES to docs/internal-storage.md before sourcing.
#
# The images are sparse: a 479 GiB fixture costs a GPT's worth of bytes, and sgdisk writes nothing
# else. Nothing here needs root and nothing is mounted.

# Rows come out of the verbatim `sfdisk --dump` block under each disk -- NOT out of the markdown
# table above it, which is the readable half and not the complete one. That table is rendered from
# lsblk, and the kernel does not enumerate a GPT entry whose type GUID is all zeroes, so every
# residue row a foreign uninstaller leaves behind is missing from it. Reading the table meant the
# five captured boards silently dropped their `last_parti` rows -- and that no fixture could
# express the state issue #56 is about at all. The dump carries index, start, size, type and name
# for every entry, live or not, and is the restorable format besides.
#
# Sizes come from the dump as sectors x the block's own `sector-size:`, because a UFS LUN reports
# 4096 where an image file reports 512 and bytes is the only unit that means the same in both.
#
# Partitions are laid in capture order at their captured sizes, so indices and neighbours match the
# hardware -- which matters because the ceiling is "the sector before whatever follows userdata"
# and the Odin 2 puts userdata at 17.
#
# The type GUIDs are what let the suites assert the carve's most easily-missed obligation: stock
# userdata is the vendor type `1B81E7E6-…` and the Pocket FIT shows what it looks like when a carve
# hands it back as `0FC63DAF-…`. Without the real types that assertion would be vacuous.
rows_for() {  # <board> <disk> -> "index name bytes type start-bytes" lines
  awk -v want_b="$1" -v want_d="$2" '
    /^# Internal storage capture/ { b=$0; sub(/^# Internal storage capture — /,"",b) }
    /^## `\/dev\// { d=$0; gsub(/[#` ]/,"",d); ss=0 }
    /^sector-size:/ { if (b == want_b && d == want_d) ss = $2 + 0 }
    /: *start=/ {
      if (b != want_b || d != want_d) next
      # The row is `<device><N> : start=…`, and <device> is the disk this section is about, so the
      # index is whatever follows it -- with the `p` of mmcblk0p11 or nvme0n1p11 dropped.
      dev=$1; sub("^" d, "", dev); sub(/^p/, "", dev)
      if (dev !~ /^[0-9]+$/) next
      i = dev + 0
      s = 0; z = 0
      if (match($0, /start=[ ]*[0-9]+/)) s = substr($0, RSTART+6, RLENGTH-6) + 0
      if (match($0, /size=[ ]*[0-9]+/))  z = substr($0, RSTART+5, RLENGTH-5) + 0
      tp[i] = (match($0, /type=[0-9A-Fa-f-]+/) ? substr($0, RSTART+5, RLENGTH-5) : "-")
      nm[i] = (match($0, /name="[^"]*"/)      ? substr($0, RSTART+6, RLENGTH-7) : "-")
      if (nm[i] == "") nm[i] = "-"
      by[i] = z * (ss ? ss : 512); st[i] = s * (ss ? ss : 512)
      if (i > max) max = i
    }
    END { for (i=1; i<=max; i++) if (i in nm) print i, nm[i], by[i], tp[i], st[i] }
  ' "$CAPTURES"
}

# The disks a board captured, minus sda (the data LUN) and zram. Read from the document rather than
# hardcoded because the boards do not agree: the S2 and the Odin 2 expose sdb..sdh, the ACE sdb..sdf.
luns_for() {  # <board> -> /dev/sdX lines
  awk -v want_b="$1" '
    /^# Internal storage capture/ { b=$0; sub(/^# Internal storage capture — /,"",b) }
    /^## `\/dev\// {
      if (b != want_b) next
      d=$0; gsub(/[#` ]/,"",d)
      if (d != "/dev/sda" && d !~ /zram/) print d
    }' "$CAPTURES"
}

DEAD_TYPE="00000000-0000-0000-0000-000000000000"

# FIXTURE_LAYOUT=packed (the default) lays the rows end to end from sector 2048, at their captured
# SIZES; indices, order and neighbours match the hardware while the disk stays small. That is what
# every board captured in a stock state wants.
#
# FIXTURE_LAYOUT=captured places each row at its captured BYTE OFFSET instead. It exists for the
# one board where the offsets are the finding: after a ROCKNIX uninstall the residue rows sit
# INSIDE the regrown userdata, and a packed layout cannot express an overlap at all. Byte offsets
# are reproduced exactly -- the image is addressed in 512-byte sectors where the LUN is 4Kn, so
# every sector number is eight times the hardware one and every byte offset is identical.
FIXTURE_LAYOUT="${FIXTURE_LAYOUT:-packed}"

build() {  # <img> ; rows "index name bytes type start-bytes" on stdin
  # ONE sgdisk invocation per disk, not one per partition. An sde LUN carries 78 rows and there are
  # eight LUNs in play, so the naive loop spawned ~600 processes and each one re-read and rewrote
  # the whole GPT -- minutes of wall clock for a suite that does no real work. sgdisk takes as many
  # -n/-c pairs as you give it (create mode in genpart.sh depends on the same thing), and every
  # start sector here is explicit, so batching changes nothing about the tables produced.
  local img="$1" idx name bytes type startb sectors first cursor=2048 end=0 a overlaps
  local -a order=() dead=() late=() now=() args=()
  local -A st=() sz=() nm=() ty=()

  while read -r idx name bytes type startb; do
    [ -n "$idx" ] || continue
    sectors=$(( bytes / 512 )); [ "$sectors" -gt 0 ] || sectors=1
    if [ "$FIXTURE_LAYOUT" = captured ]; then
      # 48, not 34: sgdisk's default 128-entry array ends at sector 33, and every captured board
      # starts its first partition well past that once the 4Kn offsets are read as 512-byte ones.
      first=$(( ${startb:-0} / 512 )); [ "$first" -ge 48 ] || first=48
    else
      first="$cursor"
      cursor=$(( cursor + sectors ))
      cursor=$(( (cursor + 2047) / 2048 * 2048 ))   # 1 MiB alignment, as on the captures
    fi
    order+=("$idx"); st["$idx"]="$first"; sz["$idx"]="$sectors"; nm["$idx"]="$name"; ty["$idx"]="$type"
    [ $(( first + sectors )) -gt "$end" ] && end=$(( first + sectors ))
    [ "$type" = "$DEAD_TYPE" ] && dead+=("$idx")
  done

  [ "${#order[@]}" -gt 0 ] || return 1
  truncate -s $(( (end + 65536) * 512 )) "$img" || return 1
  sgdisk -Z "$img" >/dev/null 2>&1

  # Rows are created in two passes, and only a board carrying residue has anything in the second.
  # A row overlapping a dead row cannot be created while that dead row is still typed, so it waits
  # until the zeroing below has made the dead rows unused -- and even then it is written by SFDISK,
  # not sgdisk. MEASURED, gdisk 1.0.10: sgdisk refuses ("Could not create partition 11 from …")
  # while libfdisk does not count a zero-type entry as occupying its sectors and writes the row.
  # That difference is not a fixture detail -- it is why install/carve.sh has to drop the residue
  # outright instead of appending past it, and lib-gpt.sh records the same measurement.
  for idx in "${order[@]}"; do
    overlaps=0
    for a in "${dead[@]}"; do
      [ "$a" = "$idx" ] && continue
      if [ "${st[$idx]}" -lt $(( ${st[$a]} + ${sz[$a]} )) ] \
         && [ $(( ${st[$idx]} + ${sz[$idx]} )) -gt "${st[$a]}" ]; then overlaps=1; fi
    done
    if [ "$overlaps" = 1 ]; then late+=("$idx"); else now+=("$idx"); fi
  done

  args=()
  for idx in "${now[@]}"; do
    args+=(-n "$idx:${st[$idx]}:+${sz[$idx]}")
    [ "${nm[$idx]}" = "-" ] || args+=(-c "$idx:${nm[$idx]}")
    # An all-zero type is "unused" to sgdisk, so a dead row is created with the default type and
    # zeroed afterwards -- asking sgdisk for it here would delete the entry it was just given.
    case "${ty[$idx]}" in -|"$DEAD_TYPE") ;; *) args+=(-t "$idx:${ty[$idx]}") ;; esac
  done
  # -a 1: sgdisk silently ROUNDS an explicit start to a 2048-sector boundary otherwise, which the
  # packed layout never noticed because it only ever asks for multiples of 2048. A captured layout
  # asks for the hardware's offsets, and a fixture whose partitions are a few hundred sectors off
  # the capture is not the disk it claims to be.
  sgdisk -a 1 "${args[@]}" "$img" >/dev/null 2>&1 || return 1

  if [ "${#dead[@]}" -gt 0 ]; then
    zero_types "$img" "${dead[@]}" || return 1
  fi

  local d
  for idx in "${late[@]}"; do
    d="$(sfdisk --dump "$img" 2>/dev/null)" || return 1
    { printf '%s\n' "$d"
      printf '%s%s : start=%s, size=%s' "$img" "$idx" "${st[$idx]}" "${sz[$idx]}"
      case "${ty[$idx]}" in -|"$DEAD_TYPE") ;; *) printf ', type=%s' "${ty[$idx]}" ;; esac
      [ "${nm[$idx]}" = "-" ] || printf ', name="%s"' "${nm[$idx]}"
      printf '\n'
    } | sfdisk --force "$img" >/dev/null 2>&1 || return 1
  done
}

# Zero the type GUID of entries that already exist, leaving their start, size, name and uuid alone.
# sgdisk cannot do this -- `-t N:0000…` is how you tell it the entry is unused, and it deletes it --
# so the table is rewritten from its own `sfdisk --dump`, which is also how the state was recovered
# from the ACE by hand on 2026-08-21 (partitions 1..11 came back md5-identical).
zero_types() {  # <img> <index...>
  local img="$1"; shift
  local list=" $* "
  sfdisk --dump "$img" 2>/dev/null | awk -v img="$img" -v list="$list" -v dead="$DEAD_TYPE" '
    /: *start=/ {
      n = substr($1, length(img) + 1); sub(/^p/, "", n)
      if (index(list, " " n " ") > 0) sub(/type=[0-9A-Fa-f-]+/, "type=" dead)
    }
    { print }' | sfdisk --force "$img" >/dev/null 2>&1
}
