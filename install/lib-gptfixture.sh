#!/usr/bin/env bash
# Shared GPT-fixture builder for the installer suites — Phase 3 of
# .claude/plans/internal-install.plan.md.
#
# Sourced by install/test-select-target.sh and install/test-carve.sh. It exists because both suites
# need the same thing: the four boards in docs/internal-storage.md rebuilt as REAL GPTs, with real
# names, real sizes, real order and real type GUIDs. A rule tightened for one board and silently
# broken for another is the failure these suites exist to catch, so they run against every captured
# disk rather than a representative one -- and a second copy of this awk would be the obvious place
# for the two suites to drift apart.
#
# Callers must set CAPTURES to docs/internal-storage.md before sourcing.
#
# The images are sparse: a 479 GiB fixture costs a GPT's worth of bytes, and sgdisk writes nothing
# else. Nothing here needs root and nothing is mounted.

# Rows come out of the markdown as board|disk|index|name|bytes, and the TYPE GUID out of the verbatim
# `sfdisk --dump` block below the table on the same disk. Partitions are laid in capture order at
# their captured sizes, so indices and neighbours match the hardware -- which matters because the
# ceiling is "the sector before whatever follows userdata" and the Odin 2 puts userdata at 17.
#
# The type GUIDs are what let the suites assert the carve's most easily-missed obligation: stock
# userdata is the vendor type `1B81E7E6-…` and the Pocket FIT shows what it looks like when a carve
# hands it back as `0FC63DAF-…`. Without the real types that assertion would be vacuous.
rows_for() {  # <board> <disk> -> "index name bytes type" lines
  awk -v want_b="$1" -v want_d="$2" '
    /^# Internal storage capture/ { b=$0; sub(/^# Internal storage capture — /,"",b) }
    /^## `\/dev\// { d=$0; gsub(/[#` ]/,"",d) }
    /^\| *[0-9]+ \| `/ {
      if (b != want_b || d != want_d) next
      gsub(/`/,""); split($0,f,"|")
      gsub(/ /,"",f[2]); gsub(/ /,"",f[3]); gsub(/ /,"",f[5])
      if (f[5] ~ /^[0-9]+$/) { i=f[2]+0; nm[i]=f[3]; by[i]=f[5]; if (i>max) max=i }
    }
    /^\/dev\/[a-z]+[0-9]+ : start=/ {
      if (b != want_b || d != want_d) next
      dev=$1; sub(/^\/dev\/[a-z]+/,"",dev)
      if (match($0, /type=[0-9A-Fa-f-]+/)) tp[dev+0] = substr($0, RSTART+5, RLENGTH-5)
    }
    END { for (i=1; i<=max; i++) if (i in nm) print i, nm[i], by[i], (i in tp ? tp[i] : "-") }
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

build() {  # <img> ; rows "index name bytes type" on stdin
  # ONE sgdisk invocation per disk, not one per partition. An sde LUN carries 78 rows and there are
  # eight LUNs in play, so the naive loop spawned ~600 processes and each one re-read and rewrote
  # the whole GPT -- minutes of wall clock for a suite that does no real work. sgdisk takes as many
  # -n/-c pairs as you give it (create mode in genpart.sh depends on the same thing), and every
  # start sector here is explicit, so batching changes nothing about the tables produced.
  local img="$1" idx name bytes type sectors start=2048 total=0
  local -a args=()
  while read -r idx name bytes type; do
    [ -n "$idx" ] || continue
    sectors=$(( bytes / 512 )); [ "$sectors" -gt 0 ] || sectors=1
    args+=(-n "$idx:$start:+$sectors" -c "$idx:$name")
    # An all-zero type is "unused" to sgdisk, so the `last_parti` rows keep the default rather than
    # being asked for something that would delete the entry they were just given.
    case "$type" in
      -|00000000-0000-0000-0000-000000000000) ;;
      *) args+=(-t "$idx:$type") ;;
    esac
    start=$(( start + sectors ))
    start=$(( (start + 2047) / 2048 * 2048 ))   # 1 MiB alignment, as on the captures
    total=$(( total + sectors + 2048 ))
  done
  [ "${#args[@]}" -gt 0 ] || return 1
  truncate -s $(( (total + 65536) * 512 )) "$img" || return 1
  sgdisk -Z "$img" >/dev/null 2>&1
  sgdisk "${args[@]}" "$img" >/dev/null 2>&1 || return 1
}
