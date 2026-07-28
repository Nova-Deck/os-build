#!/usr/bin/env bash
# Offline test for /usr/lib/rauc/post-install.sh — the RAUC handler that turns a freshly written
# slot into a bootable one.
#
#   images/test-post-install.sh
#
# WHY THIS FILE EXISTS. The hook is the most destructive program we ship: it runs `mkfs.ext4` and
# `btrfstune -f -U` against a partition it picks itself, and the only two places its answer could
# come from disagree by design (our initramfs handoff vs RAUC's exported slot names). Until this
# file, none of that had offline coverage — images/test-bootctl.sh asserts the calls the hook MAKES,
# never the hook itself, so every claim in its header was checked by reading it. That is the same
# gap that let `set-state <slot> bad` ship broken and cost a hardware install at 40%.
#
# ORDER IS THE POINT. The hook's own header calls its five steps load-bearing, and every one of them
# is an ORDERING claim rather than a value: the fsid must be re-randomised before anything mounts
# the target (or a mount of the target can silently hand you the RUNNING root — same fsid, same
# devid=1), the target must be disarmed before the work and re-armed only after the kernel is in
# place, and the slot witness must be written after the wholesale copy that would otherwise clobber
# it. Values are cheap to check by eye; order is not. So every stub appends to one call log and the
# assertions are largely `expect_order`.
#
# HOW IT WORKS: the real, shipped post-install.sh is executed — not a copy — through the six test
# seams documented at its head (ESP, MNT, BOOTINFO, VAR, DEVDIR, DEVTEST). novadeck-bootctl is the
# shipped tool too, reached through a shim that only supplies ITS seams. Stubbed on PATH: exactly
# the commands that would touch real storage (mount, umount, mkfs.ext4, btrfstune, rsync) plus `id`
# and `mountpoint`, as in test-bootctl.sh. Each storage stub models the effect the hook depends on —
# mkfs empties the backing directory, mount exposes it at $MNT, rsync copies — so what the copy
# actually leaves on the target slot is asserted, not assumed.
#
# WHAT IT CANNOT COVER, so that nobody reads a green run as more than it is: whether btrfstune's new
# fsid actually stops the kernel aliasing the two roots, whether rsync's real --one-file-system
# skips our offload bind mounts, and whether 256M is enough for the copy. Those need the device.
# This asserts that the hook asks for the right things, in the right order, and refuses to act on a
# target it cannot prove.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/fs-overlay/usr/lib/rauc/post-install.sh"
BOOTCTL="$ROOT/fs-overlay/usr/bin/novadeck-bootctl"
[ -f "$HOOK" ]    || { echo "no post-install hook: $HOOK" >&2; exit 1; }
[ -f "$BOOTCTL" ] || { echo "no novadeck-bootctl: $BOOTCTL" >&2; exit 1; }

PASS=0; FAIL=0; CASE=""; SB=""
OUT=""; RC=0; RAUC_SLOTS=""

ok()  { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }

# --- sandbox ------------------------------------------------------------------------------------
#
# Slot devices are regular files under $SB/dev (hence DEVTEST=-e), and each one's "filesystem" is a
# directory under $SB/fs named after it. `mount` symlinks $MNT at that directory, `umount` removes
# the symlink, `mkfs.ext4` empties it. That is enough to model everything the hook does with a
# mounted slot, and it means a hook that mounted the WRONG device would read and write visibly
# wrong contents rather than passing.

sandbox() {
  SB="$(mktemp -d)"
  mkdir -p "$SB"/{bin,dev,fs,run,log,esp/NOVADECK,var}
  : >"$SB/log/calls"

  # The four slot devices, all present. Cases that need one missing delete it.
  touch "$SB"/dev/novadeck-{root,var}-{A,B}
  mkdir -p "$SB"/fs/novadeck-{root,var}-{A,B}

  # A written slot carries the new kernel inside the root — that is design C's whole point.
  mkdir -p "$SB/fs/novadeck-root-B/usr/lib/novadeck" "$SB/fs/novadeck-root-A/usr/lib/novadeck"
  printf 'NEW-KERNEL-B' >"$SB/fs/novadeck-root-B/usr/lib/novadeck/boot.img"
  printf 'NEW-KERNEL-A' >"$SB/fs/novadeck-root-A/usr/lib/novadeck/boot.img"

  # Stale state on the target's /var, so a missing reformat is visible rather than invisible.
  mkdir -p "$SB/fs/novadeck-var-B/lib/novadeck"
  printf 'stale\n' >"$SB/fs/novadeck-var-B/lib/novadeck/leftover-from-the-last-install"

  printf 'OLD-KERNEL' >"$SB/esp/KERNEL"

  cat >"$SB/bin/id" <<'EOF'
#!/bin/sh
[ "$1" = -u ] && { echo 0; exit 0; }
exec /usr/bin/id "$@"
EOF
  # The ESP automount probe, used by both the hook and novadeck-bootctl. `fail-esp` makes it answer
  # "not mounted" only once the run has reached step 1, so the disarm at step 0 — which probes the
  # same path through bootctl — still works. Without that the ESP case would fail in the wrong place.
  cat >"$SB/bin/mountpoint" <<'EOF'
#!/bin/sh
[ -e "$SB/fail-esp" ] && grep -q '^btrfstune' "$SB/log/calls" && exit 1
exit 0
EOF
  cat >"$SB/bin/mount" <<'EOF'
#!/bin/sh
echo "mount $*" >>"$SB/log/calls"
[ -e "$SB/fail-mount" ] && exit 32
last=; prev=
for a in "$@"; do prev=$last; last=$a; done
back="$SB/fs/${prev##*/}"
[ -d "$back" ] || { echo "mount: no filesystem on ${prev}" >&2; exit 32; }
rm -rf "$last"
ln -s "$back" "$last"
EOF
  cat >"$SB/bin/umount" <<'EOF'
#!/bin/sh
echo "umount $*" >>"$SB/log/calls"
[ -L "$1" ] || { echo "umount: $1: not mounted" >&2; exit 32; }
rm -f "$1"
EOF
  cat >"$SB/bin/mkfs.ext4" <<'EOF'
#!/bin/sh
echo "mkfs.ext4 $*" >>"$SB/log/calls"
[ -e "$SB/fail-mkfs" ] && exit 1
last=
for a in "$@"; do last=$a; done
rm -rf "$SB/fs/${last##*/}"
mkdir -p "$SB/fs/${last##*/}"
EOF
  cat >"$SB/bin/btrfstune" <<'EOF'
#!/bin/sh
echo "btrfstune $*" >>"$SB/log/calls"
[ -e "$SB/fail-btrfstune" ] && exit 1
exit 0
EOF
  # Copies for real, so the exclusions and the wholesale claim are asserted against actual bytes on
  # the target. The flags themselves are asserted from the call log — a stub cannot prove that real
  # rsync honours --one-file-system, only that we asked for it.
  cat >"$SB/bin/rsync" <<'EOF'
#!/bin/sh
echo "rsync $*" >>"$SB/log/calls"
[ -e "$SB/fail-rsync" ] && exit 1
last=; prev=
for a in "$@"; do prev=$last; last=$a; done
cp -a "$prev." "$last" || exit 1
EOF
  cat >"$SB/bin/novadeck-bootctl" <<'EOF'
#!/bin/sh
echo "bootctl $*" >>"$SB/log/calls"
BOOTINFO="$SB/run/boot" ESP_AUTO="$SB/esp" ESP_MANUAL="$SB/esp" exec bash "$BOOTCTL" "$@"
EOF
  chmod +x "$SB/bin"/*
}
done_() { rm -rf "$SB"; }
t() { CASE="$1"; RAUC_SLOTS=""; sandbox; }

# Run the SHIPPED hook against the sandbox.
run() {
  local env_extra=()
  [ -n "$RAUC_SLOTS" ] && env_extra=(RAUC_TARGET_SLOTS="$RAUC_SLOTS")
  OUT=$(env PATH="$SB/bin:$PATH" SB="$SB" BOOTCTL="$BOOTCTL" \
            ESP="$SB/esp" MNT="$SB/mnt" BOOTINFO="$SB/run/boot" VAR="$SB/var" \
            DEVDIR="$SB/dev" DEVTEST=-e "${env_extra[@]}" \
            bash "$HOOK" 2>&1)
  RC=$?
  return 0
}

# --- seeding ------------------------------------------------------------------------------------

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

seed_boot() { printf 'slot=%s\nsource=%s\ngen=1\nactive=%s\npending=\ntries_left=0\n' \
                     "$1" "${2:-state}" "$1" >"$SB/run/boot"; }

# The state RAUC leaves behind before it calls us, taken from a real install: it marked the target
# bad pre-write, then armed it. Every case that reaches step 0 starts here.
seed_rauc_armed() { seed_state 0 1 "$1" "$2" 1 "$1" '' "$2"; seed_boot "$1"; }

# A running /var with the pieces that have to survive an update, plus the two that must not.
seed_var() {
  mkdir -p "$SB/var/lib/novadeck" \
           "$SB/var/lib/overlays/etc/upper/NetworkManager/system-connections" \
           "$SB/var/lib/overlays/etc/work" "$SB/var/lib/systemd"
  printf 'a\n'          >"$SB/var/lib/novadeck/slot"
  printf 'de:ad:be:ef:00:01\n' >"$SB/var/lib/novadeck/mac-wifi"
  printf '7070e56b\n'   >"$SB/var/lib/overlays/etc/upper/machine-id"
  printf '[wifi]\n'     >"$SB/var/lib/overlays/etc/upper/NetworkManager/system-connections/home.nmconnection"
  printf 'ssh-ed25519\n' >"$SB/var/lib/overlays/etc/upper/ssh_host_ed25519_key"
  printf 'seed\n'       >"$SB/var/lib/systemd/random-seed"
}

# --- assertions ---------------------------------------------------------------------------------

expect_rc()  { [ "$RC" = "$1" ] && ok "exit=$1" || bad "exit: expected $1, got $RC (output: $OUT)"; }
expect_has() { case "$OUT" in *"$1"*) ok "says '$1'" ;; *) bad "expected '$1' in output, got: $OUT" ;; esac; }

expect_call() {
  grep -q -- "$1" "$SB/log/calls" && ok "called: $1" \
    || bad "expected a call matching '$1'; log was: $(tr '\n' ';' <"$SB/log/calls")"
}
expect_no_call() {
  grep -q -- "$1" "$SB/log/calls" \
    && bad "must not call '$1'; log was: $(tr '\n' ';' <"$SB/log/calls")" || ok "never called: $1"
}
# The assertion this file is mostly made of.
expect_order() {  # <earlier> <later>
  local i j
  i=$(grep -n -m1 -- "$1" "$SB/log/calls" | cut -d: -f1)
  j=$(grep -n -m1 -- "$2" "$SB/log/calls" | cut -d: -f1)
  [ -n "$i" ] || { bad "order: '$1' never happened"; return; }
  [ -n "$j" ] || { bad "order: '$2' never happened"; return; }
  [ "$i" -lt "$j" ] && ok "'$1' before '$2'" || bad "'$1' came AFTER '$2' (lines $i, $j)"
}

# Slot state, read the way the initramfs reads it: highest complete generation wins.
state_field() {  # <key>
  local best=-1 bf="" f g
  for f in "$SB"/esp/NOVADECK/STATE.*; do
    [ -f "$f" ] || continue
    grep -qx end "$f" || continue
    g=$(sed -n 's/^gen=//p' "$f")
    [ "${g:-0}" -gt "$best" ] && { best=$g; bf=$f; }
  done
  [ -n "$bf" ] || return 1
  sed -n "s/^$1=//p" "$bf"
}
expect_field() {  # <key> <value>
  local got; got=$(state_field "$1")
  [ "$got" = "$2" ] && ok "$1='$2'" || bad "$1: expected '$2', got '$got'"
}

# Contents of the target slot's /var, i.e. what the updated slot will actually boot with.
tvar() { printf '%s' "$SB/fs/novadeck-var-$1"; }
expect_file() {  # <path> <content>
  [ -f "$1" ] || { bad "missing on the target slot: ${1#"$SB/fs/"}"; return; }
  local got; got=$(cat "$1")
  [ "$got" = "$2" ] && ok "${1#"$SB/fs/"} = '$2'" || bad "${1#"$SB/fs/"}: expected '$2', got '$got'"
}
expect_absent() {
  [ -e "$1" ] && bad "must not exist on the target slot: ${1#"$SB/fs/"}" || ok "absent: ${1#"$SB/fs/"}"
}
expect_esp() {  # <name> <content>
  [ -f "$SB/esp/$1" ] || { bad "no /$1 on the ESP"; return; }
  local got; got=$(cat "$SB/esp/$1")
  [ "$got" = "$2" ] && ok "/$1 = '$2'" || bad "/$1: expected '$2', got '$got'"
}

echo "== which slot: the handoff decides, RAUC only gets to disagree =="

t "the-target-is-the-slot-we-did-not-boot"
seed_rauc_armed a b; seed_var
run
expect_rc 0
expect_has "target slot b"
expect_call 'btrfstune .*novadeck-root-B'
expect_call 'mkfs.ext4 .*novadeck-var-B'
done_

t "booting-b-targets-a"
seed_rauc_armed b a; seed_var
run
expect_rc 0
expect_call 'btrfstune .*novadeck-root-A'
expect_call 'mkfs.ext4 .*novadeck-var-A'
expect_field pending a
done_

t "the-running-slot-is-never-touched"
# The failure this rules out is unrecoverable and silent: mkfs on the RUNNING /var. Nothing else in
# the suite would notice, because every other assertion is about the target.
seed_rauc_armed a b; seed_var
run
expect_rc 0
expect_no_call 'novadeck-var-A'
expect_no_call 'novadeck-root-A'
done_

t "rauc-agreeing-is-not-required-but-disagreeing-is-fatal"
seed_rauc_armed a b; seed_var
RAUC_SLOTS="rootfs.0"          # RAUC says it wrote a; we booted a, so the target must be b
run
expect_rc 1
expect_has "refusing"
expect_no_call 'mkfs.ext4'
expect_no_call 'btrfstune'
expect_no_call 'bootctl'       # it dies before the disarm, so RAUC's own arming is left intact
expect_field pending b
done_

t "rauc-agreeing-proceeds"
seed_rauc_armed a b; seed_var
RAUC_SLOTS="rootfs.1"
run
expect_rc 0
expect_call 'mkfs.ext4 .*novadeck-var-B'
done_

t "an-unrecognised-rauc-slot-name-is-not-a-veto"
# The cross-check is RAUC's value against ours, and ours is authoritative. A name we cannot map is
# no evidence of disagreement, so it must not block an install.
seed_rauc_armed a b; seed_var
RAUC_SLOTS="rootfs.9"
run
expect_rc 0
expect_call 'mkfs.ext4 .*novadeck-var-B'
done_

t "a-boot-that-resolved-no-slot-is-refused"
# The cmdline-fallback boot writes the handoff with an empty slot=. There is no safe guess here:
# picking wrong reformats the running system's /var.
seed_state 0 1 a '' 0; printf 'slot=\nsource=cmdline\n' >"$SB/run/boot"; seed_var
run
expect_rc 1
expect_has "refusing to guess"
expect_no_call 'mkfs.ext4'
done_

t "no-handoff-at-all-is-refused"
seed_state 0 1 a '' 0; seed_var
run
expect_rc 1
expect_no_call 'mkfs.ext4'
done_

t "a-missing-slot-device-is-refused-before-anything-is-touched"
seed_rauc_armed a b; seed_var
rm -f "$SB/dev/novadeck-var-B"
run
expect_rc 1
expect_has "no block device"
expect_no_call 'mkfs.ext4'
expect_no_call 'btrfstune'
done_

echo "== order: every step of the header, as an assertion =="

t "the-fsid-is-randomised-before-anything-mounts-the-target"
# Step 1 exists because until btrfstune has run the target and the running root share an fsid AND
# devid=1, and mounting the target can hand you the running root. Every later step mounts it.
seed_rauc_armed a b; seed_var
run
expect_rc 0
expect_order '^btrfstune' '^mount'
expect_call 'btrfstune -f -U'
done_

t "the-slot-is-disarmed-before-the-work-and-armed-after-it"
seed_rauc_armed a b; seed_var
run
expect_rc 0
expect_order '^bootctl rollback' '^btrfstune'
expect_order '^btrfstune' '^bootctl set-primary'
expect_order '^bootctl set-kernel' '^bootctl set-primary'
expect_order '^bootctl set-state b good' '^bootctl set-primary'
done_

t "var-is-reformatted-before-it-is-copied-into"
seed_rauc_armed a b; seed_var
run
expect_rc 0
expect_order '^mkfs.ext4' '^rsync'
expect_order '^mkfs.ext4' '^mount .*novadeck-var-B'
done_

t "the-target-var-is-unmounted-before-the-root-is-mounted"
seed_rauc_armed a b; seed_var
run
expect_rc 0
expect_order '^umount' '^mount -o ro'
done_

echo "== /var: wholesale, minus two files named in writing =="

t "the-copy-is-wholesale"
# The design decision this locks in: a whitelist has to be extended for every new piece of
# per-device state, and forgetting one fails silently on a device with no serial console. SSH host
# keys were the next instance after machine-id; there would have been another.
seed_rauc_armed a b; seed_var
run
expect_rc 0
expect_file "$(tvar B)/lib/overlays/etc/upper/machine-id" '7070e56b'
expect_file "$(tvar B)/lib/overlays/etc/upper/ssh_host_ed25519_key" 'ssh-ed25519'
expect_file "$(tvar B)/lib/systemd/random-seed" 'seed'
done_

t "the-saved-wifi-rides-across"
# TODO.md rates this brick-class on a RELEASE image: the NetworkManager connections live in the
# /etc overlay's upper dir, which lives in the PER-SLOT /var. A target slot without them boots a
# Wi-Fi-only, headless, serial-console-less device with no network and no way back in.
seed_rauc_armed a b; seed_var
run
expect_rc 0
expect_file "$(tvar B)/lib/overlays/etc/upper/NetworkManager/system-connections/home.nmconnection" '[wifi]'
done_

t "the-copy-asks-for-the-flags-that-make-it-safe"
# A stub cannot prove real rsync honours these; it can prove we never quietly stop asking.
# --one-file-system keeps the shared /home offload binds out of a 256M partition, and -aHAX keeps
# the modes that sshd refuses to start without.
seed_rauc_armed a b; seed_var
run
expect_rc 0
expect_call 'rsync -aHAX --numeric-ids --one-file-system'
done_

t "the-reformat-drops-the-previous-installs-state"
seed_rauc_armed a b; seed_var
run
expect_rc 0
expect_absent "$(tvar B)/lib/novadeck/leftover-from-the-last-install"
expect_call 'mkfs.ext4 .*-L novadeck-var-B'
done_

t "the-slot-witness-is-rewritten-to-the-target"
# The regression this pins: /var/lib/novadeck/slot is the independent witness `novadeck-bootctl
# status` cross-checks the initramfs's choice against. Copied verbatim it would make the target
# agree with a lie, and it must therefore be written AFTER the wholesale copy, not before.
seed_rauc_armed a b; seed_var
run
expect_rc 0
expect_file "$(tvar B)/lib/novadeck/slot" 'b'
done_

t "the-mac-seed-does-not-survive-the-copy"
# Write-once and outranks the derivation, so a unit flashed before the MAC-collision fix keeps a
# colliding address forever unless an update clears it. Deleting it re-derives from the machine-id
# the copy just carried over — same id, same MAC, so a healthy device sees no change.
seed_rauc_armed a b; seed_var
run
expect_rc 0
expect_absent "$(tvar B)/lib/novadeck/mac-wifi"
expect_file "$(tvar B)/lib/overlays/etc/upper/machine-id" '7070e56b'
done_

t "the-overlay-dirs-exist-even-if-the-copy-did-not-bring-them"
# The one case that would be unrecoverable: the initramfs mounts /etc from these, so a slot without
# them does not come up at all.
seed_rauc_armed a b
mkdir -p "$SB/var/lib/novadeck"; printf 'a\n' >"$SB/var/lib/novadeck/slot"
run
expect_rc 0
[ -d "$(tvar B)/lib/overlays/etc/upper" ] && ok "upper/ created" || bad "no overlay upper/ on the target"
[ -d "$(tvar B)/lib/overlays/etc/work" ]  && ok "work/ created"  || bad "no overlay work/ on the target"
done_

echo "== /KERNEL: rotate, keeping a way back =="

t "the-kernel-comes-out-of-the-new-root"
# Not out of the bundle: /lib/modules/<ver> ships inside the rootfs, so taking the kernel from the
# root it belongs to makes the pairing true by construction. CFG80211/ATH12K are =m — a mismatch is
# a device with no Wi-Fi and no serial console.
seed_rauc_armed a b; seed_var
run
expect_rc 0
expect_esp KERNEL 'NEW-KERNEL-B'
expect_call 'mount -o ro .*novadeck-root-B'
done_

t "the-previous-kernel-is-kept-and-recorded"
seed_rauc_armed a b; seed_var
run
expect_rc 0
expect_esp KERNEL.BAK 'OLD-KERNEL'
expect_field bak KERNEL.BAK
expect_field kernel b
done_

t "the-staging-copy-is-not-left-behind"
# The rotation stages to KERNEL.NEW so a torn copy can never land on /KERNEL. A leftover would be
# harmless today and confusing forever.
seed_rauc_armed a b; seed_var
run
expect_rc 0
expect_absent "$SB/esp/KERNEL.NEW"
done_

t "no-kernel-to-back-up-records-no-backup"
# `bak` is what the initramfs restores from, so it must name a file that EXISTS. Recording one
# anyway arms a restore that can only fail, on the boot least able to absorb a surprise.
seed_rauc_armed a b; seed_var
rm -f "$SB/esp/KERNEL"
run
expect_rc 0
expect_has "no /KERNEL on the ESP to back up"
expect_field bak ''
expect_field kernel b
expect_esp KERNEL 'NEW-KERNEL-B'
done_

t "a-root-with-no-boot-image-is-fatal-and-leaves-the-esp-alone"
seed_rauc_armed a b; seed_var
rm -f "$SB/fs/novadeck-root-B/usr/lib/novadeck/boot.img"
run
expect_rc 1
expect_has "carries no boot image"
expect_esp KERNEL 'OLD-KERNEL'
expect_no_call 'bootctl set-primary'
expect_field pending ''
done_

t "an-esp-that-is-not-mounted-is-fatal"
seed_rauc_armed a b; seed_var
: >"$SB/fail-esp"
run
expect_rc 1
expect_has "ESP is not mounted"
expect_esp KERNEL 'OLD-KERNEL'
expect_field pending ''
done_

echo "== the end state, and every way of not reaching it =="

t "a-completed-run-ends-armed-unmarked-and-recorded"
seed_rauc_armed a b; seed_var
run
expect_rc 0
expect_field active a           # the trial has not happened yet; a is still what boots on failure
expect_field pending b
expect_field tries 1
expect_field broken ''          # RAUC's pre-write marking, cleared by the only thing that knows
expect_field kernel b
expect_field bak KERNEL.BAK
expect_has "re-armed for a trial boot"
done_

t "a-failure-at-the-fsid-leaves-nothing-armed"
# The whole point of the disarm. RAUC armed the slot before calling us; between step 0 and the last
# line the target has a freshly mkfs'd /var and the other slot's kernel, so a state pointing at it
# boots a root with no /etc overlay under mismatched modules. The failure mode has to be "the
# install failed, run it again", not "one bad boot, hope the rollback fires".
seed_rauc_armed a b; seed_var
: >"$SB/fail-btrfstune"
run
expect_rc 1
expect_field pending ''
expect_field tries 0
expect_no_call 'mkfs.ext4'
done_

t "a-failure-during-the-copy-leaves-nothing-armed"
seed_rauc_armed a b; seed_var
: >"$SB/fail-rsync"
run
expect_rc 1
expect_field pending ''
expect_esp KERNEL 'OLD-KERNEL'
expect_absent "$SB/esp/KERNEL.BAK"
done_

t "an-interrupted-install-still-answers-bad-afterwards"
# The other half of the design: the slot RAUC marked bad before writing stays marked, because
# nothing but a COMPLETED install clears it. A half-written slot must not answer good.
seed_rauc_armed a b; seed_var
: >"$SB/fail-rsync"
run
expect_rc 1
expect_field broken b
done_

t "the-disarm-failing-stops-the-install-before-it-starts"
# If we cannot take RAUC's arming back we cannot make the window safe, and proceeding would spend
# the safety net on a failure we chose to create.
seed_boot a                      # ...with no state on the ESP at all, so rollback cannot write
seed_var
run
expect_rc 1
expect_has "cannot disarm"
expect_no_call 'btrfstune'
expect_no_call 'mkfs.ext4'
done_

# --- summary ------------------------------------------------------------------------------------

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ] || exit 1
