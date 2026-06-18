#!/usr/bin/env bash
# novadeck firmware manifest verifier — Phase 1.
#
# Derives the ground-truth firmware set the *built* kernel will actually request
# and cross-checks it against the device manifest. Two sources of truth:
#   1. firmware-name properties in the built DTBs   (request_firmware via DT)
#   2. MODULE_FIRMWARE entries in the built modules  (request_firmware in drivers)
#
# Run AFTER kernel/build.sh (needs out/<soc>/dtbs + work/kernel/<ver> modules).
# Reports manifest entries that are unbacked and required firmware the manifest
# does not list. Run inside the build image (needs dtc + objcopy):
#   docker run ... novadeck-kbuild firmware/manifest.sh sm8650
set -euo pipefail
shopt -s nullglob

SOC="${1:-sm8650}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$ROOT/devices/$SOC/firmware-manifest.txt"
OUT="$ROOT/out/$SOC"

PIN="$ROOT/kernel/SOURCE.pin"
KVER="$(sed -n 's/^version:[[:space:]]*//p' "$PIN" | head -1)"
KDIR="${WORK:-$ROOT/work/kernel}/linux-${KVER}"

[ -f "$MANIFEST" ] || { echo "no manifest: $MANIFEST" >&2; exit 1; }
[ -d "$OUT/dtbs" ] || { echo "no built dtbs: $OUT/dtbs (run kernel/build.sh first)" >&2; exit 1; }

DTC="$(command -v dtc || true)"
OBJCOPY="$(command -v aarch64-linux-gnu-objcopy || command -v objcopy || true)"

# --- 1. firmware-name from the built DTBs (authoritative for DT-driven loads) ---
dt_fw="$(mktemp)"
if [ -n "$DTC" ]; then
  for d in "$OUT"/dtbs/*.dtb; do
    "$DTC" -I dtb -O dts "$d" 2>/dev/null \
      | grep -oE 'firmware-name = "[^"]*"' | sed -E 's/.*"(.*)"/\1/' \
      | sed 's/\\0/\n/g'   # DT multi-string: one prop may list several blobs
  done | sort -u >"$dt_fw"
else
  echo "WARN: dtc not found — skipping DTB firmware-name check" >&2
fi

# --- 2. MODULE_FIRMWARE from built modules + built-in drivers (driver loads) ---
# Loadable modules carry it in each .ko's .modinfo; built-in (=y) drivers record it
# in modules.builtin.modinfo. Scan both, or a built-in driver (e.g. DRM_MSM=y with
# its GPU GMU/SQE microcode) is invisible to a .ko-only scan. A directory request is
# expressed as a glob 'dir/*'; normalize it to 'dir/' so it matches a manifest dir.
mod_fw="$(mktemp)"
if [ -d "$KDIR" ]; then
  {
    if [ -n "$OBJCOPY" ]; then
      while IFS= read -r ko; do
        "$OBJCOPY" -O binary --only-section=.modinfo "$ko" /dev/stdout 2>/dev/null \
          | tr '\0' '\n' | sed -n 's/^firmware=//p'
      done < <(find "$KDIR" -name '*.ko' 2>/dev/null)
    else
      echo "WARN: objcopy missing — skipping loadable-module firmware scan" >&2
    fi
    # built-in drivers: NUL-separated '<modname>.firmware=<path>' entries.
    [ -f "$KDIR/modules.builtin.modinfo" ] \
      && tr '\0' '\n' <"$KDIR/modules.builtin.modinfo" | sed -n 's/.*\.firmware=//p'
  } | grep -E '^(qcom|ath1[12]k|qca)/' \
    | sed 's|/\*$|/|' \
    | sort -u >"$mod_fw"   # scope to Qualcomm SoC radios/DSPs; normalize dir globs
else
  echo "WARN: module tree missing ($KDIR) — skipping MODULE_FIRMWARE check" >&2
fi

# --- manifest install-paths (column 2 of non-comment lines) ---
man_fw="$(mktemp)"
grep -vE '^[[:space:]]*(#|$)' "$MANIFEST" | awk '{print $2}' | sort -u >"$man_fw"

echo "== novadeck firmware verify: $SOC (kernel $KVER) =="
echo "DTB firmware-name: $(wc -l <"$dt_fw")   MODULE_FIRMWARE: $(wc -l <"$mod_fw")   manifest entries: $(wc -l <"$man_fw")"

echo "--- DT-requested firmware NOT in manifest (REQUIRED) ---"
comm -23 "$dt_fw" "$man_fw" | sed 's/^/  MISSING  /' || true
echo "--- module-requested firmware NOT in manifest (review; globs expected) ---"
comm -23 "$mod_fw" "$man_fw" | sed 's/^/  review   /' || true
echo "--- manifest entries with no DT/module backing (verify still needed) ---"
comm -23 "$man_fw" <(cat "$dt_fw" "$mod_fw" | sort -u) | sed 's/^/  unbacked /' || true

rm -f "$dt_fw" "$mod_fw" "$man_fw"
echo "Done. Manifest is advisory until validated on target hardware."
