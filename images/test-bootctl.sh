#!/usr/bin/env bash
# Offline test for /usr/bin/novadeck-bootctl — above all, for its RAUC backend contract.
#
#   images/test-bootctl.sh
#
# WHY THIS FILE EXISTS. The Phase 4 suite proved that a broken backend ships silently and costs a
# hardware install at 40%: `set-state <slot> bad` returned exit 1 for the slot RAUC was about to
# overwrite (a state file can only be written when it can be read), so the first real `rauc install`
# aborted mid-copy with "Failed marking slot rootfs.1 as bad". It needed no hardware to catch.
# Phase 5 replaces the whole state writer with Valve's backend over steamos-bootconf; the lesson
# is the same: the CONTRACT IS THE EXIT STATUS, and every legal call must exit 0 including no-ops.
# RAUC treats a non-zero backend exit as a failed install.
#
# IT ALSO ENUMERATES THE CONTRACT. A subcommand RAUC calls but this tool does not dispatch must
# fail here, not on hardware — see `backend-is-complete`.
#
# HOW IT WORKS: the real, shipped novadeck-bootctl is executed — not a copy, not a sed-mangled
# variant. It exposes three environment seams (BOOTINFO, SESSION_MARKER, BC) that exist for this
# and are documented as such at the top of the tool. steamos-bootconf itself is stubbed on disk
# with a faithful mini-implementation (see the stub's header comment for which bootconf behaviours
# it mirrors and why). What runs here is the artifact that ships.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BOOTCTL="$ROOT/fs-overlay/usr/bin/novadeck-bootctl"
[ -f "$BOOTCTL" ] || { echo "no novadeck-bootctl: $BOOTCTL" >&2; exit 1; }

PASS=0; FAIL=0; CASE=""; SB=""
OUT=""; RC=0

ok()  { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }

# --- steamos-bootconf stub ----------------------------------------------------------------------
#
# Mirrors the behaviours the bootctl leans on:
#   * `config --get KEY` prints `key: value` and fails only when the whole CONFIG FILE is missing.
#     The real bootconf keeps the full schema loaded, so a config file that lacks, say, image-invalid
#     still answers `image-invalid: 0` (get_conf_item/snprint_item in the chainloader) — a missing
#     FILE is the only thing that makes get-state's "missing boot configuration" fire. That is
#     exactly what RAUC get-state needs: a slot that never booted must answer good, not die.
#   * `config` with no --get/--set creates a missing config (bootconf's create_missing defaults on),
#     which is what ensure_exists relies on before a set-state/set-primary.
#   * `set-mode reboot` clears boot-other, `reboot-other` sets it, `booted` clears boot-attempts and
#     bumps boot-count; all record the next selected image in __selected.
#   * `this-image` answers from __self; `selected-image` from __selected (dev when nothing armed).
STUB='#!/usr/bin/env bash
set -u
CONF=""; EFI=""; IMAGE=""
cmd=""; pos=(); gets=(); sets=()
args=("$@"); i=0
while [ "$i" -lt "${#args[@]}" ]; do
  a="${args[$i]}"; i=$((i+1))
  case "$a" in
    --conf-dir) CONF="${args[$i]}"; i=$((i+1)) ;;
    --efi-dir)  EFI="${args[$i]}";  i=$((i+1)) ;;
    --image)    IMAGE="${args[$i]}"; i=$((i+1)) ;;
    --get)      gets+=("${args[$i]}"); i=$((i+1)) ;;
    --set)      sets+=("${args[$i]} ${args[$((i+1))]}"); i=$((i+2)) ;;
    -v|--verbose) ;;
    --*) echo "stub: unknown option $a" >&2; exit 2 ;;
    *)
      if [ -z "$cmd" ]; then cmd="$a"; else pos+=("$a"); fi ;;
  esac
done

self()   { cat "$CONF/__self"; }
target() { printf "%s" "${IMAGE:-$(self)}"; }
get_u()  { sed -n "s/^$2: //p" "$CONF/$1.conf" 2>/dev/null | head -1; }
apply_set() {
  local t="$1" k="$2" v="$3" tmp
  [ -f "$CONF/$t.conf" ] || : > "$CONF/$t.conf"
  tmp="$CONF/$t.conf.tmp"
  sed "s/^$k: .*/$k: $v/" "$CONF/$t.conf" > "$tmp"
  grep -q "^$k: " "$tmp" || printf "%s: %s\n" "$k" "$v" >> "$tmp"
  mv "$tmp" "$CONF/$t.conf"
}

case "$cmd" in
  this-image) self ;;
  selected-image) cat "$CONF/__selected" 2>/dev/null || echo dev ;;
  list-images)
    for i in A B dev; do
      [ -f "$CONF/$i.conf" ] || continue
      m=" "; [ "$i" = "$(self)" ] && m="*"
      printf "+ %s %s\n" "$i" "$m"
    done
    ;;
  set-mode)
    T="$(target)"
    [ -f "$CONF/$T.conf" ] || { echo "stub: no config for image $T" >&2; exit 1; }
    case "${pos[0]:-}" in
      reboot)       apply_set "$T" boot-other 0 ;;
      reboot-other) apply_set "$T" boot-other 1 ;;
      booted)
        apply_set "$T" boot-attempts 0
        apply_set "$T" boot-count "$(( $(get_u "$T" boot-count) + 1 ))"
        apply_set "$T" boot-time "$(date +%s)"
        ;;
      shutdown|first-boot) ;;
      *) echo "stub: bad mode ${pos[0]:-}" >&2; exit 1 ;;
    esac
    for s in "${sets[@]}"; do apply_set "$T" $s; done
    apply_set "$T" boot-requested-at "$(date +%s)"
    printf "%s\n" "$T" > "$CONF/__selected"
    ;;
  config)
    T="$(target)"
    if [ "${#gets[@]}" -eq 0 ] && [ "${#sets[@]}" -eq 0 ]; then
      # create_missing: create only, never rewrite an existing config (bootconf only saves on
      # alteration).
      [ -f "$CONF/$T.conf" ] || : > "$CONF/$T.conf"
      exit 0
    fi
    [ -f "$CONF/$T.conf" ] || { echo "stub: no configuration selected" >&2; exit 1; }
    for s in "${sets[@]}"; do apply_set "$T" $s; done
    for k in "${gets[@]}"; do
      v=$(get_u "$T" "$k"); printf "%s: %s\n" "$k" "${v:-0}"
    done
    ;;
  create)
    T="$(target)"
    [ -f "$CONF/$T.conf" ] || : > "$CONF/$T.conf"
    for s in "${sets[@]}"; do apply_set "$T" $s; done
    ;;
  *) echo "stub: unknown command $cmd" >&2; exit 2 ;;
esac
'

# --- sandbox ------------------------------------------------------------------------------------

sandbox() {
  SB="$(mktemp -d)"
  mkdir -p "$SB/bin" "$SB/conf" "$SB/efi" "$SB/run"
  printf '%s\n' "$STUB" >"$SB/bin/steamos-bootconf"
  chmod +x "$SB/bin/steamos-bootconf"
  reset
}
done_() { rm -rf "$SB"; }
t() { CASE="$1"; sandbox; }

reset() {
  rm -f "$SB"/conf/*.conf "$SB"/conf/__self "$SB"/conf/__selected "$SB"/marker
  printf 'A\n'   >"$SB/conf/__self"
  printf 'dev\n' >"$SB/conf/__selected"
  printf 'boot-attempts: 0\nimage-invalid: 0\n' >"$SB/conf/A.conf"
  printf 'boot-attempts: 0\nimage-invalid: 0\n' >"$SB/conf/B.conf"
  seed_boot A
}

seed_boot() { printf 'slot=%s\nsource=%s\n' "$1" "${2:-state}" >"$SB/run/boot"; }
set_self()  { printf '%s\n' "$1" >"$SB/conf/__self"; }
set_sel()   { printf '%s\n' "$1" >"$SB/conf/__selected"; }
put_conf() {  # <ident> <key> <value>
  local f="$SB/conf/$1.conf"
  [ -f "$f" ] || : >"$f"
  if grep -q "^$2: " "$f"; then sed -i "s/^$2: .*/$2: $3/" "$f"; else printf '%s: %s\n' "$2" "$3" >>"$f"; fi
}
marker() { : >"$SB/marker"; }
boot_()  { BOOTINFO="$SB/run/boot" SESSION_MARKER="$SB/marker" \
           BC="$SB/bin/steamos-bootconf" BC_ARGS="--conf-dir $SB/conf --efi-dir $SB/efi" \
           bash "$BOOTCTL" "$@" 2>&1; }

# Run the SHIPPED tool against the sandbox. Captures stdout+stderr and the exit status.
bc() { OUT=$(boot_ "$@"); RC=$?; return 0; }

# --- assertions ---------------------------------------------------------------------------------

expect_rc()     { [ "$RC" = "$1" ] && ok "exit=$1" || bad "exit: expected $1, got $RC (output: $OUT)"; }
expect_out()    { [ "$OUT" = "$1" ] && ok "printed '$1'" || bad "expected '$1', got '$OUT'"; }
expect_has()    { case "$OUT" in *"$1"*) ok "mentions '$1'" ;; *) bad "expected '$1' in output, got '$OUT'" ;; esac; }
conf_field()    { sed -n "s/^$2: //p" "$SB/conf/$1.conf" 2>/dev/null | head -1; }
expect_conf()   { local got; got=$(conf_field "$1" "$2"); \
                  [ "$got" = "$3" ] && ok "$1 $2='$3'" || bad "$1 $2: expected '$3', got '$got'"; }
expect_sel()    { local got; got=$(cat "$SB/conf/__selected"); \
                  [ "$got" = "$1" ] && ok "selected=$1" || bad "selected: expected $1, got $got"; }
expect_conf_absent() { [ -e "$SB/conf/$1.conf" ] && bad "$1.conf should not exist" || ok "$1.conf absent"; }

echo "== RAUC backend: the contract is the EXIT STATUS =="

# The Phase 4 regression that cost the first hardware install, restated for Phase 5: RAUC marks the
# slot it is about to overwrite bad, and that slot may not exist yet on a fresh device. set-state
# must exit 0 and CREATE the config rather than fail.
t "set-state-bad-on-a-never-installed-slot-exits-0"
rm -f "$SB/conf/B.conf"
bc set-state B bad
expect_rc 0
expect_conf B image-invalid 1
done_

t "backend-exits-0-on-every-legal-call"
# A table rather than prose so a MISSING subcommand is as visible as a broken one: this list is the
# contract RAUC consumes. Each call gets a pristine state, because several write and the point here
# is the status of the call in isolation.
for call in "get-current" "get-primary" "get-state A" "get-state B" "get-state self" \
            "set-primary A" "set-primary B" "set-primary self" \
            "set-state A good" "set-state B good" "set-state A bad" "set-state B bad" \
            "set-state self good" "set-state self bad" \
            "mark-good" "mark-good --require-marker" "mark-good --require-marker --wait 0" \
            "status"; do
  t "backend-exits-0-on-$call"
  marker   # mark-good --require-marker needs the session marker present
  # shellcheck disable=SC2086
  bc $call
  [ "$RC" = 0 ] && ok "'$call' exits 0" || bad "'$call' exits $RC (output: $OUT)"
  done_
done

t "backend-is-complete"
# Enumerates the subcommands system.conf's bootloader=custom backend contract requires, plus the
# health tool. A command this tool does not dispatch must fail here, not on hardware at 40% of an
# install. `self` is the argument the health unit's ExecOnFailure uses to demote the booted slot.
for sub in get-current get-primary set-primary get-state set-state mark-good status; do
  grep -qE "^  $sub\)" "$BOOTCTL" && ok "dispatches '$sub'" || bad "no dispatch case for '$sub'"
done
grep -qE "self\)" "$BOOTCTL" && ok "accepts 'self' as an image" || bad "no 'self' resolution"
done_

t "unknown-subcommand-still-fails"
# The complement of the above: a real typo must NOT be silently absorbed by a lenient dispatcher.
bc set-stat B bad
expect_rc 1
done_

echo "== RAUC backend: values =="

t "get-current-reads-bootconf-not-the-cmdline"
# RAUC's own fallback parses root= from /proc/cmdline, which our static cmdline makes permanently
# wrong. The answer must come from steamos-bootconf this-image, i.e. the partset the initramfs wrote.
set_self B
bc get-current
expect_rc 0; expect_out B
done_

t "get-current-fails-on-a-dev-boot"
# dev is a valid bootconf image but not a RAUC slot (system.conf has only rootfs.0/rootfs.1).
# Guessing would hand RAUC a slot nothing verified, so this is the contract's "cannot be determined".
set_self dev
bc get-current
expect_rc 1
expect_has "no RAUC slot"
done_

t "get-current-falls-back-to-a-known-image"
# Guard Valve ships for an unidentifiable this-image: pick a well-known image from list-images.
set_self Q
bc get-current
expect_rc 0; expect_out B
done_

t "get-primary-is-the-armed-image"
set_sel B
bc get-primary
expect_rc 0; expect_out B
done_

t "get-primary-falls-back-to-current-when-selected-is-dev"
# selected-image answering dev means nothing is armed for the next boot.
set_sel dev
bc get-primary
expect_rc 0; expect_out A
done_

t "set-primary-arms-the-other-slot"
bc set-primary B
expect_rc 0
expect_sel B
[ -n "$(conf_field B boot-requested-at)" ] && ok "B armed (boot-requested-at stamped)" \
  || bad "B was not armed"
expect_conf B boot-other 0
done_

t "set-primary-self-resolves-to-the-current-image"
bc set-primary self
expect_rc 0
expect_sel A
done_

t "set-primary-creates-a-missing-config"
# ensure_exists: a slot that was never installed has no conf yet, and arming it must create one.
rm -f "$SB/conf/B.conf"
bc set-primary B
expect_rc 0
expect_conf B boot-other 0
done_

t "set-primary-rejects-an-unknown-image"
bc set-primary C
expect_rc 1
done_

echo "== get-state =="

t "get-state-good-on-a-clean-image"
bc get-state A
expect_rc 0; expect_out good
done_

t "get-state-bad-on-boot-attempts"
put_conf A boot-attempts 2
bc get-state A
expect_rc 0; expect_out bad
done_

t "get-state-bad-on-image-invalid"
put_conf A image-invalid 1
bc get-state A
expect_rc 0; expect_out bad
done_

t "get-state-absent-keys-answer-good"
# A slot that was installed but never booted has no boot-attempts on the ESP (stage 2 only writes
# it at boot time); the bootconf schema defaults it to 0, so the answer is good, not a failure.
printf 'title: A\n' >"$SB/conf/A.conf"
bc get-state A
expect_rc 0; expect_out good
done_

t "get-state-missing-config-dies"
rm -f "$SB/conf/A.conf"
bc get-state A
expect_rc 1
expect_has "missing boot configuration"
done_

t "get-state-self-resolves-to-the-booted-image"
set_self B; put_conf B boot-attempts 1
bc get-state self
expect_rc 0; expect_out bad
done_

echo "== set-state =="

t "set-state-good-clears-invalid"
put_conf A image-invalid 1
bc set-state A good
expect_rc 0
expect_conf A image-invalid 0
bc get-state A
expect_out good
done_

t "set-state-bad-flags-invalid-and-arms-reboot-other"
bc set-state B bad
expect_rc 0
expect_conf B image-invalid 1
expect_conf B boot-other 1
expect_sel B
done_

t "set-state-self-bad-demotes-the-running-image"
# What novadeck-boot-good.service's ExecOnFailure runs when the confirmation fails.
bc set-state self bad
expect_rc 0
expect_conf A image-invalid 1
expect_sel A
done_

t "set-state-self-bad-on-a-dev-boot-exits-0"
# The health unit can fire on a cmdline-fallback boot too (ConditionPathExists=/run/novadeck/boot
# is true there); the demote must be harmless, not an error.
set_self dev
bc set-state self bad
expect_rc 0
expect_conf dev image-invalid 1
done_

t "set-state-rejects-a-bad-value"
bc set-state B maybe
expect_rc 1
done_

t "set-state-rejects-a-bad-image"
bc set-state C good
expect_rc 1
done_

echo "== mark-good (boot health) =="

t "mark-good-confirms-the-booted-slot"
# set-mode booted clears boot-attempts (so the stage-2 counter and stock steamcl's failsafe stop
# counting this boot), bumps boot-count, and clears image-invalid (which booted does NOT touch on
# its own -- see the note in the tool).
put_conf A boot-attempts 3
put_conf A image-invalid 1
put_conf A boot-count 5
marker
bc mark-good
expect_rc 0
expect_has "boot confirmed good"
expect_conf A boot-attempts 0
expect_conf A image-invalid 0
expect_conf A boot-count 6
expect_sel A
done_

t "mark-good-re-promotes-a-recovered-slot"
# A slot that was demoted (image-invalid 1) but then boots and passes health must be re-promoted,
# or it would confirm yet stay marked for the failsafe.
put_conf A image-invalid 1
marker
bc mark-good
expect_rc 0
expect_conf A image-invalid 0
done_

t "mark-good-requires-the-session-marker"
# --require-marker is what the service passes: confirming without the marker being present proves
# nothing about the session, and the 30s re-check exists precisely to catch a session that died.
bc mark-good --require-marker
expect_rc 1
expect_has "no session marker"
done_

t "mark-good-is-a-no-op-that-exits-0-on-a-degraded-boot"
# Load-bearing: novadeck-boot-good.service is RemainAfterExit=yes, so a non-zero exit re-arms the
# level-triggered .path into a failing mark-good every 30s for the rest of the device's uptime.
# The handoff names no slot on a cmdline-fallback boot, so that is the guard: nothing to confirm.
seed_boot '' cmdline
bc mark-good
expect_rc 0
expect_has "nothing to confirm"
done_

t "mark-good-require-marker-is-also-a-no-op-on-a-degraded-boot"
seed_boot '' cmdline
bc mark-good --require-marker
expect_rc 0
done_

t "mark-good-fails-when-the-booted-image-has-no-conf"
# Not reachable on a device (the booted slot always has a conf on the ESP), but the failure must be
# loud rather than silently marking nothing.
rm -f "$SB/conf/A.conf"
marker
bc mark-good
expect_rc 1
expect_has "failed"
done_

echo "== mark-good --wait: a shutdown mid-re-check is not a verdict =="
#
# HW 2026-08-10, Pocket S2: the re-check delay used to be ExecStartPre=/usr/bin/sleep 30 in
# novadeck-boot-good.service. Powering the device off inside that window -- i.e. every OOBE test --
# SIGTERMed the sleep, so systemd scored the unit `Failed with result 'signal'` and fired
# OnFailure=novadeck-boot-bad.service. The demote lost the race to the shutdown transaction that
# time; nothing guaranteed it would. These cases pin the replacement: the wait lives in the tool
# and a signal during it means NO VERDICT -- exit 0, nothing confirmed, nothing demoted.

# Runs the shipped tool in the background and SIGTERMs the shell after <delay>s. Only the shell is
# signalled, not its `sleep` child, which is the STRICTER case: with no trap, bash dies on the
# default disposition and the call exits 143, so a regression cannot pass by accident.
bc_term_after() {  # <delay-seconds> <args...>
  local delay=$1; shift
  BOOTINFO="$SB/run/boot" SESSION_MARKER="$SB/marker" \
    BC="$SB/bin/steamos-bootconf" BC_ARGS="--conf-dir $SB/conf --efi-dir $SB/efi" \
    bash "$BOOTCTL" "$@" >"$SB/bg.out" 2>&1 &
  local pid=$!
  sleep "$delay"
  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid"; RC=$?
  OUT=$(cat "$SB/bg.out")
  return 0
}

t "wait-completes-and-confirms-when-nothing-interrupts-it"
put_conf A boot-attempts 2
marker
bc mark-good --require-marker --wait 1
expect_rc 0
expect_has "boot confirmed good"
expect_conf A boot-attempts 0
done_

t "sigterm-during-the-wait-exits-0-and-reaches-no-verdict"
# The three things that must all hold: not a failure (no red unit, no OnFailure), not a
# confirmation (the session never served its 30s), and not a demote.
put_conf A boot-attempts 1
put_conf A image-invalid 0
marker
bc_term_after 1 mark-good --require-marker --wait 20
expect_rc 0
expect_has "interrupted"
expect_conf A boot-attempts 1
expect_conf A image-invalid 0
done_

t "sigterm-after-the-wait-does-not-reach-back-and-undo-the-confirmation"
# The trap is armed only around the wait; once it has been disarmed the confirmation is a normal
# write and a late signal must not turn a good boot into no-verdict.
put_conf A boot-attempts 3
marker
bc_term_after 3 mark-good --require-marker --wait 1
expect_conf A boot-attempts 0
done_

t "wait-rejects-a-non-numeric-argument"
# --wait feeds `sleep` and an arithmetic test; a typo must be loud rather than silently 0.
marker
bc mark-good --wait 30s
expect_rc 1
expect_has "whole number"
done_

t "mark-good-rejects-an-unknown-option"
marker
bc mark-good --requre-marker
expect_rc 1
expect_has "unknown option"
done_

t "the-shipped-unit-passes--wait-and-carries-no-sleep-of-its-own"
# The tool growing --wait is worthless if the unit still sleeps in an ExecStartPre, so assert the
# artifact that ships, not just the tool. This is the drift that would silently restore the bug.
UNIT="$ROOT/fs-overlay/usr/lib/systemd/system/novadeck-boot-good.service"
grep -qE '^ExecStart=.*mark-good .*--wait 30' "$UNIT" \
  && ok "boot-good ExecStart passes --wait 30" || bad "boot-good does not pass --wait 30"
grep -qE '^ExecStartPre=.*sleep' "$UNIT" \
  && bad "boot-good still sleeps in ExecStartPre -- the signal lands on the sleep again" \
  || ok "boot-good has no ExecStartPre sleep"
BADUNIT="$ROOT/fs-overlay/usr/lib/systemd/system/novadeck-boot-bad.service"
grep -qE '^ExecCondition=' "$BADUNIT" \
  && ok "boot-bad is gated by an ExecCondition" || bad "boot-bad has no shutdown guard"
grep -qE '^ExecCondition=.*is-system-running' "$BADUNIT" \
  && ok "boot-bad's guard tests is-system-running" || bad "boot-bad's guard does not test is-system-running"
done_

echo "== the install sequence, as RAUC and the hook actually drive it =="

# RAUC's custom-backend ordering (from a real journal): it marks the target bad before writing,
# then arms it via set-primary. The Phase 5 post-install hook then disarms BOTH images directly
# through steamos-bootconf (not this tool) while it works, and only this tool's last two calls are
# visible here: clearing the pre-write marking and re-arming. The window between RAUC's arming and
# the hook's step-0 disarm is closed by the hook itself -- see test-post-install.sh.
t "a-completed-install-ends-armed-and-unmarked"
bc set-state B bad  ; expect_rc 0     # 1. RAUC, pre-write
bc set-primary B    ; expect_rc 0     # 2. RAUC, post-write: target armed but NOT bootable yet
bc set-state B good ; expect_rc 0     # 3. hook, step 4: clear the pre-write marking
bc set-primary B    ; expect_rc 0     # 4. hook, step 4: re-arm
expect_conf B image-invalid 0
expect_conf B boot-other 0
expect_sel B
bc get-state B; expect_out good
done_

t "an-install-that-dies-before-the-hook-leaves-the-marking"
# RAUC aborted between its two calls -- nothing runs afterwards to tidy up, so the marking has to
# be enough on its own: the interrupted slot answers bad rather than pretending it was never touched.
bc set-state B bad
bc set-primary B
bc get-state B; expect_out bad
bc get-primary; expect_out B           # ...but RAUC did arm it, which the hook's step-0 disarms
done_

echo "== status =="

t "status-reports-the-images"
bc status
expect_rc 0
expect_has "booted image: A"
expect_has "image A:"
expect_has "image B:"
done_

t "status-without-a-conf-does-not-die"
rm -f "$SB/conf/A.conf" "$SB/conf/B.conf"
bc status
expect_rc 0
expect_has "no config on the ESP"
done_

t "status-tolerates-an-unidentifiable-boot"
rm -f "$SB/conf/__self"
bc status
expect_rc 0
expect_has "booted image: <unidentifiable>"
done_

# --- summary ------------------------------------------------------------------------------------

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ] || exit 1
