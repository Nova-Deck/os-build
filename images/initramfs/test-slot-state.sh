#!/usr/bin/env bash
# Offline test for the A/B slot decision in images/initramfs/init.
#
# The init script is the one component in this tree that can leave a device unbootable, and the
# device has no serial console -- so every HW test costs a reflash-and-reboot cycle. The decision
# table (which slot, when to decrement, when to roll back, when to fail over) is pure logic over
# a text file, so it can be exercised here for free and the hardware time spent on the things
# only hardware can show.
#
#   images/initramfs/test-slot-state.sh
#
# HOW IT WORKS: the real init is copied and a handful of absolute paths are redirected into a
# sandbox (/esp, /sysroot, /proc/cmdline, /dev/kmsg, /run/novadeck), then run with stubbed
# mount/umount/findfs/sleep/switch_root on PATH. Every substitution is asserted to have applied,
# so this fails loudly if the init is restructured rather than silently testing a stale copy.
# Nothing in the shipped init is conditional on being under test.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INIT="$ROOT/images/initramfs/init"
[ -f "$INIT" ] || { echo "no init script: $INIT" >&2; exit 1; }

PASS=0; FAIL=0
SB=""

# --- sandbox ---------------------------------------------------------------------------------

sandbox() {
  SB="$(mktemp -d)"
  mkdir -p "$SB/esp/NOVADECK" "$SB/sysroot/var" "$SB/run" "$SB/bin"
  : >"$SB/kmsg"
  printf 'quiet root=PARTLABEL=novadeck-root-A rootfstype=btrfs ro novadeck.var=PARTLABEL=novadeck-var-A panic=5\n' >"$SB/cmdline"
  : >"$SB/mounts"        # what mount was asked to do
  : >"$SB/missing"       # PARTLABELs findfs must not resolve
  : >"$SB/unmountable"   # devices mount must refuse

  cat >"$SB/bin/findfs" <<EOF
#!/bin/sh
spec=\$1; label=\${spec#PARTLABEL=}
grep -qx "\$label" "$SB/missing" 2>/dev/null && exit 1
dev="$SB/dev-\$label"; : >"\$dev"
printf '%s' "\$dev"
EOF

  # -b tests in the init check for a BLOCK device, which a sandbox file is not; the stub prints a
  # path the init then feeds back to `mount`, so the block test is what we neutralise here by
  # having findfs emit a path under $SB and the init's [ -b ] ... see below.
  cat >"$SB/bin/mount" <<EOF
#!/bin/sh
echo "mount \$*" >>"$SB/mounts"
for a in "\$@"; do
  case "\$a" in
    $SB/dev-*)
      base=\$(basename "\$a")
      grep -qx "\${base#dev-}" "$SB/unmountable" 2>/dev/null && exit 32
      ;;
  esac
done
case " \$* " in
  *" $SB/esp "*) grep -qx "ESP_RO" "$SB/unmountable" 2>/dev/null && case " \$* " in *" rw "*|*"-o rw"*) exit 32;; esac ;;
esac
exit 0
EOF

  cat >"$SB/bin/umount" <<EOF
#!/bin/sh
echo "umount \$*" >>"$SB/mounts"
exit 0
EOF

  cat >"$SB/bin/switch_root" <<EOF
#!/bin/sh
echo "switch_root \$*" >>"$SB/mounts"
exit 0
EOF

  # The init uses cp for exactly one thing: restoring KERNEL.BAK over KERNEL on a rollback. The
  # marker lets a case make that copy fail -- the branch where the state has ALREADY been written
  # claiming the restore, and has to be corrected before the boot continues.
  cat >"$SB/bin/cp" <<EOF
#!/bin/sh
[ -f "$SB/cp-fails" ] && exit 1
exec /usr/bin/cp "\$@"
EOF

  printf '#!/bin/sh\nexit 0\n' >"$SB/bin/sleep"
  chmod +x "$SB/bin"/*
}

# Copy the init, redirecting the absolute paths into the sandbox. Each rewrite is asserted.
build_init() {
  local src dst n
  src="$INIT"; dst="$SB/init"
  cp "$src" "$dst"
  # pattern -> replacement, applied with a count check so a restructured init fails the test
  # rather than quietly being tested at its real paths.
  rewrite() {
    local pat=$1 rep=$2 want=$3 got
    got=$(grep -cF "$pat" "$dst")
    [ "$got" = "$want" ] || {
      echo "FATAL: expected $want occurrence(s) of '$pat' in init, found $got" >&2
      echo "  the init was restructured -- update images/initramfs/test-slot-state.sh" >&2
      exit 2
    }
    # shellcheck disable=SC2001
    sed -i "s|$(printf '%s' "$pat" | sed 's/[.[\*^$/]/\\&/g')|$rep|g" "$dst"
  }
  rewrite 'SYSROOT=/sysroot'          "SYSROOT=$SB/sysroot"           1
  rewrite 'ESPDIR=/esp'               "ESPDIR=$SB/esp"                1
  rewrite '>/dev/kmsg'                ">>$SB/kmsg"                    2
  rewrite '</proc/cmdline'            "<$SB/cmdline"                  1
  rewrite 'mkdir -p /run/novadeck'    "mkdir -p $SB/run/novadeck"     1
  rewrite '>/run/novadeck/boot'       ">$SB/run/novadeck/boot"        1
  # The [ -b ] block-device tests can never pass on sandbox files.
  rewrite '[ -b "$_spec" ]'           '[ -e "$_spec" ]'               1
  rewrite '[ -b "$_d" ]'              '[ -e "$_d" ]'                  1
  # /proc, /sys, /dev and /run are mounted before anything we test; the stub mount no-ops them.
  n=$(grep -c 'mount -t proc' "$dst"); [ "$n" = 1 ] || { echo "FATAL: pseudo-fs mounts changed" >&2; exit 2; }
}

seed_state() {  # <file-index> <gen> <active> <pending> <tries> [bak] [kernel] [broken]
  cat >"$SB/esp/NOVADECK/STATE.$1" <<EOF
gen=$2
active=$3
pending=$4
tries=$5
kernel=${7:-}
bak=${6:-}
broken=${8:-}
end
EOF
}

# <key> <expected value> in the winning state file -- used for the two fields that are NOT part of
# the four-field expect_state tuple, and whose whole point is that they must not go stale.
expect_field() {
  local bf g best=-1 f got
  for f in "$SB"/esp/NOVADECK/STATE.*; do
    [ -f "$f" ] || continue
    grep -qx end "$f" || continue
    g=$(sed -n 's/^gen=//p' "$f"); [ "${g:-0}" -gt "$best" ] && { best=$g; bf=$f; }
  done
  got=$(sed -n "s/^$1=//p" "$bf")
  [ "$got" = "$2" ] && ok "$1='$2'" || bad "$1: expected '$2', got '$got'"
}
expect_bak()    { expect_field bak "$1"; }
expect_kernel() { expect_field kernel "$1"; }
expect_broken() { expect_field broken "$1"; }

run_init() {
  ( cd "$SB" && PATH="$SB/bin:$PATH" sh "$SB/init" >"$SB/stdout" 2>"$SB/stderr" )
  echo $? >"$SB/rc"
}

# --- assertions ------------------------------------------------------------------------------

t() { CASE="$1"; sandbox; build_init; }

ok()   { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }
done_() { rm -rf "$SB"; }

expect_boot() {  # <key> <value>
  local got
  got=$(sed -n "s/^$1=//p" "$SB/run/novadeck/boot" 2>/dev/null)
  [ "$got" = "$2" ] && ok "$1=$2" || bad "$1: expected '$2', got '$got'"
}

# Echoes "<gen>|<active>|<pending>|<tries>" of the file with the highest gen. Pipe-delimited, not
# space-delimited: `pending` is EMPTY on exactly the states this file exists to check, and a
# whitespace `read` silently shifts every field left of it.
winning_state() {
  local best=-1 bf="" f g
  for f in "$SB"/esp/NOVADECK/STATE.*; do
    [ -f "$f" ] || continue
    g=$(sed -n 's/^gen=//p' "$f")
    grep -qx end "$f" || continue
    [ "${g:-0}" -gt "$best" ] && { best=$g; bf=$f; }
  done
  [ -n "$bf" ] || return 1
  printf '%s|%s|%s|%s' "$best" \
    "$(sed -n 's/^active=//p' "$bf")" "$(sed -n 's/^pending=//p' "$bf")" "$(sed -n 's/^tries=//p' "$bf")"
}

expect_state() {  # <gen> <active> <pending> <tries>  -- reads whichever file has the highest gen
  local w; w=$(winning_state) || { bad "no valid state file on the ESP"; return; }
  local best a p tr; IFS="|" read -r best a p tr <<<"$w"
  [ "$best" = "$1" ] && [ "$a" = "$2" ] && [ "$p" = "$3" ] && [ "$tr" = "$4" ] \
    && ok "state gen=$1 active=$2 pending='$3' tries=$4" \
    || bad "state: expected gen=$1 active=$2 pending='$3' tries=$4, got gen=$best active=$a pending='$p' tries=$tr"
}

# The handoff must describe the ESP AS IT STANDS at switch_root -- never a post-write `gen` beside
# a pre-write `pending`, which is what the init published before 2026-07-28. Asserted on every
# case that reaches a valid state, because the skew only appears on the paths that WRITE, and
# those are the boots whose offline evidence matters most.
expect_handoff_matches_state() {
  local w; w=$(winning_state) || { bad "no valid state file on the ESP"; return; }
  local best a p tr; IFS="|" read -r best a p tr <<<"$w"
  local hg ha hp ht f="$SB/run/novadeck/boot"
  hg=$(sed -n 's/^gen=//p' "$f");     ha=$(sed -n 's/^active=//p' "$f")
  hp=$(sed -n 's/^pending=//p' "$f"); ht=$(sed -n 's/^tries_left=//p' "$f")
  [ "$hg" = "$best" ] && [ "$ha" = "$a" ] && [ "$hp" = "$p" ] && [ "$ht" = "$tr" ] \
    && ok "handoff mirrors the ESP (gen=$best active=$a pending='$p' tries_left=$tr)" \
    || bad "handoff skew: ESP has gen=$best active=$a pending='$p' tries=$tr, handoff says gen=$hg active=$ha pending='$hp' tries_left=$ht"
}

expect_kmsg() { grep -qF "$1" "$SB/kmsg" && ok "logged: $1" || bad "not logged: $1"; }
expect_rc()   { local r; r=$(cat "$SB/rc"); [ "$r" = "$1" ] && ok "exit=$1" || bad "exit: expected $1, got $r"; }
expect_written_to() {  # the write must land on the file that did NOT win
  [ -f "$SB/esp/NOVADECK/STATE.$1" ] && ok "wrote STATE.$1" || bad "STATE.$1 was not written"
}

echo "== A/B slot decision =="

t "normal-a"
seed_state 0 1 a '' 0
run_init
expect_boot slot a; expect_boot source state; expect_rc 0
expect_handoff_matches_state
done_

t "normal-b"
seed_state 0 4 b '' 0
run_init
expect_boot slot b; expect_boot source state
grep -q 'novadeck-root-B' "$SB/mounts" && ok "mounted root-B" || bad "did not mount root-B"
done_

t "no-state-falls-back-to-cmdline"
run_init
expect_boot source cmdline
expect_kmsg "no valid slot state on the ESP"
grep -q 'novadeck-root-A' "$SB/mounts" && ok "cmdline root used" || bad "cmdline root not used"
done_

t "torn-file-is-rejected-older-wins"
seed_state 0 1 a '' 0
# a truncated higher generation: no `end` terminator
printf 'gen=9\nactive=b\npending=\ntries=0\n' >"$SB/esp/NOVADECK/STATE.1"
run_init
expect_boot slot a; expect_boot gen 1
done_

t "highest-generation-wins"
seed_state 0 2 a '' 0
seed_state 1 7 b '' 0
run_init
expect_boot slot b; expect_boot gen 7
done_

t "generation-10-beats-9-numerically"
seed_state 0 9 a '' 0
seed_state 1 10 b '' 0
run_init
expect_boot slot b; expect_boot gen 10
done_

t "try-decrements-then-boots-pending"
seed_state 0 5 a b 1
run_init
expect_boot slot b; expect_boot source try; expect_boot tries_left 0
expect_state 6 a b 0
expect_boot gen 6   # the decrement's generation, not the one it superseded
expect_handoff_matches_state
expect_written_to 1
done_

t "try-exhausted-rolls-back-and-clears-pending"
seed_state 0 6 a b 0
run_init
expect_boot slot a; expect_boot source rollback
expect_state 7 a '' 0
# The regression this case exists for: gen advanced to 7 while pending stayed 'b' in the handoff.
expect_boot gen 7; expect_boot pending ''; expect_boot tries_left 0
expect_handoff_matches_state
expect_kmsg "ROLLBACK: pending slot b exhausted its tries"
done_

t "readonly-esp-refuses-to-try"
seed_state 0 5 a b 1
echo ESP_RO >"$SB/unmountable"
run_init
expect_boot slot a; expect_boot source try-noro; expect_boot esp ro
expect_kmsg "ESP is read-only"
expect_state 5 a b 1   # untouched: the counter must not silently stay put on a trial
expect_handoff_matches_state   # nothing was written, so the read values are still the truth
done_

t "unmountable-pending-slot-fails-over-and-clears-pending"
seed_state 0 5 a b 1
echo 'novadeck-root-B' >"$SB/unmountable"
run_init
expect_boot slot a; expect_boot source failover
expect_kmsg "failing over to slot a"
expect_state 7 a '' 0   # gen 6 = the try decrement, gen 7 = the failover
expect_boot gen 7; expect_boot pending ''
expect_handoff_matches_state   # two writes in one boot; the handoff reflects the LAST one
done_

t "both-slots-unmountable-panics"
seed_state 0 5 a b 1
printf 'novadeck-root-A\nnovadeck-root-B\n' >"$SB/unmountable"
run_init
expect_rc 1
expect_kmsg "no bootable root — panicking"
done_

t "missing-esp-still-boots-via-cmdline"
seed_state 0 3 b '' 0
echo 'NOVADECK-ESP' >"$SB/missing"
run_init
expect_boot source cmdline; expect_boot esp none
grep -q 'novadeck-root-A' "$SB/mounts" && ok "cmdline root used" || bad "cmdline root not used"
done_

t "esp-is-unmounted-before-switch_root"
seed_state 0 1 a '' 0
run_init
grep -q "umount $SB/esp" "$SB/mounts" && ok "ESP unmounted" || bad "ESP was not unmounted"
awk '/umount/{u=NR} /switch_root/{s=NR} END{exit !(u&&s&&u<s)}' "$SB/mounts" \
  && ok "umount precedes switch_root" || bad "umount does not precede switch_root"
done_

t "unknown-keys-are-ignored-not-rejected"
cat >"$SB/esp/NOVADECK/STATE.0" <<'EOF'
gen=3
active=b
pending=
tries=0
somethingnewfrompass2=xyz
end
EOF
run_init
expect_boot slot b; expect_boot source state
done_

t "garbage-fields-are-rejected"
cat >"$SB/esp/NOVADECK/STATE.0" <<'EOF'
gen=notanumber
active=a
pending=
tries=0
end
EOF
cat >"$SB/esp/NOVADECK/STATE.1" <<'EOF'
gen=2
active=zzz
pending=
tries=0
end
EOF
run_init
expect_boot source cmdline   # neither validates -> cmdline fallback, no crash
done_

t "overlay-is-stacked-from-the-selected-slot"
seed_state 0 2 b '' 0
run_init
grep -q 'novadeck-var-B' "$SB/mounts" && ok "mounted var-B" || bad "did not mount var-B"
grep -q 'lowerdir=' "$SB/mounts" && ok "/etc overlay stacked" || bad "/etc overlay not stacked"
done_

# --- kernel rollback (design C) ----------------------------------------------------------------
# An update rotates /KERNEL and records the previous one in `bak`. If the trial it was installed
# for never gets confirmed, the rollback has to put that kernel back -- otherwise the old root
# boots under the new kernel, whose /lib/modules it does not carry (=m CFG80211/ATH12K: no Wi-Fi,
# on a device with no serial console).

t "rollback-restores-the-previous-kernel"
seed_state 0 6 a b 0 KERNEL.BAK b
printf 'NEW-KERNEL' >"$SB/esp/KERNEL"
printf 'OLD-KERNEL' >"$SB/esp/KERNEL.BAK"
run_init
expect_rc 1                     # exit 1 -> panic -> panic=5 reboots into the restored kernel
[ "$(cat "$SB/esp/KERNEL")" = "OLD-KERNEL" ] \
  && ok "KERNEL restored from KERNEL.BAK" || bad "KERNEL was not restored (got '$(cat "$SB/esp/KERNEL")')"
expect_state 7 a '' 0
expect_bak ''                   # cleared in the SAME generation that cleared pending
expect_kernel a                 # ... and `kernel` follows the image back, in that same generation
expect_kmsg "restoring the previous kernel"
awk '/umount/{u=1} END{exit !u}' "$SB/mounts" && ok "ESP unmounted before the reboot" || bad "ESP not unmounted"
done_

# The state is written BEFORE the copy (so an interrupted restore cannot be retried forever), so a
# copy that fails leaves a record claiming a rotation that did not happen. The init has to take it
# back, or `kernel` lies about which /lib/modules matches -- the exact defect this field was fixed
# for, one branch deeper.
t "a-failed-restore-takes-back-the-kernel-record"
seed_state 0 6 a b 0 KERNEL.BAK b
printf 'NEW-KERNEL' >"$SB/esp/KERNEL"
printf 'OLD-KERNEL' >"$SB/esp/KERNEL.BAK"
: >"$SB/cp-fails"
run_init
expect_rc 0                     # the restore failed, so it boots on rather than rebooting
expect_boot slot a; expect_boot source rollback
expect_kmsg "could not restore KERNEL.BAK"
expect_state 8 a '' 0           # gen 7 = the rollback, gen 8 = the correction
expect_kernel b                 # /KERNEL still holds b's image, and the state says so
expect_bak ''                   # NOT re-armed: one failed restore per boot, not a loop
expect_boot kernel b
expect_handoff_matches_state
expect_kmsg "/KERNEL is slot b's boot image but this boot is slot a"
done_

t "rollback-with-a-missing-backup-file-still-rolls-back"
seed_state 0 6 a b 0 KERNEL.BAK b
printf 'NEW-KERNEL' >"$SB/esp/KERNEL"     # no KERNEL.BAK on the ESP
run_init
expect_rc 0                     # degrades to a normal rollback rather than refusing to boot
expect_boot slot a; expect_boot source rollback
[ "$(cat "$SB/esp/KERNEL")" = "NEW-KERNEL" ] && ok "KERNEL left alone" || bad "KERNEL was touched"
expect_kernel b                 # no restore happened, so the record must not claim one
expect_kmsg "is missing"
done_

t "readonly-esp-cannot-restore-the-kernel"
seed_state 0 6 a b 0 KERNEL.BAK b
printf 'NEW-KERNEL' >"$SB/esp/KERNEL"; printf 'OLD-KERNEL' >"$SB/esp/KERNEL.BAK"
echo ESP_RO >"$SB/unmountable"
run_init
expect_rc 0
expect_boot slot a; expect_boot source rollback; expect_boot esp ro
[ "$(cat "$SB/esp/KERNEL")" = "NEW-KERNEL" ] && ok "KERNEL left alone on a ro ESP" || bad "KERNEL was rewritten on a ro ESP"
expect_kernel b
expect_kmsg "cannot restore the previous kernel"
done_

# The four cases above all reach the rollback through `tries` hitting zero. A REAL failed OTA does
# not get that far: a trial slot that will not mount fails over on its first boot, before the
# counter can ever run out, so the failover path is the one that actually runs in production. It
# used to clear `pending` and stop there -- old root, new kernel, no Wi-Fi, no serial console. The
# cases below are the failover halves of the four above, and the reason the bug survived this file
# is that the only failover case here seeded no `bak` at all.

t "failover-from-an-unmountable-trial-restores-the-previous-kernel"
seed_state 0 5 a b 1 KERNEL.BAK b
printf 'NEW-KERNEL' >"$SB/esp/KERNEL"
printf 'OLD-KERNEL' >"$SB/esp/KERNEL.BAK"
echo 'novadeck-root-B' >"$SB/unmountable"
run_init
expect_rc 1                     # exit 1 -> panic -> panic=5 reboots into the restored kernel
[ "$(cat "$SB/esp/KERNEL")" = "OLD-KERNEL" ] \
  && ok "KERNEL restored from KERNEL.BAK" || bad "KERNEL was not restored (got '$(cat "$SB/esp/KERNEL")')"
expect_state 7 a '' 0           # gen 6 = the try decrement, gen 7 = the failover
expect_bak ''
expect_kernel a
expect_kmsg "FAILOVER: restoring the previous kernel"
awk '/umount/{u=1} END{exit !u}' "$SB/mounts" && ok "ESP unmounted before the reboot" || bad "ESP not unmounted"
done_

t "a-failed-restore-on-failover-takes-back-the-kernel-record"
seed_state 0 5 a b 1 KERNEL.BAK b
printf 'NEW-KERNEL' >"$SB/esp/KERNEL"
printf 'OLD-KERNEL' >"$SB/esp/KERNEL.BAK"
echo 'novadeck-root-B' >"$SB/unmountable"
: >"$SB/cp-fails"
run_init
expect_rc 0                     # the restore failed, so it boots the other slot rather than rebooting
expect_boot slot a; expect_boot source failover
expect_kmsg "could not restore KERNEL.BAK"
expect_state 8 a '' 0           # gen 6 = try, gen 7 = failover, gen 8 = the correction
expect_kernel b                 # /KERNEL still holds b's image, and the state says so
expect_bak ''                   # NOT re-armed: one failed restore per boot, not a loop
expect_boot kernel b
expect_handoff_matches_state
expect_kmsg "/KERNEL is slot b's boot image but this boot is slot a"
done_

t "failover-with-a-missing-backup-file-still-fails-over"
seed_state 0 5 a b 1 KERNEL.BAK b
printf 'NEW-KERNEL' >"$SB/esp/KERNEL"     # no KERNEL.BAK on the ESP
echo 'novadeck-root-B' >"$SB/unmountable"
run_init
expect_rc 0                     # degrades to the old behaviour rather than refusing to boot
expect_boot slot a; expect_boot source failover
[ "$(cat "$SB/esp/KERNEL")" = "NEW-KERNEL" ] && ok "KERNEL left alone" || bad "KERNEL was touched"
expect_kernel b                 # no restore happened, so the record must not claim one
expect_kmsg "is missing"
done_

# --- kernel/root coherence ---------------------------------------------------------------------
# /KERNEL is SHARED; /lib/modules/<ver> ships inside a root. `try` on a slot the last rotation did
# not install reaches the mismatch with no update involved, and =m CFG80211/ATH12K make it look
# like "Wi-Fi broke", not "wrong kernel". The journal is the only place that can say so.

t "kernel-slot-mismatch-is-logged"
seed_state 0 3 a '' 0 '' b
run_init
expect_rc 0                     # a warning, never a refusal: not booting is the worse outcome
expect_boot slot a; expect_boot kernel b
expect_kmsg "/KERNEL is slot b's boot image but this boot is slot a"
done_

t "matching-kernel-slot-is-silent"
seed_state 0 3 a '' 0 '' a
run_init
expect_boot slot a; expect_boot kernel a
grep -qF "/lib/modules will not match" "$SB/kmsg" \
  && bad "warned about a matching kernel/slot pair" || ok "no mismatch warning"
done_

# A card seeded before `kernel` was maintained carries an empty one. It must make no claim at all
# rather than reading as "slot ''" and warning on every boot.
t "an-unrecorded-kernel-warns-about-nothing"
seed_state 0 3 b '' 0
run_init
expect_boot slot b; expect_boot kernel ''
grep -qF "/lib/modules will not match" "$SB/kmsg" \
  && bad "warned on an unrecorded kernel" || ok "no mismatch warning"
done_

# The try path writes state; `kernel` is not its business and must round-trip untouched.
t "a-try-write-preserves-the-kernel-record"
seed_state 0 5 a b 1 '' b
run_init
expect_boot slot b; expect_boot source try
expect_state 6 a b 0
expect_kernel b
done_

echo "== broken= is carried, not dropped =="

# This writer emits a FIXED field list, and it writes on EVERY trial boot to decrement `tries`. A
# `broken` marker set by novadeck-bootctl's RAUC backend would therefore survive exactly one boot
# if the field were left to the "unknown keys are ignored" rule -- and that rule is a property of
# the READER here, never of the writer. The marker's whole purpose is to outlive the failure that
# set it, so this is the assertion that makes it real.
t "a-trial-boot-decrement-preserves-broken"
seed_state 0 5 a b 1 '' '' b
run_init
expect_boot slot b; expect_boot source try
expect_state 6 a b 0
expect_broken b
done_

t "a-rollback-preserves-broken"
# The rollback path assigns STATE_KERNEL/STATE_BAK before writing; `broken` must ride through that
# write untouched -- the slot being rolled back away from is precisely the one under suspicion.
seed_state 0 7 a b 0 '' '' b
run_init
expect_boot slot a
expect_broken b
done_

t "both-slots-marked-broken-survive-a-write"
seed_state 0 3 a b 1 '' '' ab
run_init
expect_broken ab
done_

t "an-empty-broken-stays-empty"
# The common case, and the one that would show a stray default leaking in.
seed_state 0 2 a '' 0
run_init
expect_broken ''
done_

t "the-handoff-publishes-broken"
# /run/novadeck/boot is the whole offline debugging surface on a no-UART device, and
# novadeck-bootctl reads it. A marker the ESP holds but the handoff omits is one that nothing on
# the running system can see.
seed_state 0 4 a '' 0 '' '' b
run_init
expect_boot broken b
done_

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
