#!/usr/bin/env bash
# novadeck partition-script generator — Phase 4.
#
# Turns images/partition-table.txt into a runnable sgdisk script that lays down the
# A/B GPT on a target disk/image. Prints the script to stdout; with a target it also
# applies it. Side-effect-free unless a target is given.
#
#   images/genpart.sh            # print sgdisk script
#   images/genpart.sh --min      # print only the minimum target size in MiB
#   images/genpart.sh <target>   # also apply to <target> (disk or image file)
set -euo pipefail

TARGET="${1:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TABLE="$ROOT/images/partition-table.txt"
[ -f "$TABLE" ] || { echo "no partition table: $TABLE" >&2; exit 1; }

# Sum the fixed partition sizes (MiB) for a minimum-target-size hint; 'rest' is 0.
minmib="$(awk '
  /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
  { s=$2; u=substr(s,length(s),1); v=substr(s,1,length(s)-1)
    if (u=="G") m+=v*1024; else if (u=="M") m+=v }
  END { print m+1 }' "$TABLE")"   # +1 MiB GPT/alignment slack

# make-sdcard.sh sizes its image file off this, so the fixed layout stays defined in one place.
if [ "$TARGET" = "--min" ]; then
  echo "$minmib"
  exit 0
fi

# One sgdisk -n/-t/-c per row; 'rest' -> 0:0 (fills the disk). A row's 'attrs' column adds one
# --attributes per GPT bit, applied after the partition exists.
partlines="$(awk '
  /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
  { n++
    spec = ($2 == "rest") ? "0:0" : "0:+" $2
    printf "sgdisk -n %d:%s -t %d:%s -c %d:%s \"$DISK\"\n", n, spec, n, $3, n, $5
    if ($6 != "" && $6 != "-") {
      k = split($6, bits, ",")
      for (i = 1; i <= k; i++) printf "sgdisk --attributes=%d:set:%s \"$DISK\"\n", n, bits[i]
    }
  }' "$TABLE")"

emit() {
  echo "# novadeck A/B GPT — generated from images/partition-table.txt"
  echo "# minimum target size: ${minmib} MiB ('home' expands to fill the rest)"
  echo 'DISK="${DISK:?set DISK to the target disk or image}"'
  echo 'sgdisk -Z "$DISK"   # zap any existing GPT/MBR'
  echo "$partlines"
  echo 'sgdisk -p "$DISK"   # print resulting table'
}

if [ -z "$TARGET" ]; then
  emit
  exit 0
fi

command -v sgdisk >/dev/null 2>&1 || { echo "sgdisk not found (run inside novadeck-build)" >&2; exit 1; }
echo "[novadeck] applying A/B GPT to $TARGET (min ${minmib} MiB)" >&2
DISK="$TARGET" bash -euo pipefail -c "$(emit)"
