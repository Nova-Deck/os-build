#!/usr/bin/env bash
# Offline tests for the INSTALLER image's declarations — Phase 6 of
# .claude/plans/internal-install.plan.md.
#
#   install/test-mkroot.sh
#
# Everything runs on the host with no root, no docker, no network and no built tree. Run via
# `make test`.
#
# WHAT IS ACTUALLY AT RISK HERE, and it is not shell correctness. Building the installer root costs
# an emulated pacstrap, so nothing in `make test` can build one — which means every failure this
# suite does not catch is a failure discovered twenty minutes in, or worse, on a device holding a
# stranger's data. The three shapes it guards:
#
#   1. THE DECLARATION LOSING A TOOL. install/pkgs.list names four packages that are in NONE of
#      images/manifest.lock's rows because they ship on no device — and one of them, mtools, has
#      already cost this project a hardware slot: without `mdir`, select-target.sh's rule 3b could
#      not read a foreign ESP, so it failed OPEN and offered to carve a Pocket FIT that was running
#      ROCKNIX (2026-08-21). `dosfstools` looks like it covers mtools and does not: it ships
#      mkfs.vfat, never mdir. [[offline-suite-inherits-host-path]].
#   2. THE FILE LISTS DRIFTING FROM THE TREE. install/mkroot.sh names every file it places, one by
#      one, rather than globbing — deliberately, since install/ also holds the hw-* stagers, the
#      suites and a __pycache__. The cost of that choice is a list that can go stale when a file is
#      renamed, and a renamed UI module is an installer that dies on import with the panel already
#      black. So the lists are read back OUT of the script and checked against the tree.
#   3. THE apostrophe TRAP. The bootstrap's container half is one single-quoted `bash -c` string.
#      A bare apostrophe anywhere in it — in a comment, in prose — closes that string and leaks the
#      remainder to the HOST shell, which then runs a fragment of an image build as the build user.
#      images/customize-base.sh carries the same hazard and the same warning.
#
# It also asserts what the installer must NOT be. The whole risk in a second image is that it drifts
# towards the first one, and drift arrives as an innocuous-looking line in a package list.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKGSLIST="$ROOT/install/pkgs.list"
MKROOT="$ROOT/install/mkroot.sh"
GENLOCK="$ROOT/install/genlock.sh"
OSREL="$ROOT/install/os-release"
UNITS="$ROOT/install/units"

PASS=0; FAIL=0; SKIP=0; CASE=""
ok()   { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }
skip() { SKIP=$((SKIP+1)); printf '  skip %s -- %s\n' "$CASE" "$1"; }

for f in "$PKGSLIST" "$MKROOT" "$GENLOCK" "$OSREL"; do
  [ -e "$f" ] || { echo "missing input: $f" >&2; exit 1; }
done

# The declaration, parsed exactly as mkroot.sh parses it — same sed, same grep. A test that parsed
# it its own way would pass on a list the builder reads differently.
mapfile -t PKGS < <(sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$PKGSLIST" | grep -v '^$')
has_pkg() { printf '%s\n' "${PKGS[@]}" | grep -qx "$1"; }

# ---------------------------------------------------------------------------------------------
CASE="pkgs.list"
[ "${#PKGS[@]}" -gt 0 ] && ok "parses to ${#PKGS[@]} package names" \
  || bad "parses to nothing — mkroot.sh would refuse"

# A name with whitespace in it means a comment stripper missed something, and pacman would be
# handed a phrase. Cheap to assert, and it is the failure that turns a doc edit into a build break.
strayed=""
for p in "${PKGS[@]}"; do
  case "$p" in *[[:space:]]*|'#'*) strayed="$strayed $p" ;; esac
done
[ -z "$strayed" ] && ok "every entry is a bare package name" \
  || bad "entries that are not bare names:$strayed"

has_pkg base && ok "declares the 'base' metapackage as the foundation" \
  || bad "no 'base' — the tree would have no systemd, no udev and no coreutils"

# ---------------------------------------------------------------------------------------------
# The four the SHIPPED image does not have. install/lib-hwstage.sh exists solely to stage these
# onto a dev card for the hardware gates; the installer image is where they are supposed to arrive
# as packages instead, and this is the only check standing between that intent and a silent hole.
CASE="the four tools no device carries"
for want in gptfdisk dosfstools mtools parted; do
  has_pkg "$want" && ok "declares $want" \
    || bad "$want is not declared — the spine's recon() would refuse at second zero"
done
# Named separately because the reasoning is the part worth keeping: a reader trimming this list
# will see dosfstools and mtools as redundant. They are not, and hardware has already said so.
has_pkg mtools \
  && ok "mtools is present alongside dosfstools (mdir is NOT in dosfstools; rule 3b reads with it)" \
  || bad "mtools missing — rule 3b fails OPEN on a foreign ESP, as it did on the Pocket FIT"

CASE="the rest of what recon() checks by name"
for want in e2fsprogs btrfs-progs rauc dbus glib2 curl zstd; do
  has_pkg "$want" && ok "declares $want" || bad "$want is not declared"
done

CASE="the Phase-5 display stack"
for want in gamescope seatd mesa vulkan-freedreno python; do
  has_pkg "$want" && ok "declares $want" || bad "$want is not declared"
done

# ---------------------------------------------------------------------------------------------
# The drift guard. Each of these has a specific reason to be absent, and each is the kind of line
# that looks harmless in a diff: an installer is not a device, and the moment it starts carrying a
# session, a login manager or a splash it stops being the thing that works when the device is broken.
CASE="what the installer must NOT be"
for unwanted in sddm plymouth steam fex-emu bluez pipewire mangohud noto-fonts scx-scheds; do
  has_pkg "$unwanted" \
    && bad "$unwanted is declared — the installer is drifting towards the shipped image" \
    || ok "no $unwanted"
done
# python-pygame and PySDL2 exist in NO holo repo (measured 2026-08-22 against the pinned builder).
# Declaring either resolves to nothing and the bootstrap dies deep inside an emulated container,
# twenty minutes in, with a message about a target not found.
for ghost in python-pygame python-pysdl2 sdl2; do
  has_pkg "$ghost" \
    && bad "$ghost is declared, and no holo repo has it — the SDL binding is install/pygame-ce.pin" \
    || ok "no $ghost (the binding is the pinned wheel)"
done

# ---------------------------------------------------------------------------------------------
# Prebuilt pins: every dependency a pin declares must be a leaf of the list. mkroot.sh asserts the
# same thing at build time; this is the copy that runs in `make test`, where a pin bump is reviewed.
CASE="prebuilt pins"
pin_field() { sed -n "s/^$2:[[:space:]]*//p" "$1" | head -1; }
for pin in "$ROOT/packages/inputplumber/prebuilt.pin" "$ROOT/install/pygame-ce.pin"; do
  rel="${pin#"$ROOT"/}"
  if [ ! -f "$pin" ]; then bad "$rel is missing — mkroot.sh names it explicitly"; continue; fi
  ok "$rel is present"
  [ -n "$(pin_field "$pin" sha256)" ] && ok "$rel carries a sha256" || bad "$rel has no sha256"
  for dep in $(pin_field "$pin" deps); do   # word-split: deps is space-separated
    has_pkg "$dep" && ok "$rel's dep '$dep' is declared" \
      || bad "$rel declares dep '$dep', which pkgs.list does not carry"
  done
done
# pygame-ce must stay OUT of packages/, or images/customize-base.sh's auto-discovery ships 39 MB of
# SDL bindings to every device. That is the whole reason the pin lives where it does.
[ -e "$ROOT/packages/pygame-ce" ] \
  && bad "packages/pygame-ce exists — customize-base.sh would ship the wheel to every device" \
  || ok "pygame-ce is outside packages/, so the release bootstrap cannot discover it"

# ---------------------------------------------------------------------------------------------
# The file lists, read back out of mkroot.sh. Extracting them from the script rather than
# re-declaring them here is the point: a second copy would drift in the same commit that broke the
# first, and agree with it.
CASE="the files mkroot.sh places"
mapfile -t FLAT < <(sed -n '/^INSTALL_FILES=(/,/^)/p' "$MKROOT" | sed -e '1d' -e '$d' -e 's/#.*//' | tr ' ' '\n' | grep -v '^$')
[ "${#FLAT[@]}" -ge 10 ] && ok "INSTALL_FILES parses to ${#FLAT[@]} entries" \
  || bad "INSTALL_FILES parsed to ${#FLAT[@]} entries — the extraction or the array shape changed"
for f in "${FLAT[@]}"; do
  [ -f "$ROOT/install/$f" ] && ok "install/$f exists" \
    || bad "mkroot.sh places install/$f, which is not in the tree"
done
# The four §5 model/view files and the spine specifically: they find each other by
# dirname(__file__) and $SELFDIR, so all of them or none of them.
for f in ui uipad.py uiflow.py uiview.py novadeck-install confirm-ui installer-session save-log.sh; do
  printf '%s\n' "${FLAT[@]}" | grep -qx "$f" && ok "$f travels with the image" \
    || bad "$f is NOT placed — it is resolved by dirname/SELFDIR and there is no fallback"
done
# ...and the ones that are build-host only. Shipping a stager onto the medium would put a
# sha256-pinned download path inside the tool, which is the opposite of what the medium is for.
for f in hw-install.sh hw-select-target.sh hw-preflight.sh lib-hwstage.sh lib-gptfixture.sh probe-internal.sh mkroot.sh genlock.sh; do
  printf '%s\n' "${FLAT[@]}" | grep -qx "$f" \
    && bad "$f is placed on the image — it is a BUILD HOST tool" \
    || ok "$f stays on the build host"
done

CASE="the files the spine resolves by search"
mapfile -t FOREIGN < <(sed -n '/^FOREIGN_FILES=(/,/^)/p' "$MKROOT" | sed -e '1d' -e '$d' | tr -d '"' | tr ' ' '\n' | grep -v '^$')
[ "${#FOREIGN[@]}" -eq 4 ] && ok "FOREIGN_FILES parses to 4 entries" \
  || bad "FOREIGN_FILES parsed to ${#FOREIGN[@]} entries, expected 4"
for spec in "${FOREIGN[@]}"; do
  [ -f "$ROOT/${spec%%:*}" ] && ok "${spec%%:*} exists" \
    || bad "mkroot.sh places ${spec%%:*}, which is not in the tree"
done

# ---------------------------------------------------------------------------------------------
CASE="units"
[ -f "$UNITS/novadeck-installer.service" ] && ok "the session unit exists" \
  || bad "no novadeck-installer.service"
[ -f "$UNITS/novadeck-installer-console.service" ] && ok "the fallback console unit exists" \
  || bad "no novadeck-installer-console.service"
# The console unit is started by OnFailure=. Enabling it would run the fallback on every boot —
# including the ones that worked — and the log tail on the panel would read as a failure.
grep -q 'multi-user.target.wants/novadeck-installer.service' "$MKROOT" \
  && ok "mkroot.sh enables the session unit" || bad "mkroot.sh does not enable the session unit"
grep -q 'multi-user.target.wants/novadeck-installer-console.service' "$MKROOT" \
  && bad "mkroot.sh ENABLES the fallback console — it is an OnFailure= target, not a boot unit" \
  || ok "the fallback console is not enabled (OnFailure= starts it)"

CASE="the consent gate's fixed path"
# $CONFIRM defaults to /usr/lib/novadeck/install/confirm and the symlink decides which renderer
# answers. On this image the UI already owns the panel and the pad, so a second SDL client would
# contend with it for gamescope focus — and that failure mode is a consent screen that never
# appears, which points nowhere near its cause.
grep -qE 'ln -sf +confirm-ui .*/install/confirm$' "$MKROOT" \
  && ok "confirm -> confirm-ui (the socket shim, not a second SDL client)" \
  || bad "the confirm symlink does not point at confirm-ui"

CASE="identity"
grep -q '^ID=novadeck-installer$' "$OSREL" && ok "ID=novadeck-installer" \
  || bad "install/os-release does not set ID=novadeck-installer"
# It must not answer the same ID as an install. The spine's own rules key off "is this disk ours",
# and a medium claiming to be novadeck is a device claiming to be the thing it is about to install.
grep -q '^ID=novadeck$' "$OSREL" \
  && bad "install/os-release claims ID=novadeck — that is the SHIPPED image's identity" \
  || ok "it does not claim the shipped image's identity"

# ---------------------------------------------------------------------------------------------
CASE="the bash -c trap"
# Extract the container half and prove two things about it: it holds no apostrophe (one would close
# the -c string and leak the rest to the host shell), and it parses as bash on its own.
inner="$(awk "/bash -euo pipefail -c '/{f=1;next} f&&/^' >&2\$/{f=0} f" "$MKROOT")"
[ -n "$inner" ] && ok "the container script was located ($(printf '%s\n' "$inner" | wc -l) lines)" \
  || bad "could not locate the container script — the extraction marker moved"
case "$inner" in
  *\'*) bad "the container script contains an apostrophe — it would leak to the HOST shell" ;;
  *)    ok "no apostrophe anywhere in the container script" ;;
esac
printf '%s\n' "$inner" | bash -n 2>/dev/null \
  && ok "the container script parses as bash" || bad "the container script does not parse"

CASE="host halves parse"
for s in "$MKROOT" "$GENLOCK" "$ROOT/images/fetchlock.sh"; do
  bash -n "$s" 2>/dev/null && ok "${s#"$ROOT"/} parses" || bad "${s#"$ROOT"/} does not parse"
done

CASE="the lock is a second artifact, not a fork of the first"
# fetchlock.sh must take the lock as an argument, or mkroot.sh silently materializes the SHIPPED
# image's lock into the installer root — which resolves, installs, and produces an image with no
# sgdisk on it.
grep -q 'LOCK="${2:-\$ROOT/images/manifest.lock}"' "$ROOT/images/fetchlock.sh" \
  && ok "fetchlock.sh takes the lock as an optional second argument" \
  || bad "fetchlock.sh has no lock argument — mkroot.sh cannot use it"
grep -q 'fetchlock.sh" "\$STAGE/install.list" "\$LOCKFILE"' "$MKROOT" \
  && ok "mkroot.sh passes install/manifest.lock, not the shipped one" \
  || bad "mkroot.sh does not pass its own lock to fetchlock.sh"

printf '\ntest-mkroot.sh: %d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
