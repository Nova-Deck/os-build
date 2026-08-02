#!/usr/bin/env bash
# Offline parity test for the phase-5 stage-2 GRUB data model.
#
# Three files have to agree about what a board IS, and each of them is edited for a different
# reason, so they drift silently:
#
#   boot/boards.map                              build-time catalog: id / menu name / dtb / bootargs
#   kernel/dts/qcom/*.dts                        the DTBs that actually ship
#   fs-overlay/usr/lib/novadeck/devices/*.conf   the identity the RUNNING system reports
#
# and then boot/gen-grub-cfg.sh turns the first into a grub.cfg whose per-slot cmdline has to match
# images/partition-table.txt. A mismatch anywhere is a board that cannot be selected, a menu entry
# that boots the wrong DTB, or a slot that mounts the other slot's /var.
#
#   images/test-stage2-grub.sh
#
# Everything runs on the host with no root, no device and no cross-build: the configs under test
# are GENERATED here into a temp dir, so this never skips and never asserts against a stale
# out/boot from some earlier build. Run via `make test`.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVICES="$ROOT/fs-overlay/usr/lib/novadeck/devices"
BOARDS="$ROOT/boot/boards.map"
TABLE="$ROOT/images/partition-table.txt"
DTS="$ROOT/kernel/dts/qcom"
GEN="$ROOT/boot/gen-grub-cfg.sh"

PASS=0; FAIL=0; SKIP=0; CASE=""
ok()   { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }
skip() { SKIP=$((SKIP+1)); printf '  skip %s -- %s\n' "$CASE" "$1"; }

for f in "$BOARDS" "$TABLE" "$GEN"; do
  [ -e "$f" ] || { echo "missing input: $f" >&2; exit 1; }
done
[ -d "$DTS" ] || { echo "missing dts dir: $DTS" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

part_num()   { awk -v n="$1" '/^[[:space:]]*#/||/^[[:space:]]*$/{next} {i++; if ($1==n) {print i; exit}}' "$TABLE"; }
part_label() { awk -v n="$1" '/^[[:space:]]*#/||/^[[:space:]]*$/{next} {if ($1==n) {print $5; exit}}' "$TABLE"; }

# --- 1. every catalog row names a real board DTB and carries bootargs --------------------------
CASE="board catalog -> DTB"
unset pids;  declare -A pids
unset pdtbs; declare -A pdtbs
ncat=0
while IFS=$'\t' read -r id name dtb ba; do
  [ -n "$id" ] || continue
  [[ $id == \#* ]] && continue
  ncat=$((ncat+1))
  [ -n "$name" ] || bad "$id has no menu name in the catalog"
  [ -n "$dtb" ] || { bad "$id has no DTB in the catalog"; continue; }
  [ -n "$ba" ] || bad "$id has no bootargs in the catalog"
  pids["$id"]=1
  pdtbs["$dtb"]=1
  [ -f "$DTS/$dtb.dts" ] && ok "$id -> $dtb.dts" || bad "$id names missing DTB $dtb.dts"
done < "$BOARDS"
[ "$ncat" -gt 0 ] && ok "$ncat boards in the catalog" || bad "the catalog is empty"

# --- 2. the catalog and the runtime device profiles agree on identity ---------------------------
# The menuentry id is what the user picks; NOVADECK_DEVICE_ID is what device-env reports at
# runtime. They are the same identity and must stay spelled the same, or a board is selectable
# under a name the OS has never heard of.
CASE="catalog <-> device profiles"
unset confids; declare -A confids
for f in "$DEVICES"/*.conf; do
  [ "$(basename "$f")" = "defaults.conf" ] && continue
  id=$(sed -n 's/^NOVADECK_DEVICE_ID=//p' "$f" | head -1 | tr -d "'\"")
  [ -n "$id" ] && confids["$id"]=1 || bad "$(basename "$f") has no NOVADECK_DEVICE_ID"
done
[ "${#confids[@]}" -eq "$ncat" ] \
  && ok "${#confids[@]} device profiles, ${ncat} catalog rows" \
  || bad "${#confids[@]} device profiles vs $ncat catalog rows"
for id in "${!pids[@]}"; do
  [ -n "${confids[$id]:-}" ] && ok "catalog id '$id' has a device profile" \
                             || bad "catalog id '$id' has no device profile"
done
for id in "${!confids[@]}"; do
  [ -n "${pids[$id]:-}" ] && ok "device profile '$id' has a catalog row" \
                          || bad "device profile '$id' is missing from the catalog"
done

# --- 3. every shipped DTB is reachable from the menu --------------------------------------------
# A DTB with no catalog row is only legal when it is a hardware variant deriving from one (the
# RP6's top-dpad revision). Anything else ships a board nobody can boot.
CASE="DTB -> menuentry"
ndtb=0
for dts in "$DTS"/*.dts; do
  base=$(basename "$dts" .dts)
  ndtb=$((ndtb+1))
  if [ -n "${pdtbs[$base]:-}" ]; then
    ok "$base covered by a catalog row"
  elif [ -n "${pdtbs[${base%-top-dpad}]:-}" ] && [ "$base" != "${base%-top-dpad}" ]; then
    ok "$base covered by the derived ${base%-top-dpad} entry"
  else
    bad "$base has no catalog row and no parent to derive from"
  fi
done
ok "$ndtb board DTBs, $ncat catalog rows, $((ndtb - ncat)) derived"

# --- 4. the generated grub.cfg files ------------------------------------------------------------
CASE="generated grub.cfg"
for slot in A B; do
  lc="${slot,,}"
  cfg="$T/grub-$lc.cfg"
  if ! "$GEN" "$slot" "$cfg" >/dev/null 2>"$T/generr"; then
    bad "gen-grub-cfg.sh $slot failed: $(head -1 "$T/generr")"
    continue
  fi
  ok "gen-grub-cfg.sh $slot produced a config"

  # one menuentry per board, ids intact
  n_entries=$(grep -c '^menuentry ' "$cfg")
  [ "$n_entries" -eq "$ndtb" ] && ok "grub-$lc.cfg has $n_entries entries (one per DTB)" \
                               || bad "grub-$lc.cfg has $n_entries entries, expected $ndtb"
  for id in "${!pids[@]}"; do
    grep -q -- "--id $id\$\|--id $id " "$cfg" && ok "grub-$lc.cfg has an entry for $id" \
                                              || bad "grub-$lc.cfg is missing an entry for $id"
  done

  # the per-slot cmdline. Every entry must name THIS slot's root, var and efi partitions -- one
  # entry pointing at the other slot is a boot that silently mounts the wrong /var.
  for key in "root=PARTLABEL=$(part_label "rootfs-$lc")" \
             "novadeck.var=PARTLABEL=$(part_label "var-$lc")" \
             "novadeck.efi=PARTLABEL=$(part_label "efi-$lc")"; do
    n=$(grep -c -- "$key" "$cfg")
    [ "$n" -eq "$n_entries" ] && ok "grub-$lc.cfg: all $n entries carry $key" \
                              || bad "grub-$lc.cfg: $n of $n_entries entries carry $key"
  done
  other=$([ "$slot" = A ] && echo b || echo a)
  grep -q -- "PARTLABEL=$(part_label "rootfs-$other")" "$cfg" \
    && bad "grub-$lc.cfg references the OTHER slot's root" \
    || ok "grub-$lc.cfg never references the other slot"

  # partition indices must match the table this was generated from
  grep -q "set esp=\"\$bootdisk,gpt$(part_num esp)\"" "$cfg" \
    && ok "grub-$lc.cfg finds the ESP at gpt$(part_num esp)" \
    || bad "grub-$lc.cfg ESP index disagrees with ${TABLE#"$ROOT"/}"
  grep -q "set slotroot=\"\$bootdisk,gpt$(part_num "rootfs-$lc")\"" "$cfg" \
    && ok "grub-$lc.cfg finds the root at gpt$(part_num "rootfs-$lc")" \
    || bad "grub-$lc.cfg root index disagrees with ${TABLE#"$ROOT"/}"

  # the saved board choice. savedefault is called by every entry and is NOT a GRUB builtin, so a
  # config that does not DEFINE it saves nothing and silently prints an error per entry.
  grep -q '^function savedefault {' "$cfg" && ok "grub-$lc.cfg defines savedefault" \
                                           || bad "grub-$lc.cfg calls savedefault without defining it"
  n_save=$(grep -c '^  savedefault$' "$cfg")
  [ "$n_save" -eq "$n_entries" ] && ok "grub-$lc.cfg: all $n_save entries call savedefault" \
                                 || bad "grub-$lc.cfg: $n_save of $n_entries entries call savedefault"
  grep -q 'load_env -f (\$esp)/EFI/steamos/grubenv' "$cfg" \
    && ok "grub-$lc.cfg loads the ESP grubenv" || bad "grub-$lc.cfg does not load the grubenv"
  grep -q 'save_env -f (\$esp)/EFI/steamos/grubenv' "$cfg" \
    && ok "grub-$lc.cfg saves to the ESP grubenv" || bad "grub-$lc.cfg does not save the grubenv"
  # A config that never sets a timeout waits forever (GRUB treats unset as -1); one that sets only
  # a hidden timeout gives a keyboard-less device no way back to the menu.
  grep -q '^  set timeout=3$' "$cfg" && ok "grub-$lc.cfg boots the saved entry after 3s" \
                                     || bad "grub-$lc.cfg has no timeout for the saved-entry path"
  grep -q '^  set timeout=-1$' "$cfg" && ok "grub-$lc.cfg waits when no board is saved" \
                                      || bad "grub-$lc.cfg does not wait on a fresh card"

  # steamenv is built into grubaa64.efi but must not be INVOKED yet: steamenv_init overwrites
  # timeout/timeout_style after this config has set them, and it is what bumps boot-attempts.
  # Reintroducing it is a separate, deliberate step (docs/phase5.md).
  grep -q 'steamenv_' "$cfg" && bad "grub-$lc.cfg invokes a steamenv_ command" \
                             || ok "grub-$lc.cfg invokes no steamenv_ command"

  if command -v grub-script-check >/dev/null 2>&1; then
    grub-script-check "$cfg" 2>"$T/gscerr" \
      && ok "grub-$lc.cfg parses under grub-script-check" \
      || bad "grub-$lc.cfg is not valid GRUB script: $(head -1 "$T/gscerr")"
  else
    skip "grub-script-check not installed (it is in the build container)"
  fi
done

# --- 5. the board bootargs left the device trees ------------------------------------------------
# They live on the `linux` line now. They have to: the EFI stub OVERWRITES /chosen/bootargs with
# the loader's command line, so anything still in a dtsi is silently dropped.
CASE="dtsi bootargs stripped"
n_ba=0
for f in "$DTS"/*.dtsi; do
  grep -q 'bootargs *=' "$f" && { n_ba=$((n_ba+1)); bad "$(basename "$f") still carries /chosen/bootargs"; }
done
[ "$n_ba" -eq 0 ] && ok "no /chosen/bootargs remain in the dtsi files"

printf '\n%s: %d passed, %d failed, %d skipped\n' "$(basename "$0")" "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
