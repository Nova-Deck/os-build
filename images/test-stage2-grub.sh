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

# --- 2b. device-env can actually REACH every profile --------------------------------------------
# A fourth file has to agree and nothing checked it until a six-board SoC import made the gap
# obvious. fs-overlay/usr/lib/novadeck/device-env maps the devicetree `model` string to a profile
# name with a hand-written case. Miss a board there and it does not fail: it falls through to
# defaults.conf, so the running system reports device-id `unknown`, exports no SOC_CLASS (powerd
# loses its underclock table) and no panel dims (novadeck-session falls back to a generic
# landscape 1920x1080 on the wrong connector). No error, just a subtly wrong session.
CASE="device-env <-> profiles"
DEVENV="$ROOT/fs-overlay/usr/lib/novadeck/device-env"
if [ ! -r "$DEVENV" ]; then
  bad "cannot read $DEVENV"
else
  # Case arms look like:  "AYN Thor Lite")   profile=ayn-thor-lite ;;
  unset envprof; declare -A envprof
  unset envmodel; declare -A envmodel
  while IFS= read -r line; do
    m=$(printf '%s' "$line" | sed -n 's/^[[:space:]]*"\([^"]*\)").*profile=\([A-Za-z0-9._-]*\).*/\1/p')
    p=$(printf '%s' "$line" | sed -n 's/^[[:space:]]*"\([^"]*\)").*profile=\([A-Za-z0-9._-]*\).*/\2/p')
    [ -n "$p" ] || continue
    envprof["$p"]=1
    envmodel["$m"]=1
  done < "$DEVENV"

  for id in "${!confids[@]}"; do
    [ -n "${envprof[$id]:-}" ] && ok "device-env can select profile '$id'" \
      || bad "device-env has no model string mapping to '$id' -- that board silently gets defaults.conf"
  done
  for p in "${!envprof[@]}"; do
    [ -r "$DEVICES/$p.conf" ] && ok "device-env's '$p' arm has a profile file" \
      || bad "device-env maps a model to '$p', but $p.conf does not exist"
  done

  # And the case KEYS must be real model strings, or the match never fires on hardware. Compare
  # against the root `model` of every board .dts (following one level of #include for the boards
  # that inherit their root node from a sibling .dts).
  for dts in "$DTS"/*.dts; do
    mdl=$(sed -n 's/^[[:space:]]*model = "\(.*\)";.*/\1/p' "$dts" | head -1)
    [ -n "$mdl" ] || continue
    [ -n "${envmodel[$mdl]:-}" ] && ok "model '$mdl' is matched by device-env" \
      || bad "$(basename "$dts") declares model '$mdl', which device-env's case never matches"
  done
fi

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

# --- 4. the stage-2 module set carries what the config calls -------------------------------------
# A config that calls a module which was never embedded gets "unknown command", leaves the target
# variable unset, and carries on -- so `probe --part-uuid` missing from grubaa64.efi is not a boot
# failure, it is every boot silently taking the PARTLABEL fallback with one console line to show
# for it. probe is stock GRUB and builds unconditionally; it was simply never in MODULES.
#
# This is asserted here rather than in a boot/grub.sh test because the coupling is here: the
# generated config is the only caller, and the two files are edited for different reasons.
CASE="stage-2 module set"
MODLINE=$(sed -n '/^MODULES="/,/"$/p' "$ROOT/boot/grub.sh" | tr -d '\\\n')
if [ -z "$MODLINE" ]; then
  bad "cannot find the MODULES= assignment in boot/grub.sh"
else
  for m in probe regexp loadenv novadeck; do
    printf '%s' "$MODLINE" | grep -qw -- "$m" \
      && ok "boot/grub.sh embeds $m" \
      || bad "boot/grub.sh does not embed $m -- the config's $m calls are 'unknown command'"
  done
fi

# --- 5. the generated grub.cfg files ------------------------------------------------------------
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
  for key in 'root=$rootspec' 'novadeck.var=$varspec' 'novadeck.efi=$efispec' "novadeck.slot=$slot"; do
    n=$(grep -cF -- "$key" "$cfg")
    [ "$n" -eq "$n_entries" ] && ok "grub-$lc.cfg: all $n entries carry $key" \
                              || bad "grub-$lc.cfg: $n of $n_entries entries carry $key"
  done
  other=$([ "$slot" = A ] && echo b || echo a)
  grep -q -- "PARTLABEL=$(part_label "rootfs-$other")" "$cfg" \
    && bad "grub-$lc.cfg references the OTHER slot's root" \
    || ok "grub-$lc.cfg never references the other slot"
  grep -q -- "novadeck.slot=${other^^}" "$cfg" \
    && bad "grub-$lc.cfg tells the initramfs it is slot ${other^^}" \
    || ok "grub-$lc.cfg never claims to be slot ${other^^}"

  # PARTUUID, and the PARTLABEL fallback behind it. The three specs are set ONCE at the top and
  # referenced by every entry, so this is where the partition identity actually gets decided.
  for v in rootuuid varuuid efiuuid; do
    grep -q -- "probe --part-uuid --set=$v " "$cfg" \
      && ok "grub-$lc.cfg derives \$$v with probe --part-uuid" \
      || bad "grub-$lc.cfg never sets \$$v"
  done
  # The PARTUUID assignment must be reachable only when all three probes produced something. probe
  # sets the literal string "none" for a device with no partition rather than failing, so an
  # emptiness test alone would happily put root=PARTUUID=none on the cmdline.
  grep -q 'set rootspec="PARTUUID=\$rootuuid"' "$cfg" \
    && ok "grub-$lc.cfg names the root by PARTUUID when the probe succeeds" \
    || bad "grub-$lc.cfg never uses the probed PARTUUID"
  n_none=$(grep -o '!= "none"' "$cfg" | wc -l)
  [ "$n_none" -eq 3 ] && ok "grub-$lc.cfg rejects all three 'none' probe results" \
                      || bad "grub-$lc.cfg guards $n_none of 3 probe results against \"none\""
  # The fallback arm has to still emit the form that shipped before, or a probe regression is a
  # black screen instead of a message.
  for key in "set rootspec=\"PARTLABEL=$(part_label "rootfs-$lc")\"" \
             "set varspec=\"PARTLABEL=$(part_label "var-$lc")\"" \
             "set efispec=\"PARTLABEL=$(part_label "efi-$lc")\""; do
    grep -qF -- "$key" "$cfg" && ok "grub-$lc.cfg falls back to: $key" \
                              || bad "grub-$lc.cfg has no PARTLABEL fallback for ${key%%=*}"
  done
  # ...and the fallback must be the DEFAULT, assigned before the conditional overrides it. Set the
  # other way round, a failed probe leaves the specs unset and the kernel gets root= with no value.
  ln_fb=$(grep -n 'set rootspec="PARTLABEL=' "$cfg" | cut -d: -f1)
  ln_uu=$(grep -n 'set rootspec="PARTUUID=' "$cfg" | cut -d: -f1)
  [ -n "$ln_fb" ] && [ -n "$ln_uu" ] && [ "$ln_fb" -lt "$ln_uu" ] \
    && ok "grub-$lc.cfg defaults to PARTLABEL and upgrades to PARTUUID" \
    || bad "grub-$lc.cfg sets the PARTUUID spec before the PARTLABEL default, which then clobbers it"

  # Partition indices. They are no longer baked into the device specs: an internal install appends
  # our eight to the OEM's GPT at per-vendor indices, so the specs read variables and the numbers
  # come from parts.env on this slot's efi partition, falling back to the table's own order.
  for spec in "set esp=\"\$bootdisk,gpt\$esp_idx\"" \
              "set slotroot=\"\$bootdisk,gpt\$root_idx\"" \
              "probe --part-uuid --set=varuuid  (\$bootdisk,gpt\$var_idx)"; do
    grep -qF -- "$spec" "$cfg" && ok "grub-$lc.cfg addresses by index variable: ${spec%% *} ${spec#* }" \
      || bad "grub-$lc.cfg does not use an index VARIABLE here -- a baked index is wrong on internal: $spec"
  done
  # ...and the defaults behind those variables are the table's order, so a card is unchanged.
  for kv in "set esp_idx=$(part_num esp)" \
            "set root_idx=$(part_num "rootfs-$lc")" \
            "set var_idx=$(part_num "var-$lc")"; do
    grep -qx -- "$kv" "$cfg" && ok "grub-$lc.cfg defaults to: $kv" \
      || bad "grub-$lc.cfg's index default disagrees with ${TABLE#"$ROOT"/}: expected '$kv'"
  done

  # parts.env. It is read from (\$root) -- the efi partition steamcl chainloaded us from -- because
  # the ESP's own index is one of the numbers in it, so an ESP-resident map could not be located
  # without already knowing what it says.
  grep -q 'load_env -f (\$root)/EFI/steamos/parts.env ' "$cfg" \
    && ok "grub-$lc.cfg loads parts.env from the slot's own efi partition" \
    || bad "grub-$lc.cfg does not load (\$root)/EFI/steamos/parts.env"
  grep -q 'if \[ -f (\$root)/EFI/steamos/parts.env \]; then' "$cfg" \
    && ok "grub-$lc.cfg guards the load with -f, so a card without one is silent" \
    || bad "grub-$lc.cfg loads parts.env unguarded -- every pre-existing card would print an error"
  # Per-slot keys: slot A must take its indices from A's keys, and never from B's. The map is one
  # file shared by both slots, so picking the wrong key is a config that mounts the other slot's
  # /var -- the same failure the per-slot cmdline assertions above guard, one layer earlier.
  grep -qF -- "set root_idx=\"\$nd_root_$lc\"" "$cfg" \
    && ok "grub-$lc.cfg takes its root index from \$nd_root_$lc" \
    || bad "grub-$lc.cfg does not take its root index from \$nd_root_$lc"
  grep -qF -- "set var_idx=\"\$nd_var_$lc\"" "$cfg" \
    && ok "grub-$lc.cfg takes its var index from \$nd_var_$lc" \
    || bad "grub-$lc.cfg does not take its var index from \$nd_var_$lc"
  if grep -qF -- "_idx=\"\$nd_root_$other\"" "$cfg" || grep -qF -- "_idx=\"\$nd_var_$other\"" "$cfg"; then
    bad "grub-$lc.cfg takes an index from slot ${other^^}'s keys"
  else
    ok "grub-$lc.cfg never takes an index from slot ${other^^}'s keys"
  fi
  # ALL-OR-NOTHING. A file missing one key must not yield a map half from the install and half from
  # this build -- a root from one layout with a /var from another boots something nobody assembled.
  # So: exactly three -n tests, in ONE condition, and the three assignments only inside it.
  n_ntest=$(grep -c -- '-n "\$nd_' "$cfg")
  [ "$n_ntest" -eq 1 ] && ok "grub-$lc.cfg validates the loaded keys in a single condition" \
    || bad "grub-$lc.cfg has $n_ntest conditions testing nd_* keys, expected 1 (partial maps must be impossible)"
  n_keys=$(grep -o -- '-n "\$nd_[a-z_]*"' "$cfg" | wc -l)
  [ "$n_keys" -eq 3 ] && ok "grub-$lc.cfg requires all 3 consumed keys before using any" \
    || bad "grub-$lc.cfg tests $n_keys of the 3 keys it consumes"
  n_assign=$(grep -c -- 'set [a-z]*_idx="\$nd_' "$cfg")
  [ "$n_assign" -eq 3 ] && ok "grub-$lc.cfg upgrades all 3 indices together" \
    || bad "grub-$lc.cfg assigns $n_assign indices from parts.env, expected 3"
  # Defaults must be assigned BEFORE the load, or the upgrade is what gets clobbered.
  ln_def=$(grep -n "^set esp_idx=" "$cfg" | cut -d: -f1)
  ln_env=$(grep -n 'load_env -f (\$root)/EFI/steamos/parts.env ' "$cfg" | cut -d: -f1)
  [ -n "$ln_def" ] && [ -n "$ln_env" ] && [ "$ln_def" -lt "$ln_env" ] \
    && ok "grub-$lc.cfg sets the built-in indices before reading parts.env" \
    || bad "grub-$lc.cfg reads parts.env before its defaults, which then overwrite it"
  # The indices have to be settled before anything is addressed with them.
  ln_use=$(grep -n 'set esp="\$bootdisk,gpt\$esp_idx"' "$cfg" | cut -d: -f1)
  [ -n "$ln_use" ] && [ -n "$ln_env" ] && [ "$ln_env" -lt "$ln_use" ] \
    && ok "grub-$lc.cfg reads parts.env before it addresses a partition" \
    || bad "grub-$lc.cfg addresses partitions before parts.env is read"

  # THE DEVICE DERIVATION, executed rather than grepped. GRUB's `regexp` compiles with
  # REG_EXTENDED, so a POSIX ERE engine here (sed -E) is the same matcher the device runs -- which
  # makes this the one assertion that can catch a pattern that parses, ships, and never matches.
  # It did: the first version required literal parens around $root, but GRUB sets `root` to the
  # BARE device name (kern/main.c) and only parenthesises it for $prefix. The config fell through
  # to its search fallback on every boot, and the sole symptom was a message and a 3s pause.
  pat=$(sed -n "s/^regexp -s bootdisk '\(.*\)' \"\$root\"\$/\1/p" "$cfg")
  if [ -z "$pat" ]; then
    bad "grub-$lc.cfg has no 'regexp -s bootdisk' line"
  else
    ok "grub-$lc.cfg derives the boot disk with: $pat"
    for form in 'hd0,gpt2' '(hd0,gpt2)' 'hd0,gpt10'; do
      got=$(printf '%s' "$form" | sed -E "s|$pat|\1|")
      [ "$got" = "hd0" ] && ok "grub-$lc.cfg: \$root='$form' -> bootdisk=hd0" \
                         || bad "grub-$lc.cfg: \$root='$form' -> '$got', expected 'hd0' (the fallback search would run every boot)"
    done
  fi

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

  # boot-attempts. The counter is per-IMAGE state, so slot A's config must bump A's conf and only
  # A's: a config that counted the other slot's attempts would mark a healthy image bad and,
  # worse, let a failing one retry forever.
  other_uc="${other^^}"
  grep -q "^if novadeck_bootattempts $slot; then\$" "$cfg" \
    && ok "grub-$lc.cfg counts a boot attempt against image $slot" \
    || bad "grub-$lc.cfg does not call novadeck_bootattempts $slot"
  grep -q "novadeck_bootattempts $other_uc" "$cfg" \
    && bad "grub-$lc.cfg counts a boot attempt against the OTHER image ($other_uc)" \
    || ok "grub-$lc.cfg never names image $other_uc to novadeck_bootattempts"
  # It has to run where its errors can be seen. Its predecessor ran before the terminal was up and
  # a total failure was indistinguishable from success — which is the whole reason it was replaced.
  ln_term=$(grep -n '^terminal_output gfxterm$' "$cfg" | cut -d: -f1)
  ln_att=$(grep -n '^if novadeck_bootattempts ' "$cfg" | cut -d: -f1)
  [ -n "$ln_term" ] && [ -n "$ln_att" ] && [ "$ln_att" -gt "$ln_term" ] \
    && ok "grub-$lc.cfg counts the attempt after terminal_output gfxterm" \
    || bad "grub-$lc.cfg calls novadeck_bootattempts before the terminal is up"

  # Console. rotation is read once, when the video driver builds the framebuffer render target, so
  # a `set rotation=` that lands AFTER terminal_output parses fine, ships, and does nothing — the
  # ordering is the whole assertion. The colours have no such constraint.
  ln_rot=$(grep -n '^set rotation=270$' "$cfg" | cut -d: -f1)
  [ -n "$ln_rot" ] \
    && ok "grub-$lc.cfg rotates the framebuffer 270" \
    || bad "grub-$lc.cfg does not set rotation=270 — patch 0001 is inert without it"
  [ -n "$ln_rot" ] && [ -n "$ln_term" ] && [ "$ln_rot" -lt "$ln_term" ] \
    && ok "grub-$lc.cfg sets rotation before terminal_output gfxterm" \
    || bad "grub-$lc.cfg sets rotation after the terminal is up, where it is a no-op"
  grep -q '^set menu_color_normal=cyan/blue$' "$cfg" \
    && ok "grub-$lc.cfg sets menu_color_normal" \
    || bad "grub-$lc.cfg does not set menu_color_normal"
  grep -q '^set menu_color_highlight=white/blue$' "$cfg" \
    && ok "grub-$lc.cfg sets menu_color_highlight" \
    || bad "grub-$lc.cfg does not set menu_color_highlight"

  # Every arm that prints a diagnostic must hold it on screen long enough to READ. gfxterm draws in
  # the boot font, already at the only scale lever we have, and 3s was measured too short on a
  # Pocket S2 panel (2026-08-06). A pause that drifts back down makes the message useless on the one
  # class of device that has no other diagnostic at all.
  n_short=$(grep -cE '^ *sleep [1-9]$' "$cfg")
  [ "$n_short" -eq 0 ] && ok "grub-$lc.cfg holds every diagnostic for 10s or more" \
    || bad "grub-$lc.cfg has $n_short arm(s) pausing under 10s — unreadable on a handheld panel"
  n_sleep=$(grep -cE '^ *sleep 10$' "$cfg")
  [ "$n_sleep" -eq 4 ] && ok "grub-$lc.cfg: all 4 diagnostic arms pause 10s" \
    || bad "grub-$lc.cfg has $n_sleep 10s pauses, expected 4 (an arm lost its dwell, or gained one)"

  if command -v grub-script-check >/dev/null 2>&1; then
    grub-script-check "$cfg" 2>"$T/gscerr" \
      && ok "grub-$lc.cfg parses under grub-script-check" \
      || bad "grub-$lc.cfg is not valid GRUB script: $(head -1 "$T/gscerr")"
  else
    skip "grub-script-check not installed (it is in the build container)"
  fi
done

# --- 6. the board bootargs left the device trees ------------------------------------------------
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
