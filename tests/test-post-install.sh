#!/usr/bin/env bash
# Offline test for /usr/lib/rauc/post-install.sh — the RAUC handler that turns a freshly written
# slot into a bootable one.
#
#   tests/test-post-install.sh
#
# WHY THIS FILE EXISTS. The hook is the most destructive program we ship: it runs `mkfs.ext4` and
# `btrfstune -f -U` against a partition it picks itself, and the only two places its answer could
# come from disagree by design (steamos-bootconf this-image vs RAUC's exported slot names). Until
# this file, none of that had offline coverage — tests/test-bootctl.sh asserts the calls the hook
# MAKES through the backend, never the hook itself. That is the same gap that let `set-state <slot>
# bad` ship broken and cost a hardware install at 40%.
#
# ORDER IS THE POINT. The hook's own header calls its steps load-bearing, and every one of them is
# an ORDERING claim rather than a value: the fsid must be re-randomised before anything mounts the
# target (or a mount of the target can silently hand you the RUNNING root — same fsid, same devid=1),
# the target must be disarmed before the work and re-armed only after the bootconf is written, and
# the slot witness must be written after the wholesale copy that would otherwise clobber it. Values
# are cheap to check by eye; order is not. So every stub appends to one call log and the assertions
# are largely `expect_order`.
#
# HOW IT WORKS: the real, shipped post-install.sh is executed — not a copy — through the test seams
# documented at its head (ESP, EFI, MNT, EFIMNT, VAR, DEVDIR, DEVTEST, BC). steamos-bootconf is the
# stubbed via the BC seam: `this-image` reads partsets/self off the emulated /efi, and the state
# writes land in the emulated /esp/SteamOS/conf. Stubbed on PATH: exactly the commands that would
# touch real storage (mount, umount, mkfs.ext4, btrfstune, rsync) plus `mountpoint`, as in the old
# suite. Each storage stub models the effect the hook depends on — mkfs empties the backing
# directory, mount exposes it at $MNT, rsync copies — so what the copy actually leaves on the target
# slot is asserted, not assumed.
#
# WHAT IT CANNOT COVER, so that nobody reads a green run as more than it is: whether btrfstune's new
# fsid actually stops the kernel aliasing the two roots, whether rsync's real --one-file-system
# skips our offload bind mounts, whether 256M is enough for the copy, and whether GRUB actually
# boots the freshly written efi partition. Those need the device. This asserts that the
# hook asks for the right things, in the right order, and refuses to act on a target it cannot prove.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/fs-overlay/usr/lib/rauc/post-install.sh"
[ -f "$HOOK" ] || { echo "no post-install hook: $HOOK" >&2; exit 1; }

PASS=0; FAIL=0; CASE=""; SB=""
OUT=""; RC=0; RAUC_SLOTS=""

ok()  { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }

# --- sandbox ------------------------------------------------------------------------------------
#
# Slot devices are regular files under $SB/dev (hence DEVTEST=-e), and each one's "filesystem" is a
# directory under $SB/fs named after it. `mount` symlinks $MNT at that directory, `umount` removes
# the symlink, `mkfs.ext4` empties it. That is enough to model everything the hook does with a
# mounted slot, and it means a hook that mounted the WRONG device would read and write visibly wrong
# contents rather than passing.
#
# Layout in play, mirroring the device:
#   $SB/efi   = the RUNNING slot's efi partition, mounted at $EFI (SteamOS/partsets)
#   $SB/esp   = the shared ESP, mounted at $ESP (SteamOS/conf, EFI/BOOT/bootaa64.efi, ...)
#   $SB/var   = the RUNNING /var
#   $SB/fs/novadeck-root-<s>, novadeck-var-<s>, novadeck-efi-<s> = the six slot filesystems

sandbox() {
  SB="$(mktemp -d)"
  mkdir -p "$SB"/{bin,dev,fs,log,run,var,mnt,efimnt} \
           "$SB/esp/SteamOS/conf" \
           "$SB/esp/EFI/BOOT" "$SB/esp/EFI/novadeck" \
           "$SB/efi/SteamOS/partsets"
  : >"$SB/log/calls"

  touch "$SB"/dev/novadeck-{root,var,efi}-{A,B}
  for s in A B; do
    mkdir -p "$SB/fs/novadeck-root-$s/usr/lib/novadeck/boot/fonts" \
             "$SB/fs/novadeck-efi-$s/EFI/steamos" \
             "$SB/fs/novadeck-efi-$s/SteamOS" \
             "$SB/fs/novadeck-var-$s/lib/novadeck"
    # Stage-2 + stage-1 boot files inside the installed roots, so the hook's source files exist.
    # grub-<slot>.cfg is lowercase (that is boot/grub.sh's output and what the hook looks up).
    printf 'GRUB-%s\n'    "$s" >"$SB/fs/novadeck-root-$s/usr/lib/novadeck/boot/grubaa64.efi"
    printf 'CFG-%s\n'     "$s" >"$SB/fs/novadeck-root-$s/usr/lib/novadeck/boot/grub-${s,,}.cfg"
    printf 'FONT-%s\n'    "$s" >"$SB/fs/novadeck-root-$s/usr/lib/novadeck/boot/fonts/dejavu-mono.pf2"
    printf 'FONT-%s\n'    "$s" >"$SB/fs/novadeck-root-$s/usr/lib/novadeck/boot/fonts/default.pf2"
    printf 'STEAMCL-%s\n' "$s" >"$SB/fs/novadeck-root-$s/usr/lib/novadeck/boot/steamcl.efi"
    printf '1.%s\n'       "$s" >"$SB/fs/novadeck-root-$s/usr/lib/novadeck/boot/steamcl-version"
    # Stale stage 2 on the target efi, so a missed refresh is visible rather than invisible.
    printf 'OLD-EFI-GRUB-%s\n' "$s" >"$SB/fs/novadeck-efi-$s/EFI/steamos/grubaa64.efi"
    # Stale state on the target /var, so a missing reformat is visible rather than invisible.
    printf 'stale\n' >"$SB/fs/novadeck-var-$s/lib/novadeck/leftover-from-the-last-install"
  done

  # Partsets on the RUNNING efi. Disk-derived content for A/B/dev so the refresh is assertable.
  for f in all shared A B dev; do printf 'partset-%s\n' "$f" >"$SB/efi/SteamOS/partsets/$f"; done
  set_efi A

  # ESP state. The confs exist by default (a real device's images were both installed at some
  # point); cases that want a missing target conf delete it. The old steamcl is stale on purpose.
  : >"$SB/esp/SteamOS/conf/A.conf"
  : >"$SB/esp/SteamOS/conf/B.conf"
  printf 'OLD-STEAMCL\n' >"$SB/esp/EFI/BOOT/bootaa64.efi"
  printf 'OLD-STEAMCL\n' >"$SB/esp/EFI/novadeck/steamcl.efi"
  printf '0.9\n'         >"$SB/esp/EFI/novadeck/steamcl-version"

  seed_var
  write_stubs
}
done_() { rm -rf "$SB"; }
t() { CASE="$1"; RAUC_SLOTS=""; sandbox; }

set_efi() {  # <booted-image>  — writes partsets/self + /other on the running efi
  local booted="$1" other
  case "$booted" in A) other=B ;; B) other=A ;; *) other=A ;; esac
  printf '%s\n' "$booted" >"$SB/efi/SteamOS/partsets/self"
  printf '%s\n' "$other"  >"$SB/efi/SteamOS/partsets/other"
}

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

write_stubs() {
  cat >"$SB/bin/mount" <<'EOF'
#!/bin/sh
echo "mount $*" >>"$SB/log/calls"
[ -e "$SB/fail-mount" ] && exit 32
prev=; last=
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
  # `btrfs filesystem label` -- the second half of un-sharing the target's identity. The bundle
  # image is slot A's byte for byte, so a raw write leaves BOTH partitions labelled
  # novadeck-root-A until this runs.
  cat >"$SB/bin/btrfs" <<'EOF'
#!/bin/sh
echo "btrfs $*" >>"$SB/log/calls"
[ -e "$SB/fail-btrfs-label" ] && exit 1
exit 0
EOF
  cat >"$SB/bin/rsync" <<'EOF'
#!/bin/sh
echo "rsync $*" >>"$SB/log/calls"
[ -e "$SB/fail-rsync" ] && exit 1
prev=; last=
for a in "$@"; do prev=$last; last=$a; done
cp -a "$prev." "$last" || exit 1
EOF
  cat >"$SB/bin/mountpoint" <<'EOF'
#!/bin/sh
[ -e "$SB/fail-esp" ] && exit 1
exit 0
EOF
  # steamos-bootconf, reached through the hook's BC seam. this-image is the partset; set-mode
  # requires the image's conf to exist (as the real bootconf does) so the disarm can fail; the
  # writes land in the emulated /esp/SteamOS/conf. Every invocation is logged for the order
  # assertions.
  cat >"$SB/bin/steamos-bootconf" <<'EOF'
#!/usr/bin/env bash
set -u
CONF=""; EFI=""
cmd=""; IMAGE=""; pos=(); sets=()
args=("$@"); i=0
while [ "$i" -lt "${#args[@]}" ]; do
  a="${args[$i]}"; i=$((i+1))
  case "$a" in
    --conf-dir) CONF="${args[$i]}"; i=$((i+1)) ;;
    --efi-dir)  EFI="${args[$i]}";  i=$((i+1)) ;;
    --image)    IMAGE="${args[$i]}"; i=$((i+1)) ;;
    --set)      sets+=("${args[$i]} ${args[$((i+1))]}"); i=$((i+2)) ;;
    -v|--verbose) ;;
    *) if [ -z "$cmd" ]; then cmd="$a"; else pos+=("$a"); fi ;;
  esac
done
conf_of() { printf '%s/%s.conf' "$CONF" "$1"; }
case "$cmd" in
  this-image) cat "$EFI/SteamOS/partsets/self" 2>/dev/null ;;
  set-mode)
    T="${IMAGE:?}"; m="${pos[0]:-}"
    echo "BC set-mode $T $m" >>"$SB/log/calls"
    [ -f "$(conf_of "$T")" ] || { echo "stub: no conf for $T" >&2; exit 1; }
    for s in "${sets[@]}"; do printf '%s\n' "$s" >>"$(conf_of "$T")"; done
    ;;
  create)
    T="${IMAGE:?}"
    echo "BC create $T" >>"$SB/log/calls"
    mkdir -p "$CONF"
    : >"$(conf_of "$T")"
    ;;
  config)
    T="${IMAGE:-}"
    if [ "${#sets[@]}" -gt 0 ]; then
      k="${sets[0]%% *}"; v="${sets[0]#* }"
      echo "BC config $T $k $v" >>"$SB/log/calls"
      mkdir -p "$CONF"
      printf '%s %s\n' "$k" "$v" >>"$(conf_of "$T")"
    fi
    ;;
  *) echo "stub: unknown command $cmd" >&2; exit 2 ;;
esac
EOF
  chmod +x "$SB/bin"/*
}

# Run the SHIPPED hook against the sandbox.
run() { # [KEY=VAL ...]  -- leading assignments are passed to the hook, as in test-publish-bundle.sh
  local env_extra=()
  while [ $# -gt 0 ] && [[ $1 == *=* ]]; do env_extra+=("$1"); shift; done
  [ -n "$RAUC_SLOTS" ] && env_extra+=(RAUC_TARGET_SLOTS="$RAUC_SLOTS")
  OUT=$(env PATH="$SB/bin:$PATH" SB="$SB" \
            ESP="$SB/esp" EFI="$SB/efi" MNT="$SB/mnt" EFIMNT="$SB/efimnt" VAR="$SB/var" \
            DEVDIR="$SB/dev" DEVTEST=-e BC="$SB/bin/steamos-bootconf" \
            "${env_extra[@]}" bash "$HOOK" 2>&1)
  RC=$?
  return 0
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

# Contents of the target slot's filesystems, i.e. what the updated slot will actually boot with.
tvar() { printf '%s' "$SB/fs/novadeck-var-$1"; }
tefi() { printf '%s' "$SB/fs/novadeck-efi-$1"; }
expect_file() {  # <path> <content>
  [ -f "$1" ] || { bad "missing on the target: ${1#"$SB/fs/"}"; return; }
  local got; got=$(cat "$1")
  [ "$got" = "$2" ] && ok "${1#"$SB/fs/"} = '$2'" || bad "${1#"$SB/fs/"}: expected '$2', got '$got'"
}
expect_absent() {
  [ -e "$1" ] && bad "must not exist on the target: ${1#"$SB/fs/"}" || ok "absent: ${1#"$SB/fs/"}"
}
expect_esp() {  # <name> <content>
  [ -f "$SB/esp/$1" ] || { bad "no /$1 on the ESP"; return; }
  local got; got=$(cat "$SB/esp/$1")
  [ "$got" = "$2" ] && ok "/$1 = '$2'" || bad "/$1: expected '$2', got '$got'"
}
expect_conf() {  # <content>
  grep -q -- "$1" "$SB/esp/SteamOS/conf/B.conf" && ok "B.conf $1" \
    || bad "B.conf has no '$1' (contents: $(tr '\n' ';' <"$SB/esp/SteamOS/conf/B.conf" 2>/dev/null))"
}

echo "== which slot: bootconf decides, RAUC only gets to disagree =="

t "the-target-is-the-slot-we-did-not-boot"
run
expect_rc 0
expect_has "target slot B"
expect_call 'btrfstune .*novadeck-root-B'
expect_call 'btrfs filesystem label .*novadeck-root-B novadeck-root-B'
expect_call 'mkfs.ext4 .*novadeck-var-B'
done_

t "booting-b-targets-a"
set_efi B
run
expect_rc 0
expect_has "target slot A"
expect_call 'btrfstune .*novadeck-root-A'
expect_call 'btrfs filesystem label .*novadeck-root-A novadeck-root-A'
expect_call 'mkfs.ext4 .*novadeck-var-A'
done_

t "the-running-slot-is-never-touched"
# The failure this rules out is unrecoverable and silent: mkfs on the RUNNING /var. Nothing else in
# the suite would notice, because every other assertion is about the target.
run
expect_rc 0
expect_no_call 'novadeck-var-A'
expect_no_call 'novadeck-root-A'
expect_no_call 'novadeck-efi-A'
done_

t "rauc-disagreeing-is-fatal"
RAUC_SLOTS="rootfs.0"          # RAUC says it wrote a; we booted a, so the target must be b
run
expect_rc 1
expect_has "refusing"
expect_no_call 'mkfs.ext4'
expect_no_call 'btrfstune'
expect_no_call 'BC set-mode'   # it dies before the disarm, so RAUC's own arming is left intact
done_

t "rauc-agreeing-proceeds"
RAUC_SLOTS="rootfs.1"
run
expect_rc 0
expect_call 'mkfs.ext4 .*novadeck-var-B'
done_

t "an-unrecognised-rauc-slot-name-is-not-a-veto"
# The cross-check is RAUC's value against ours, and ours is authoritative. A name we cannot map is
# no evidence of disagreement, so it must not block an install.
RAUC_SLOTS="rootfs.9"
run
expect_rc 0
expect_call 'mkfs.ext4 .*novadeck-var-B'
done_

t "a-boot-that-resolved-no-slot-is-refused"
# this-image answering dev is the cmdline-fallback boot. There is no safe guess here: picking wrong
# reformats the running system's /var.
printf 'dev\n' >"$SB/efi/SteamOS/partsets/self"
run
expect_rc 1
expect_has "no counterpart slot"
expect_no_call 'mkfs.ext4'
done_

t "a-missing-partset-is-refused"
# No partsets/self on the running efi means bootconf cannot say which image is booting.
rm -f "$SB/efi/SteamOS/partsets/self"
run
expect_rc 1
expect_has "cannot identify the booted image"
expect_no_call 'mkfs.ext4'
done_

t "a-missing-slot-device-is-refused-before-anything-is-touched"
rm -f "$SB/dev/novadeck-var-B"
run
expect_rc 1
expect_has "no block device"
expect_no_call 'mkfs.ext4'
expect_no_call 'btrfstune'
expect_no_call 'BC set-mode'   # the device checks run before the disarm too
done_

echo "== order: every step of the header, as an assertion =="

t "the-fsid-is-randomised-before-anything-mounts-the-target"
# Step 1 exists because until btrfstune has run the target and the running root share an fsid AND
# devid=1, and mounting the target can hand you the running root. Every later step mounts it.
run
expect_rc 0
expect_order 'btrfstune' 'mount -o ro'
expect_call 'btrfstune -f -U'
done_

t "the-slot-is-disarmed-before-the-work-and-re-armed-after"
run
expect_rc 0
expect_order 'BC set-mode A reboot' 'btrfstune'       # step 0 takes RAUC's arming back
expect_order 'BC config B image-invalid 0' 'BC set-mode B reboot'   # ...and only re-arms at the end
done_

t "var-is-reformatted-before-it-is-copied-into"
run
expect_rc 0
expect_order 'mkfs.ext4' 'rsync'
expect_order 'mkfs.ext4' "mount $SB/dev/novadeck-var-B"
done_

t "the-target-var-is-unmounted-before-the-root-is-mounted"
run
expect_rc 0
expect_order "umount $SB/mnt" 'mount -o ro'
done_

echo "== /var: wholesale, minus two files named in writing =="

t "the-copy-is-wholesale"
# A whitelist has to be extended for every new piece of per-device state, and forgetting one fails
# silently on a device with no serial console. SSH host keys were the next instance after
# machine-id; there would have been another.
run
expect_rc 0
expect_file "$(tvar B)/lib/overlays/etc/upper/machine-id" '7070e56b'
expect_file "$(tvar B)/lib/overlays/etc/upper/ssh_host_ed25519_key" 'ssh-ed25519'
expect_file "$(tvar B)/lib/systemd/random-seed" 'seed'
done_

t "the-saved-wifi-rides-across"
# DONE.md rates this brick-class on a RELEASE image: the NetworkManager connections live in the
# /etc overlay's upper dir, which lives in the PER-SLOT /var. A target slot without them boots a
# Wi-Fi-only, headless, serial-console-less device with no network and no way back in.
run
expect_rc 0
expect_file "$(tvar B)/lib/overlays/etc/upper/NetworkManager/system-connections/home.nmconnection" '[wifi]'
done_

t "the-copy-asks-for-the-flags-that-make-it-safe"
# A stub cannot prove real rsync honours these; it can prove we never quietly stop asking.
run
expect_rc 0
expect_call 'rsync -aHAX --numeric-ids --one-file-system'
done_

t "the-reformat-drops-the-previous-installs-state"
run
expect_rc 0
expect_absent "$(tvar B)/lib/novadeck/leftover-from-the-last-install"
expect_call 'mkfs.ext4 .*-L novadeck-var-B'
done_

t "the-slot-witness-is-rewritten-to-the-target"
# /var/lib/novadeck/slot records which image this slot is, in the bootconf naming (A/B). Copied
# verbatim it would make the target agree with a lie, and it must therefore be written AFTER the
# wholesale copy, not before. The copy brought slot=a; the witness must be B.
run
expect_rc 0
expect_file "$(tvar B)/lib/novadeck/slot" 'B'
done_

t "the-mac-seed-does-not-survive-the-copy"
# Write-once and outranks the derivation, so a unit flashed before the MAC-collision fix keeps a
# colliding address forever unless an update clears it. Deleting it re-derives from the machine-id
# the copy just carried over — same id, same MAC, so a healthy device sees no change.
run
expect_rc 0
expect_absent "$(tvar B)/lib/novadeck/mac-wifi"
expect_file "$(tvar B)/lib/overlays/etc/upper/machine-id" '7070e56b'
done_

t "the-overlay-dirs-exist-even-if-the-copy-did-not-bring-them"
# The one case that would be unrecoverable: the initramfs mounts /etc from these, so a slot without
# them does not come up at all.
rm -rf "$SB/var/lib/overlays"
run
expect_rc 0
[ -d "$(tvar B)/lib/overlays/etc/upper" ] && ok "upper/ created" || bad "no overlay upper/ on the target"
[ -d "$(tvar B)/lib/overlays/etc/work" ]  && ok "work/ created"  || bad "no overlay work/ on the target"
done_

echo "== stage 2 + partsets + the shared ESP =="

t "the-stage-2-comes-out-of-the-new-root"
# Not out of the bundle: grubaa64.efi and grub-<slot>.cfg are boot software owned by the same build
# that ships /boot/Image and /lib/modules/<ver> inside the rootfs, so taking them from the root
# makes the pairing true by construction. The target efi started with stale OLD-EFI-GRUB content.
run
expect_rc 0
expect_call 'mount -o ro .*novadeck-root-B'
expect_file "$(tefi B)/EFI/steamos/grubaa64.efi" 'GRUB-B'
expect_file "$(tefi B)/EFI/steamos/grub.cfg" 'CFG-B'
expect_file "$(tefi B)/EFI/steamos/fonts/dejavu-mono.pf2" 'FONT-B'
done_

t "the-partsets-are-refreshed-with-self-pointing-at-the-target"
# all/shared/A/B are disk-derived and identical on both efi partitions; only self/other re-point,
# so steamcl identifies this partition as its own image.
run
expect_rc 0
expect_file "$(tefi B)/SteamOS/partsets/all"     'partset-all'
expect_file "$(tefi B)/SteamOS/partsets/shared"  'partset-shared'
expect_file "$(tefi B)/SteamOS/partsets/A"       'partset-A'
expect_file "$(tefi B)/SteamOS/partsets/B"       'partset-B'
expect_file "$(tefi B)/SteamOS/partsets/self"    'partset-B'
expect_file "$(tefi B)/SteamOS/partsets/other"   'partset-A'
expect_file "$(tefi B)/SteamOS/partsets/dev"     'partset-dev'
done_

t "a-partset-copy-failing-is-fatal"
# this-image still worked (partsets/self exists), but the refresh cannot be completed.
rm -f "$SB/efi/SteamOS/partsets/all"
run
expect_rc 1
expect_has "cannot copy"
done_

t "the-steamcl-on-the-shared-esp-is-refreshed"
# ABL chainloads /EFI/BOOT/bootaa64.efi, so that is the copy that matters. Companion files
# in /EFI/BOOT/ are resolved by steamcl's resolve_path() relative to the chainloader.
# Content-identical when unchanged — skip rather than rewrite.
run
expect_rc 0
expect_esp EFI/BOOT/bootaa64.efi 'STEAMCL-B'
expect_esp EFI/BOOT/steamcl-version '1.B'
expect_esp EFI/BOOT/fonts/default.pf2 'FONT-B'
# steamcl-restricted is an empty flag file; just ensure it exists (not asserted by content)
done_

t "a-missing-hasher-dies-before-anything-destructive"
# The preflight exists because the two ways of losing the comparator fail in OPPOSITE directions and
# only one of them is survivable. A missing `cmp` (what shipped until 2026-08-05) exits non-zero, so
# the guard degrades to always-copy: wasteful, but the bytes end up right. A missing hasher inside
# $(...) yields two EMPTY strings that compare equal, so the ESP is never refreshed at all and a new
# root boots against the old steamcl. That one is silent and wrong, hence a hard assertion.
#
# It has to fire before step 0. By the use site in step 3 the target's fsid is randomised and its
# /var reformatted, so dying there leaves an unbootable slot and a run that cannot simply be redone.
run SHA256=novadeck-no-such-hasher
expect_rc 1
expect_has "novadeck-no-such-hasher is missing"
expect_no_call 'btrfstune'              # step 1 -- nothing may have been touched
expect_no_call 'mkfs.ext4'              # step 2
expect_no_call 'BC set-mode B reboot'   # step 4 -- and nothing armed
expect_esp EFI/BOOT/bootaa64.efi 'OLD-STEAMCL'
done_

t "identical-esp-boot-files-are-left-untouched"
# The skip is not an optimisation. The shared ESP is the only write in the whole update with no A/B
# copy behind it, so every needless rewrite of the file ABL chainloads is a power-cut window with
# nothing to roll back to. Seed the ESP with content already identical to the new root's and assert
# the file is NOT rewritten -- by mtime, because `cp -f` truncates in place and keeps the inode.
#
# WHY THIS CASE EXISTS: the comparison was `cmp -s` from 58e48a8 until 2026-08-05, and cmp is
# diffutils, which is not in PKGS and has never been on the image. On hardware it was "command not
# found" -- a non-zero exit, indistinguishable from "the files differ" -- so the skip never once
# happened in three releases and every OTA rewrote all three files. run() appends the HOST's PATH
# after $SB/bin and the host has diffutils, which is precisely why a suite asserting only content
# could not see it. Assert the skip itself, not the bytes.
printf 'STEAMCL-B\n' >"$SB/esp/EFI/BOOT/bootaa64.efi"
touch -d '2001-01-01 00:00:00' "$SB/esp/EFI/BOOT/bootaa64.efi"
before=$(stat -c %Y "$SB/esp/EFI/BOOT/bootaa64.efi")
run
expect_rc 0
after=$(stat -c %Y "$SB/esp/EFI/BOOT/bootaa64.efi")
[ "$before" = "$after" ] && ok "bootaa64.efi was not rewritten" \
  || bad "bootaa64.efi was rewritten despite identical content"
expect_esp EFI/BOOT/bootaa64.efi 'STEAMCL-B'
# The companions genuinely changed, so the same run must still refresh them -- a skip that skips
# everything would pass the assertion above and be just as wrong.
expect_esp EFI/BOOT/steamcl-version '1.B'
expect_esp EFI/BOOT/fonts/default.pf2 'FONT-B'
done_

t "an-esp-that-is-not-mounted-is-fatal"
: >"$SB/fail-esp"
run
expect_rc 1
expect_has "ESP is not mounted"
expect_no_call 'BC config B'         # nothing after step 3 may have run
expect_no_call 'BC set-mode B reboot'
expect_esp EFI/BOOT/bootaa64.efi 'OLD-STEAMCL'
done_

t "a-root-with-no-stage-2-is-fatal-and-leaves-the-esp-alone"
rm -f "$SB/fs/novadeck-root-B/usr/lib/novadeck/boot/grubaa64.efi"
run
expect_rc 1
expect_has "carries no stage-2 GRUB"
expect_no_call 'BC set-mode B reboot'
expect_esp EFI/BOOT/bootaa64.efi 'OLD-STEAMCL'
done_

echo "== the end state, and every way of not reaching it =="

t "a-completed-run-ends-armed-and-unmarked"
# RAUC marked the target bad pre-write (simulated: nothing writes image-invalid here), and only a
# COMPLETED install may take that back -- step 4 is the only place that knows it completed.
run
expect_rc 0
expect_conf 'image-invalid 0'
expect_call 'BC set-mode B reboot'
expect_has "re-armed for a trial boot"
done_

t "a-missing-target-conf-is-created"
# A handler that ran outside RAUC may be the first writer of the target's conf.
rm -f "$SB/esp/SteamOS/conf/B.conf"
run
expect_rc 0
expect_call 'BC create B'
[ -f "$SB/esp/SteamOS/conf/B.conf" ] && ok "B.conf created" || bad "B.conf was not created"
done_

t "an-existing-target-conf-is-not-recreated"
printf 'title: B\nimage-invalid 1\n' >"$SB/esp/SteamOS/conf/B.conf"
run
expect_rc 0
expect_no_call 'BC create B'
grep -q 'title: B' "$SB/esp/SteamOS/conf/B.conf" && ok "title survived" || bad "title was lost"
done_

t "a-failure-at-the-fsid-leaves-nothing-armed"
# The whole point of the disarm. RAUC armed the slot before calling us; between step 0 and the last
# line the target has a freshly mkfs'd /var and no stage 2, so a state pointing at it boots
# nothing. The failure mode has to be "the install failed, run it again", not "one bad boot, hope
# the failsafe fires".
: >"$SB/fail-btrfstune"
run
expect_rc 1
expect_has "fsid"
expect_no_call 'mkfs.ext4'
expect_no_call 'BC set-mode B reboot'
done_

t "a-failure-during-the-copy-leaves-nothing-armed"
: >"$SB/fail-rsync"
run
expect_rc 1
expect_no_call 'BC set-mode B reboot'
expect_esp EFI/BOOT/bootaa64.efi 'OLD-STEAMCL'
done_

t "an-interrupted-install-still-answers-bad-afterwards"
# The other half of the design: the mark RAUC wrote before the install stays, because nothing but a
# COMPLETED install clears it. A half-written slot must not answer good.
printf 'image-invalid 1\n' >"$SB/esp/SteamOS/conf/B.conf"
: >"$SB/fail-rsync"
run
expect_rc 1
grep -q 'image-invalid 1' "$SB/esp/SteamOS/conf/B.conf" && ok "still marked bad" \
  || bad "the pre-write marking was lost"
grep -q 'image-invalid 0' "$SB/esp/SteamOS/conf/B.conf" \
  && bad "a failed install cleared the marking" || ok "never cleared"
done_

t "the-disarm-failing-stops-the-install-before-it-starts"
# If we cannot take RAUC's arming back we cannot make the window safe, and proceeding would spend
# the safety net on a failure we chose to create. The booted image's conf is gone, so bootconf
# refuses the disarm.
rm -f "$SB/esp/SteamOS/conf/A.conf"
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
