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

seed_state() {  # <file-index> <gen> <active> <pending> <tries>
  cat >"$SB/esp/NOVADECK/STATE.$1" <<EOF
gen=$2
active=$3
pending=$4
tries=$5
kernel=
bak=
end
EOF
}

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

expect_state() {  # <gen> <active> <pending> <tries>  -- reads whichever file has the highest gen
  local best=-1 bf="" f g
  for f in "$SB"/esp/NOVADECK/STATE.*; do
    [ -f "$f" ] || continue
    g=$(sed -n 's/^gen=//p' "$f")
    grep -qx end "$f" || continue
    [ "${g:-0}" -gt "$best" ] && { best=$g; bf=$f; }
  done
  [ -n "$bf" ] || { bad "no valid state file on the ESP"; return; }
  local a p tr
  a=$(sed -n 's/^active=//p' "$bf"); p=$(sed -n 's/^pending=//p' "$bf"); tr=$(sed -n 's/^tries=//p' "$bf")
  [ "$best" = "$1" ] && [ "$a" = "$2" ] && [ "$p" = "$3" ] && [ "$tr" = "$4" ] \
    && ok "state gen=$1 active=$2 pending='$3' tries=$4" \
    || bad "state: expected gen=$1 active=$2 pending='$3' tries=$4, got gen=$best active=$a pending='$p' tries=$tr"
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
expect_written_to 1
done_

t "try-exhausted-rolls-back-and-clears-pending"
seed_state 0 6 a b 0
run_init
expect_boot slot a; expect_boot source rollback
expect_state 7 a '' 0
expect_kmsg "ROLLBACK: pending slot b exhausted its tries"
done_

t "readonly-esp-refuses-to-try"
seed_state 0 5 a b 1
echo ESP_RO >"$SB/unmountable"
run_init
expect_boot slot a; expect_boot source try-noro; expect_boot esp ro
expect_kmsg "ESP is read-only"
expect_state 5 a b 1   # untouched: the counter must not silently stay put on a trial
done_

t "unmountable-pending-slot-fails-over-and-clears-pending"
seed_state 0 5 a b 1
echo 'novadeck-root-B' >"$SB/unmountable"
run_init
expect_boot slot a; expect_boot source failover
expect_kmsg "failing over to slot a"
expect_state 7 a '' 0   # gen 6 = the try decrement, gen 7 = the failover
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

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
