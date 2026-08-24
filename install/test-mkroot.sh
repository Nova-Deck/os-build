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

CASE="firmware: the same two trees the card gets"
# HW-FOUND 2026-08-24: the first medium had a 16 KB /usr/lib/firmware and NO Wi-Fi. pkgs.list has no
# `linux-firmware`; the shipped image gets firmware from two staging trees that only
# images/assemble-rootfs.sh installs from, and this image never runs it. It read as a hostname or
# DHCP problem and was neither — there was no wlan interface at all.
#
# WHOLESALE, NOT CURATED. The first fix shipped a hand-written list carrying ath12k, because the
# board on the bench was an SM8650 — the SM8250 machines use a QCA6390 on ath11k and would have hit
# the identical invisible failure. A list enumerating every radio across a growing fleet goes stale
# silently, on the tool you reach for when a device is already broken. So these cases assert that
# NOTHING is being selected.
[ -e "$ROOT/install/firmware.list" ] \
  && bad "a curated firmware list is back — it will go stale per-board, as it already did once" \
  || ok "no curated firmware list; both trees are taken whole"
grep -q '/fw-qcom:ro' "$MKROOT" && grep -q '/fw-linux:ro' "$MKROOT" \
  && ok "both staging trees are mounted into the bootstrap" \
  || bad "a firmware tree is not mounted — the medium ships without it"
grep -qE 'cp -a "\$src/\." /target/usr/lib/firmware/' "$MKROOT" \
  && ok "each tree is copied whole, with no filter" \
  || bad "firmware is filtered on the way in — that is the curation this replaced"
grep -q 'make fw-qcom' "$MKROOT" && grep -q 'make fw-linux' "$MKROOT" \
  && ok "a missing tree fails the build naming the target that fetches it" \
  || bad "a missing firmware tree would produce a silently radio-less medium"
# The bookkeeping files describe the staging trees, not the device; they must not land in /lib/firmware.
grep -q 'rm -f /target/usr/lib/firmware/sha256sums.txt' "$MKROOT" \
  && ok "the staging bookkeeping files are removed from the image" \
  || bad "sha256sums.txt/.fetched.stamp would ship inside /usr/lib/firmware"
grep -q 'kernel/embed.list' "$MKROOT" \
  && ok "it records why the GPU worked without any of this (those blobs are in the kernel)" \
  || bad "the embed.list relationship is undocumented — the next reader repeats the diagnosis"

CASE="InputPlumber board configs"
# HW-FOUND the same boot: the UI drew and stopped on §4d's "No controller or keyboard". The prebuilt
# tarball ships the daemon and its generic configs; the per-board MCU gamepad definitions are OURS
# and live in the overlay. Without them nothing recognises the pad and the stop fires correctly.
grep -q 'fs-overlay/etc/inputplumber' "$MKROOT" \
  && ok "the board configs are staged from the overlay" \
  || bad "no InputPlumber board configs — the UI stops on 'No controller or keyboard'"
for d in capability_maps.d devices.d; do
  n=$(ls "$ROOT/fs-overlay/etc/inputplumber/$d"/*.yaml 2>/dev/null | wc -l)
  [ "$n" -gt 0 ] && ok "$d has $n configs to ship" || bad "$d is empty in the overlay"
done
grep -q 'etc/inputplumber' "$MKROOT" \
  && ok "they land at /etc/inputplumber on the medium" \
  || bad "the configs are staged but never installed"

CASE="remote access is TEST-ONLY"
# The same split [[wifi-config-is-test-only]] draws for the shipped image. A published recovery
# medium anyone can download must not carry a credential anyone can extract, so the release
# installer leaves sshd installed and never enabled — it listens on nothing.
grep -q 'authorized_keys' "$MKROOT" && ok "a dev build can bake an authorized_keys" \
  || bad "no dev credential path at all — an early failure would be undiagnosable"
grep -q 'if \[ -f /prebuilt/authorized_keys \]' "$MKROOT" \
  && ok "sshd is enabled ONLY when that key was staged (i.e. NOVADECK_DEV=1)" \
  || bad "sshd enablement is not gated on the dev credential"
# The host key must not be in /etc: that is squashfs here, so openssh's own sshdgenkeys would fail
# every boot and sshd, which only Wants= it, would start with no key and refuse every connection.
grep -q 'HostKey /run/ssh/ssh_host_ed25519_key' "$MKROOT" \
  && ok "the host key lives in /run, not the read-only /etc" \
  || bad "the host key would be written to a read-only /etc"
# The generator is a COMMITTED unit, so images/test-units.sh lints it with systemd-analyze — a unit
# printf-ed from inside mkroot.sh's container half would be linted by nothing, and systemd IGNORES
# a misspelled directive silently ([[systemd-execonfailure-is-not-a-directive]]).
HOSTKEY_UNIT="$UNITS/novadeck-installer-hostkey.service"
[ -f "$HOSTKEY_UNIT" ] && ok "the key generator is a committed unit file, so it gets linted" \
  || bad "no install/units/novadeck-installer-hostkey.service — a generated unit is an unlinted one"
grep -q 'ConditionPathExists=!/run/ssh/ssh_host_ed25519_key' "$HOSTKEY_UNIT" 2>/dev/null \
  && ok "regeneration is conditional (ssh-keygen prompts rather than overwriting)" \
  || bad "an sshd restart within a boot would wedge on the key generator"
# ...and it must NOT be installed by the unconditional units glob, or it lands on release media too.
# Narrowly the INSTALL command, not the staging copy: staging every unit into /prebuilt is fine and
# expected, and an earlier version of this case matched that line and failed on correct code.
grep -q 'install -m0644 /prebuilt/units/\*\.service' "$MKROOT" \
  && bad "units are installed by glob — the TEST-BUILD hostkey unit would ship on a released medium" \
  || ok "units are installed by name, so the test-build unit stays out of release media"
grep -q 'sshdgenkeys.service' "$MKROOT" \
  && ok "openssh's own generator is masked rather than left failing" \
  || bad "sshdgenkeys would fail on /etc and litter the one journal that is the whole diagnostic"
# A baked host key is a property of the BUILD: extractable from the published image and identical
# on every device flashed from it. The main image argues this at length; the conclusion holds here.
grep -qE 'ssh-keygen[^\n]*-f /target/etc/ssh' "$MKROOT" \
  && bad "a host key is baked into the image — every medium would share one private key" \
  || ok "no host key is baked into the image"

CASE="the TEST-ONLY Wi-Fi profile"
# It is what makes the sshd above worth having: joining otherwise happens through the UI's network
# screen, so on the one failure this medium exists to diagnose — a dead GUI — there is no way to
# drive the join, and therefore no network and no shell.
grep -q 'NOVADECK_WIFI_SSID' "$MKROOT" && ok "a dev build can bake a Wi-Fi profile" \
  || bad "no Wi-Fi injection — a dead GUI means no network and no way in"
# /etc is the WRONG place here and it fails silently: keyfile `path=` is redirected to /run so nmcli
# can write on a read-only root, and `path=` is the one directory NM both reads and writes.
grep -q 'usr/lib/NetworkManager/system-connections' "$MKROOT" \
  && ok "the profile goes in /usr/lib (a read-only source NM reads whatever path= says)" \
  || bad "the profile is not in /usr/lib — with path= redirected to /run it would never be read"
grep -qE 'install -m0600 /prebuilt/wifi.nmconnection' "$MKROOT" \
  && ok "installed 0600 (NM ignores a profile with looser permissions)" \
  || bad "the profile is not 0600 — NM logs 'ignoring due to permissions' and moves on"
# The PSK crosses as a FILE. Interpolated into the container's single-quoted bash -c, a quote in a
# passphrase would end the string; and a file keeps it off any process command line.
grep -q 'STAGE/wifi.nmconnection' "$MKROOT" \
  && ok "the PSK crosses as a file, not interpolated into the container script" \
  || bad "the PSK is interpolated somewhere — a quote in a passphrase would break the build"
# The reuse marker is INSTALLED INTO THE IMAGE as /usr/lib/novadeck/pkgs, so a plaintext credential
# in the cache key would ship on the medium.
grep -qE '^wifi:\$\(printf .* \| sha256sum' "$MKROOT" \
  && ok "credentials are hashed into the reuse key, never written to it" \
  || bad "the reuse key may carry a plaintext PSK, and that marker ships inside the image"
grep -q 'NOVADECK_WIFI=1 requires' "$MKROOT" \
  && ok "NOVADECK_WIFI=1 without creds is a hard error, not a quiet skip" \
  || bad "an explicit Wi-Fi request can be silently ignored"

CASE="a read-only /etc, and its three writers"
# The root is squashfs with NO overlay (the shipped image's overlay is what forces an initramfs,
# and it exists to persist a user's config — neither applies to a tool that runs once from
# removable media). That trade is only safe while the writers stay enumerated, so each is asserted
# here and the payload is scanned for new ones below.
grep -q ':.*>/target/etc/machine-id' "$MKROOT" \
  && ok "an empty /etc/machine-id exists (systemd bind-mounts a transient one over it on ro root)" \
  || bad "no /etc/machine-id is created — PID1 fails early on a read-only root without it"
grep -q 'path=/run/NetworkManager/system-connections' "$MKROOT" \
  && ok "NM keyfile profiles are redirected to tmpfs (nmcli would write /etc otherwise)" \
  || bad "NM would write profiles into a read-only /etc — install/netcfg fails"
grep -q 'rc-manager=unmanaged' "$MKROOT" \
  && ok "NM is told not to rewrite /etc/resolv.conf" \
  || bad "NM would try to replace the resolv.conf symlink and log a failure every connect"
grep -q 'ln -sf /run/NetworkManager/resolv.conf /target/etc/resolv.conf' "$MKROOT" \
  && ok "/etc/resolv.conf points into /run, where NM does maintain one" \
  || bad "no resolv.conf symlink — name resolution would not work"

# THE DRIFT GUARD. A component that starts writing to /etc fails on the device, at whatever step
# happens to reach it, with an error about the file rather than about the root being read-only.
# Comments are excluded: rauc-session.sh discusses /etc/rauc/system.conf at length without touching it.
writers="$(grep -nE '(>|>>|install -|cp |mv |tee |mkdir -p|touch|ln -s)[^|#]*/etc/' \
             "${FLAT[@]/#/$ROOT/install/}" 2>/dev/null || true)"
[ -z "$writers" ] \
  && ok "no shipped component writes under /etc" \
  || bad "a shipped component writes under /etc, which is read-only here: $(printf '%s' "$writers" | head -3 | tr '\n' ' ')"

# /var is the other half and is handled on the cmdline, not here — assert the two stay paired, since
# a squashfs root with a writable /etc plan and no /var plan still cannot run journald or NM.
grep -q 'systemd.volatile=state' "$ROOT/install/gen-grub-cfg.sh" \
  && ok "/var is a tmpfs via systemd.volatile=state on the kernel line" \
  || bad "nothing makes /var writable — journald and NM state have nowhere to go"

printf '\ntest-mkroot.sh: %d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
