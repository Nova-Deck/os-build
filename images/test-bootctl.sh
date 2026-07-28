#!/usr/bin/env bash
# Offline test for /usr/bin/novadeck-bootctl — above all, for its RAUC backend contract.
#
#   images/test-bootctl.sh
#
# WHY THIS FILE EXISTS. images/initramfs/test-slot-state.sh covers the initramfs READER and never
# executes novadeck-bootctl at all, so the WRITER's side of the same format had no offline coverage
# — and that is how a broken backend shipped. `set-state <slot> bad` returned exit 1 for a slot that
# was neither active nor pending, which is precisely the normal pre-write case (RAUC marks the
# target slot bad before writing it), so the first hardware `rauc install` aborted at 40% with
# "Failed marking slot rootfs.1 as bad" — a message describing our exit code, not our state. It
# needed no hardware and no bundle to catch: a dozen lines against a temp-dir ESP would have done it.
#
# THE CONTRACT IS THE EXIT STATUS, so that is what this asserts first and everywhere. RAUC treats a
# non-zero backend exit as a failed install, and the bug was a shell idiom rather than logic — a
# trailing `[ x = y ] && action` returns 1 when the test is false. Side-effect-only assertions
# cannot see that. Every legal call is therefore asserted to exit 0 INCLUDING the no-ops.
#
# IT ALSO ENUMERATES THE CONTRACT. `get-current` was a subcommand we had never implemented, and
# nothing noticed until hardware: RAUC fell back to parsing root= from /proc/cmdline, which is
# always wrong for us, so it believed slot a had booted on every boot. A test that lists the
# commands RAUC calls flags a MISSING one as loudly as a broken one — see `backend-is-complete`.
#
# HOW IT WORKS: the real, shipped novadeck-bootctl is executed — not a copy, not a sed-mangled
# variant. It exposes three environment seams (BOOTINFO, ESP_AUTO, ESP_MANUAL) that exist for this
# and are documented as such at the top of the tool; everything else is stubbed on PATH (`id` so
# need_root passes as an ordinary user, `mountpoint` so the sandbox ESP looks automounted). What
# runs here is the artifact that ships.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BOOTCTL="$ROOT/fs-overlay/usr/bin/novadeck-bootctl"
[ -f "$BOOTCTL" ] || { echo "no novadeck-bootctl: $BOOTCTL" >&2; exit 1; }

PASS=0; FAIL=0; CASE=""; SB=""
OUT=""; RC=0

ok()  { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }

# --- sandbox ------------------------------------------------------------------------------------

sandbox() {
  SB="$(mktemp -d)"
  mkdir -p "$SB/esp/NOVADECK" "$SB/bin" "$SB/run"
  # need_root calls `id -u`; the tool legitimately requires root on a device and we are not it.
  printf '#!/bin/sh\n[ "$1" = -u ] && { echo 0; exit 0; }\nexec /usr/bin/id "$@"\n' >"$SB/bin/id"
  # esp_open prefers the gpt-auto automount and only falls back to findfs+mount. Pointing ESP_AUTO
  # at the sandbox and making it look like a mountpoint keeps the test on the SAME code path the
  # device uses, rather than exercising the fallback nothing normally reaches.
  printf '#!/bin/sh\nexit 0\n' >"$SB/bin/mountpoint"
  chmod +x "$SB/bin"/*
}
done_() { rm -rf "$SB"; }
t() { CASE="$1"; sandbox; }

# Run the SHIPPED tool against the sandbox. Captures stdout+stderr and the exit status.
bc() {
  OUT=$(PATH="$SB/bin:$PATH" \
        BOOTINFO="$SB/run/boot" ESP_AUTO="$SB/esp" ESP_MANUAL="$SB/esp" \
        bash "$BOOTCTL" "$@" 2>&1)
  RC=$?
  return 0
}

seed_state() {  # <index> <gen> <active> <pending> <tries> [kernel] [bak] [broken]
  cat >"$SB/esp/NOVADECK/STATE.$1" <<EOF
# novadeck A/B slot state
gen=$2
active=$3
pending=$4
tries=$5
kernel=${6:-}
bak=${7:-}
broken=${8:-}
end
EOF
}

seed_boot() {  # <slot> [source]
  mkdir -p "$SB/run"
  printf 'slot=%s\nsource=%s\ngen=1\nactive=%s\npending=\ntries_left=0\n' \
    "$1" "${2:-state}" "$1" >"$SB/run/boot"
}

# --- assertions ---------------------------------------------------------------------------------

expect_rc()  { [ "$RC" = "$1" ] && ok "exit=$1" || bad "exit: expected $1, got $RC (output: $OUT)"; }
expect_out() { [ "$OUT" = "$1" ] && ok "printed '$1'" || bad "expected '$1', got '$OUT'"; }
expect_has() { case "$OUT" in *"$1"*) ok "mentions '$1'" ;; *) bad "expected '$1' in output, got '$OUT'" ;; esac; }

# Winning state, pipe-delimited: pending and broken are EMPTY on most cases and a whitespace read
# would shift every field left of them.
winning() {
  local best=-1 bf="" f g
  for f in "$SB"/esp/NOVADECK/STATE.*; do
    [ -f "$f" ] || continue
    grep -qx end "$f" || continue
    g=$(sed -n 's/^gen=//p' "$f")
    [ "${g:-0}" -gt "$best" ] && { best=$g; bf=$f; }
  done
  [ -n "$bf" ] || return 1
  printf '%s|%s|%s|%s|%s' "$best" \
    "$(sed -n 's/^active=//p'  "$bf")" "$(sed -n 's/^pending=//p' "$bf")" \
    "$(sed -n 's/^tries=//p'   "$bf")" "$(sed -n 's/^broken=//p'  "$bf")"
}

expect_state() {  # <gen> <active> <pending> <tries> [broken]
  local w; w=$(winning) || { bad "no valid state file on the ESP"; return; }
  local g a p tr br; IFS="|" read -r g a p tr br <<<"$w"
  [ "$g" = "$1" ] && [ "$a" = "$2" ] && [ "$p" = "$3" ] && [ "$tr" = "$4" ] && [ "$br" = "${5:-}" ] \
    && ok "state gen=$1 active=$2 pending='$3' tries=$4 broken='${5:-}'" \
    || bad "state: expected gen=$1 active=$2 pending='$3' tries=$4 broken='${5:-}', got gen=$g active=$a pending='$p' tries=$tr broken='$br'"
}

# The write must land on the file that did NOT win, or a torn write destroys the live state.
expect_written_to() {
  [ -f "$SB/esp/NOVADECK/STATE.$1" ] && ok "wrote STATE.$1" || bad "STATE.$1 was not written"
}

expect_field() {  # <key> <value> in the winning file
  local best=-1 bf="" f g got
  for f in "$SB"/esp/NOVADECK/STATE.*; do
    [ -f "$f" ] || continue; grep -qx end "$f" || continue
    g=$(sed -n 's/^gen=//p' "$f"); [ "${g:-0}" -gt "$best" ] && { best=$g; bf=$f; }
  done
  got=$(sed -n "s/^$1=//p" "$bf")
  [ "$got" = "$2" ] && ok "$1='$2'" || bad "$1: expected '$2', got '$got'"
}

echo "== RAUC backend: the contract is the EXIT STATUS =="

# The regression that cost the first hardware install, as its own case. RAUC marks the slot it is
# about to overwrite as bad; that slot is by definition neither active nor pending.
t "set-state-bad-on-idle-slot-exits-0"
seed_state 0 1 a '' 0; seed_boot a
bc set-state b bad
expect_rc 0
done_

t "set-state-bad-on-idle-slot-records-broken"
seed_state 0 1 a '' 0; seed_boot a
bc set-state b bad
expect_state 2 a '' 0 b
expect_written_to 1
done_

# Every legal call, no-ops included. A table rather than prose so a MISSING subcommand is as
# visible as a broken one: this list is the contract RAUC consumes.
t "backend-exits-0-on-every-legal-call"
seed_state 0 1 a '' 0; seed_boot a
for call in "get-current" "get-primary" "get-state a" "get-state b" \
            "set-primary a" "set-primary b" \
            "set-state a good" "set-state b good" "set-state a bad" "set-state b bad"; do
  # Each call gets a pristine state: several of them write, and the point here is the status of the
  # call in isolation, not of a sequence.
  rm -f "$SB"/esp/NOVADECK/STATE.*
  seed_state 0 1 a '' 0
  # shellcheck disable=SC2086
  bc $call
  [ "$RC" = 0 ] && ok "'$call' exits 0" || bad "'$call' exits $RC (output: $OUT)"
done
done_

t "backend-is-complete"
# Enumerates the subcommands system.conf's bootloader=custom backend contract requires. A command
# this tool does not dispatch must fail here, not on hardware at 40% of an install.
seed_state 0 1 a '' 0; seed_boot a
for sub in get-current get-primary set-primary get-state set-state; do
  if grep -qE "^  $sub\)" "$BOOTCTL"; then ok "dispatches '$sub'"; else bad "no dispatch case for '$sub' -- RAUC will call it"; fi
done
done_

t "unknown-subcommand-still-fails"
# The complement of the above: a real typo must NOT be silently absorbed by a lenient dispatcher.
seed_state 0 1 a '' 0; seed_boot a
bc set-stat b bad
expect_rc 1
done_

echo "== RAUC backend: values =="

t "get-current-reads-the-handoff-not-the-cmdline"
# RAUC's own fallback parses root= from /proc/cmdline, which our static cmdline makes permanently
# wrong. The answer must come from what the initramfs actually resolved.
seed_state 0 3 a b 1; seed_boot b try
bc get-current
expect_rc 0; expect_out b
done_

t "get-current-fails-on-a-degraded-boot"
# A cmdline-fallback boot still writes the handoff, with an EMPTY slot=. Non-zero is the contract's
# signal for "cannot be determined"; guessing would hand RAUC a slot nothing verified.
seed_state 0 1 a '' 0
printf 'slot=\nsource=cmdline\n' >"$SB/run/boot"
bc get-current
expect_rc 1
done_

t "get-primary-is-pending-while-a-trial-is-armed"
seed_state 0 5 a b 1; seed_boot a
bc get-primary
expect_rc 0; expect_out b
done_

t "get-primary-ignores-a-trial-with-no-tries-left"
seed_state 0 5 a b 0; seed_boot a
bc get-primary
expect_rc 0; expect_out a
done_

t "set-primary-other-slot-arms-a-trial"
seed_state 0 1 a '' 0; seed_boot a
bc set-primary b
expect_rc 0; expect_state 2 a b 1
done_

t "set-primary-active-slot-clears-a-trial"
seed_state 0 2 a b 1; seed_boot a
bc set-primary a
expect_rc 0; expect_state 3 a '' 0
done_

echo "== broken=: a marking that is recorded, not dropped =="

# The gap this field closes, demonstrated on hardware 2026-07-28 with a tampered bundle: dm-verity
# aborted the copy 13s in, slot a was genuinely inconsistent, and get-state still said good.
t "half-written-slot-answers-bad"
seed_state 0 1 a '' 0; seed_boot a
bc set-state b bad          # RAUC's pre-write marking
expect_rc 0
bc get-state b              # ...the install then dies. Nothing clears it.
expect_rc 0; expect_out bad
done_

t "an-untouched-slot-answers-good"
seed_state 0 1 a '' 0; seed_boot a
bc get-state b
expect_rc 0; expect_out good
done_

t "set-state-good-clears-broken-even-when-not-pending"
# What the post-install hook relies on. It disarms while it works, so the completed slot is neither
# active nor pending when the mark has to come off. A pending-only `good` would clear nothing and
# the slot would stay marked broken for life.
seed_state 0 1 a '' 0 '' '' b; seed_boot a
bc set-state b good
expect_rc 0; expect_state 2 a '' 0 ''
bc get-state b
expect_out good
done_

t "both-slots-can-be-broken-at-once"
# A set, not a letter. Both slots at once is reachable even though the ACTIVE slot can never be
# marked (that is refused): an install into b dies leaving broken=b with active=a, `try b` then
# boots it anyway and mark-good promotes it, so the state below is active=b with b still marked.
# An install now targets a, and if `broken` were a single letter that write would erase b's mark —
# leaving a slot nothing has repaired answering good.
seed_state 0 1 b '' 0 '' '' b; seed_boot b
bc set-state a bad
expect_rc 0
expect_field broken ab
bc get-state a; expect_out bad
bc get-state b; expect_out bad
done_

t "clearing-one-slot-keeps-the-other-marked"
seed_state 0 1 a '' 0 '' '' ab; seed_boot a
bc set-state b good
expect_field broken a
done_

t "marking-the-active-slot-bad-is-refused-but-exits-0"
# RAUC never asks this, and honouring it would leave nothing to boot. It must not be recorded
# either: a slot we are RUNNING is demonstrably bootable.
seed_state 0 1 a '' 0; seed_boot a
bc set-state a bad
expect_rc 0
expect_field broken ''
bc get-state a; expect_out good
done_

t "a-failed-trial-is-recorded-as-well-as-zeroed"
# tries=0 stops describing this slot the moment a later write moves `pending` elsewhere.
seed_state 0 2 a b 1; seed_boot a
bc set-state b bad
expect_rc 0; expect_state 3 a b 0 b
done_

t "malformed-broken-is-normalised-not-fatal"
# A bookkeeping field must never invalidate the state the device boots from.
seed_state 0 1 a '' 0 '' '' 'ZQ'
seed_boot a
bc get-primary
expect_rc 0; expect_out a
done_

t "broken-is-canonically-ordered"
# One representation per set, whatever order it arrived in — otherwise 'ab' and 'ba' are two
# different strings for one fact and any future equality check on the field is a coin toss.
seed_state 0 1 a '' 0 '' '' 'ba'
seed_boot a
bc set-state b bad          # already marked; must not duplicate, and must come back canonical
expect_rc 0
expect_field broken ab
done_

echo "== the install sequence, as RAUC and the hook actually drive it =="

# The order below is RAUC's, taken from the journal of a real install (2026-07-28): it marks the
# target bad, writes it, marks it active, and ONLY THEN starts the post-install handler. Steps 4-8
# are fs-overlay/usr/lib/rauc/post-install.sh. This case exists because the window between 3 and 8
# is the one the disarm was added to close, and nothing else in this file exercises the two
# programs as a sequence.
t "a-completed-install-ends-armed-and-unmarked"
seed_state 0 1 a '' 0; seed_boot a
bc set-state b bad   ; expect_rc 0     # 1. RAUC, pre-write
bc set-primary b     ; expect_rc 0     # 3. RAUC, post-write: the slot is now armed but NOT bootable
bc rollback          ; expect_rc 0     # 4. hook, step 0: take that back
bc set-kernel b ''   ; expect_rc 0     # 6. hook, step 3: NOW it is bootable
bc set-state b good  ; expect_rc 0     # 7. hook, step 4: clear the pre-write marking
bc set-primary b     ; expect_rc 0     # 8. hook, step 4: re-arm
expect_field pending b
expect_field tries 1
expect_field broken ''
expect_field kernel b
bc get-state b; expect_out good
done_

t "a-power-cut-inside-the-hook-leaves-nothing-armed"
# The whole point of the disarm. Between the hook's step 0 and its last line the target's /var is
# freshly mkfs'd and /KERNEL still holds the other slot's image, so a state pointing at it would
# boot a root with no /var/lib/overlays/etc/upper under a kernel whose modules belong elsewhere.
# After the disarm the ESP must name the RUNNING slot and nothing else, at every instant.
seed_state 0 1 a '' 0; seed_boot a
bc set-state b bad
bc set-primary b
bc rollback                            # ...and the power goes here
bc get-primary
expect_rc 0; expect_out a
expect_field pending ''
expect_field tries 0
# The interrupted install is still on the record, which is the other half of the design: the next
# boot comes up on a, and b answers `bad` rather than pretending it was never touched.
bc get-state b; expect_out bad
done_

t "an-install-that-dies-before-the-hook-leaves-the-slot-marked"
# RAUC aborts between steps 1 and 3 -- what the tampered-bundle test did on hardware, where verity
# failed 13s into the copy. Nothing runs afterwards to tidy up, so the marking has to be enough on
# its own.
seed_state 0 1 a '' 0; seed_boot a
bc set-state b bad
bc get-state b; expect_out bad
bc get-primary; expect_out a           # and nothing is armed at b
done_

echo "== the format is preserved across writes =="

t "unknown-keys-survive-a-write"
# The tool is PER-SLOT while the initramfs that reads it is SHARED, so an older writer and a newer
# reader coexist by design. Dropping a field we do not recognise breaks that contract.
cat >"$SB/esp/NOVADECK/STATE.0" <<'EOF'
gen=1
active=a
pending=
tries=0
kernel=
bak=
broken=
future-key=hello
end
EOF
seed_boot a
bc set-primary b
expect_rc 0
grep -qx 'future-key=hello' "$SB/esp/NOVADECK/STATE.1" \
  && ok "future-key= preserved verbatim" || bad "future-key= was dropped on write"
done_

t "kernel-and-bak-round-trip"
seed_state 0 1 a '' 0 b KERNEL.BAK
seed_boot a
bc set-primary b
expect_field kernel b; expect_field bak KERNEL.BAK
done_

t "broken-round-trips-through-an-unrelated-write"
seed_state 0 1 a '' 0 '' '' a
seed_boot b
bc set-primary a
expect_field broken a
done_

t "every-write-emits-broken"
# The initramfs writer emits a FIXED field list, so a state written without broken= loses any
# marking on the next trial-boot decrement. Both writers must name it.
seed_state 0 1 a '' 0
seed_boot a
bc set-primary b
grep -q '^broken=' "$SB/esp/NOVADECK/STATE.1" \
  && ok "broken= present in a fresh write" || bad "broken= missing -- the initramfs would drop it"
done_

echo "== interactive subcommands =="

t "try-warns-about-a-broken-slot-but-still-arms-it"
# Warned, not refused: `try` is the recovery tool, and the trial counter bounds the risk. Refusing
# would let the one recorded fact about a half-installed slot disable the only way back.
seed_state 0 1 a '' 0 '' '' b; seed_boot a
bc try b
expect_rc 0
expect_has "marked BROKEN"
expect_state 2 a b 1 b
done_

t "status-reports-a-broken-slot"
seed_state 0 1 a '' 0 '' '' b; seed_boot a
bc status
expect_rc 0
expect_has "slot b is BROKEN"
done_

t "status-without-a-handoff-does-not-die"
# `status` is the first thing anyone runs on a device that is misbehaving, including one that never
# booted through our initramfs at all.
seed_state 0 1 a '' 0
bc status
expect_rc 0
expect_has "did not boot through the novadeck initramfs"
done_

t "try-refuses-the-already-active-slot"
seed_state 0 1 a '' 0; seed_boot a
bc try a
expect_rc 1
done_

t "mark-good-confirms-the-pending-slot"
seed_state 0 2 a b 1; seed_boot b try
bc mark-good
expect_rc 0; expect_state 3 b '' 0
done_

t "mark-good-is-a-no-op-that-exits-0-on-a-degraded-boot"
# Load-bearing: novadeck-boot-good.service is RemainAfterExit=yes, and a non-zero exit re-arms the
# level-triggered .path into a mark-good every 30s for the rest of the device's uptime.
seed_state 0 1 a '' 0
printf 'slot=\nsource=cmdline\n' >"$SB/run/boot"
bc mark-good
expect_rc 0
done_

t "rollback-abandons-a-trial"
seed_state 0 2 a b 1; seed_boot a
bc rollback
expect_rc 0; expect_state 3 a '' 0
done_

t "rollback-is-a-no-op-that-exits-0-with-nothing-armed"
# The RAUC post-install hook disarms with this on entry, on a state that may have nothing pending.
seed_state 0 1 a '' 0; seed_boot a
bc rollback
expect_rc 0
done_

t "set-kernel-records-both-fields-in-one-generation"
seed_state 0 1 a '' 0; seed_boot a
: >"$SB/esp/KERNEL.BAK"
bc set-kernel b KERNEL.BAK
expect_rc 0
expect_field kernel b; expect_field bak KERNEL.BAK
expect_state 2 a '' 0
done_

t "set-kernel-refuses-a-path-as-a-backup-name"
seed_state 0 1 a '' 0; seed_boot a
bc set-kernel b ../../etc/passwd
expect_rc 1
done_

echo "== rejection =="

t "torn-state-is-rejected-and-the-older-generation-wins"
seed_state 0 1 a '' 0
printf 'gen=9\nactive=b\npending=\ntries=0\n' >"$SB/esp/NOVADECK/STATE.1"   # no `end`
seed_boot a
bc get-primary
expect_rc 0; expect_out a
done_

t "no-state-at-all-is-a-clean-failure"
seed_boot a
bc get-primary
expect_rc 1
expect_has "no valid slot state"
done_

t "get-state-rejects-a-bad-slot-name"
seed_state 0 1 a '' 0; seed_boot a
bc get-state c
expect_rc 1
done_

t "set-state-rejects-a-bad-value"
seed_state 0 1 a '' 0; seed_boot a
bc set-state b maybe
expect_rc 1
done_

# --- summary ------------------------------------------------------------------------------------

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ] || exit 1
