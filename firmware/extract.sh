#!/usr/bin/env bash
# novadeck firmware extraction — Phase 1.
#
# Stages `device`-sourced firmware blobs (per a device manifest) out of a dump of
# the target device's vendor/modem partitions into firmware/extracted/<soc>/
# (git-ignored), recording a sha256 sidecar so image assembly is reproducible.
#
# Proprietary blobs are NEVER committed. This script only *stages* them locally for
# image assembly (Phase 4). Respect the device vendor's firmware license.
#
#   extract.sh <soc> <vendor-partition-tree>
#
# <vendor-partition-tree> is a mounted/unpacked tree of the device's own partitions
# (vendor, firmware_mnt/dsp images, odm, ...). Blobs live there under names like
# adsp.mbn / cdsp.mbn / gen70900_zap.mbn, NOT under the board-scoped install paths
# the manifest targets — so sources are matched by basename and ranked by location.
#
# Some dumps ship the signed DSP/modem images *split* as a Qualcomm `.mdt` (ELF
# header + program-header table) plus `.b00`/`.b01`/... segment files instead of a
# single `.mbn`. When the single file is absent, this script reassembles it by
# placing each `.bNN` at its program header's p_offset — preferring `pil-squasher`
# if installed, else an equivalent embedded python3 merge (ELF32/ELF64, any endian).
#
# Exit: 0 if every required entry was staged; 3 if any was missing (set
# EXTRACT_ALLOW_MISSING=1 to downgrade misses to a warning and still exit 0).
set -euo pipefail
shopt -s nullglob

SOC="${1:-}"
[ -n "$SOC" ] || { echo "usage: ${0##*/} <soc>" >&2; exit 2; }
SRC="${2:-}"   # path to a mounted/extracted vendor+modem partition tree
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$ROOT/devices/$SOC/firmware-manifest.txt"
OUT="$ROOT/firmware/extracted/$SOC"
SUMS="$OUT/sha256sums.txt"

[ -n "$SRC" ]      || { echo "usage: extract.sh <soc> <vendor-partition-tree>" >&2; exit 2; }
[ -d "$SRC" ]      || { echo "no such vendor tree: $SRC" >&2; exit 2; }
[ -f "$MANIFEST" ] || { echo "no manifest: $MANIFEST" >&2; exit 1; }

mkdir -p "$OUT"
: >"$SUMS"
echo "[novadeck] extracting '$SOC' firmware from $SRC -> $OUT"

ok=0; miss=0

# Rank a candidate source path: signed DSP/modem images live in firmware_mnt/dsp
# image dirs; everything else is less specific. Lower number = preferred.
rank_path() {
  case "$1" in
    *firmware_mnt/image/*|*/dsp/image/*) echo 0 ;;
    */firmware/*)                        echo 1 ;;
    *)                                   echo 2 ;;
  esac
}

# Echo the best single source file for a wanted basename, or nothing if absent.
# Prefers the highest-ranked location; warns when distinct contents collide.
find_blob() {
  local base="$1" best="" best_rank=9 sha first_sha="" ambig=0 f r
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    sha="$(sha256sum "$f" | cut -d' ' -f1)"
    if [ -z "$first_sha" ]; then first_sha="$sha"
    elif [ "$sha" != "$first_sha" ]; then ambig=1; fi
    r="$(rank_path "$f")"
    if [ "$r" -lt "$best_rank" ]; then best="$f"; best_rank="$r"; fi
  done < <(find "$SRC" -type f -name "$base" 2>/dev/null)
  [ -n "$best" ] || return 0
  [ "$ambig" -eq 0 ] || echo "  AMBIG $base — distinct copies found; using $best" >&2
  echo "$best"
}

# Reassemble a split Qualcomm image (<stem>.mdt + <stem>.bNN) into a single .mbn.
# Prefers pil-squasher; falls back to an embedded python3 reimplementation.
merge_split() {
  local mdt="$1" out="$2"
  if command -v pil-squasher >/dev/null 2>&1; then
    pil-squasher "$out" "$mdt" >/dev/null 2>&1 && [ -s "$out" ] && return 0
    return 1
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$mdt" "$out" <<'PY'
import sys, struct, os
mdt, out = sys.argv[1], sys.argv[2]
with open(mdt, 'rb') as f:
    hdr = f.read()
if hdr[:4] != b'\x7fELF':
    sys.stderr.write("  not an ELF .mdt: %s\n" % mdt); sys.exit(1)
ei_class, ei_data = hdr[4], hdr[5]
en = '<' if ei_data == 1 else '>'
if ei_class == 1:      # ELF32
    e_phoff = struct.unpack_from(en + 'I', hdr, 0x1c)[0]
    e_phentsize = struct.unpack_from(en + 'H', hdr, 0x2a)[0]
    e_phnum = struct.unpack_from(en + 'H', hdr, 0x2c)[0]
    fmt, off_off, off_filesz = 'I', 4, 16
elif ei_class == 2:    # ELF64
    e_phoff = struct.unpack_from(en + 'Q', hdr, 0x20)[0]
    e_phentsize = struct.unpack_from(en + 'H', hdr, 0x36)[0]
    e_phnum = struct.unpack_from(en + 'H', hdr, 0x38)[0]
    fmt, off_off, off_filesz = 'Q', 8, 32
else:
    sys.stderr.write("  unknown ELF class in %s\n" % mdt); sys.exit(1)
stem = mdt[:-4] if mdt.endswith('.mdt') else mdt
segs, end = [], 0
for i in range(e_phnum):
    ph = e_phoff + i * e_phentsize
    p_offset = struct.unpack_from(en + fmt, hdr, ph + off_off)[0]
    p_filesz = struct.unpack_from(en + fmt, hdr, ph + off_filesz)[0]
    if p_filesz == 0:
        continue
    seg = "%s.b%02d" % (stem, i)
    if not os.path.exists(seg):
        sys.stderr.write("  missing segment %s\n" % os.path.basename(seg)); sys.exit(2)
    with open(seg, 'rb') as sf:
        data = sf.read()
    segs.append((p_offset, data)); end = max(end, p_offset + len(data))
if not segs:
    sys.stderr.write("  no loadable segments for %s\n" % os.path.basename(mdt)); sys.exit(3)
buf = bytearray(end)
for off, data in segs:
    buf[off:off + len(data)] = data
with open(out, 'wb') as o:
    o.write(buf)
PY
    return $?
  fi
  echo "  (need pil-squasher or python3 to merge split images)" >&2
  return 1
}

stage_file() {
  local dest="$1" base src stem mdt merged
  base="$(basename "$dest")"
  src="$(find_blob "$base")"
  if [ -n "$src" ]; then
    install -Dm0644 "$src" "$OUT/$dest"
    ( cd "$OUT" && sha256sum "$dest" >>"$SUMS" )
    echo "  ok   $dest"
    ok=$((ok + 1))
    return
  fi
  # No single-file blob — try a split .mdt + .bNN image (signed DSP/modem images).
  stem="${base%.*}"
  mdt="$(find_blob "$stem.mdt")"
  if [ -n "$mdt" ]; then
    merged="$(mktemp)"
    if merge_split "$mdt" "$merged"; then
      install -Dm0644 "$merged" "$OUT/$dest"
      ( cd "$OUT" && sha256sum "$dest" >>"$SUMS" )
      rm -f "$merged"
      echo "  ok   $dest  (merged $(basename "$mdt") + segments)"
      ok=$((ok + 1))
    else
      rm -f "$merged"
      echo "  MISS $dest  (found $(basename "$mdt") but segment merge failed)"
      miss=$((miss + 1))
    fi
    return
  fi
  echo "  MISS $dest  (no '$base' or '$stem.mdt' in dump — verify name/location)"
  miss=$((miss + 1))
}

# Directory entries (manifest dest ends in '/', e.g. ath12k globs): locate the
# matching source subtree and stage every regular file under it, preserving layout.
stage_dir() {
  local dest="${1%/}" srcdir f rel
  srcdir="$(find "$SRC" -type d -path "*/$dest" 2>/dev/null | head -1 || true)"
  if [ -z "$srcdir" ]; then
    echo "  MISS $dest/  (no '$dest' dir in dump)"
    miss=$((miss + 1))
    return
  fi
  local n=0
  while IFS= read -r f; do
    rel="${f#"$srcdir"/}"
    install -Dm0644 "$f" "$OUT/$dest/$rel"
    ( cd "$OUT" && sha256sum "$dest/$rel" >>"$SUMS" )
    n=$((n + 1))
  done < <(find "$srcdir" -type f 2>/dev/null)
  echo "  ok   $dest/  ($n files)"
  ok=$((ok + 1))
}

# Read 'device'-tagged manifest lines; column 2 is the install-path under /lib/firmware.
while read -r dest; do
  [ -n "$dest" ] || continue
  case "$dest" in
    */) stage_dir "$dest" ;;
    *)  stage_file "$dest" ;;
  esac
done < <(grep -E '^device[[:space:]]' "$MANIFEST" | awk '{print $2}')

echo "Staged $ok entr$([ "$ok" -eq 1 ] && echo y || echo ies), $miss missing -> $OUT"
echo "sha256 sidecar: $SUMS"
echo "Done. extracted/ is git-ignored; consumed by image assembly (Phase 4)."

if [ "$miss" -gt 0 ] && [ "${EXTRACT_ALLOW_MISSING:-0}" != "1" ]; then
  exit 3
fi
