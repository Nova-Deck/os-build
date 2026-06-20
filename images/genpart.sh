#!/usr/bin/env bash
# novadeck partition-script generator — Phase 4.
#
# Turns images/partition-table.txt into a runnable sgdisk script that lays down the
# A/B GPT on a target disk/image. Prints the script to stdout; with a target it also
# applies it. Side-effect-free unless a target is given.
#
#   images/genpart.sh <soc>            # print sgdisk script
#   images/genpart.sh <soc> <target>   # also apply to <target> (disk or image file)
set -euo pipefail

SOC="${1:-}"
[ -n "$SOC" ] || { echo "usage: ${0##*/} <soc>" >&2; exit 2; }
TARGET="${2:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TABLE="$ROOT/images/partition-table.txt"
[ -f "$TABLE" ] || { echo "no partition table: $TABLE" >&2; exit 1; }

# Sum the fixed partition sizes (MiB) for a minimum-target-size hint; 'rest' is 0.
minmib="$(awk '
  /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
  { s=$2; u=substr(s,length(s),1); v=substr(s,1,length(s)-1)
    if (u=="G") m+=v*1024; else if (u=="M") m+=v }
  END { print m+1 }' "$TABLE")"   # +1 MiB GPT/alignment slack

# One sgdisk -n/-t/-c per row; 'rest' -> 0:0 (fills the disk).
partlines="$(awk '
  /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
  { n++
    spec = ($2 == "rest") ? "0:0" : "0:+" $2
    printf "sgdisk -n %d:%s -t %d:%s -c %d:%s \"$DISK\"\n", n, spec, n, $3, n, $5
  }' "$TABLE")"

emit() {
  echo "# novadeck $SOC A/B GPT — generated from images/partition-table.txt"
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
