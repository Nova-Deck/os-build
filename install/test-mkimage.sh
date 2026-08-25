#!/usr/bin/env bash
# Offline tests for the INSTALLER MEDIUM — Phase 6 of .claude/plans/internal-install.plan.md.
#
#   install/test-mkimage.sh
#
# Host-only: no docker, no root, no built tree, no network. Run via `make test`. Peer of
# install/test-mkroot.sh, which covers the ROOT; this covers what gets written around it — the
# two-partition table, the boot chain and the generated grub.cfg.
#
# THE ONE THAT EARNS ITS KEEP IS THE DTB PARITY CHECK. install/gen-grub-cfg.sh and
# boot/gen-grub-cfg.sh read the SAME board catalog (boot/boards.map) but emit different configs,
# and the derivation rule for a catalog-less .dts is subtle: the parent is found by stripping the
# literal `-top-dpad` suffix, not by dropping the last dash-segment, and the menu title comes from
# the .dts `model =` line. I hand-copied that wrong while writing the installer generator and it
# failed on the single board it exists for. A divergence that does NOT fail the build is worse: a
# board that boots from a card and not from the installer, found on hardware, on the tool you reach
# for when the device is already broken. So the two generators are required to name the same DTBs.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TABLE="$ROOT/install/medium-table.txt"
GENCFG="$ROOT/install/gen-grub-cfg.sh"
MKIMAGE="$ROOT/install/mkimage.sh"
SHIPPED_GENCFG="$ROOT/boot/gen-grub-cfg.sh"
DTS="$ROOT/kernel/dts/qcom"

PASS=0; FAIL=0; SKIP=0; CASE=""
ok()   { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }
skip() { SKIP=$((SKIP+1)); printf '  skip %s -- %s\n' "$CASE" "$1"; }

for f in "$TABLE" "$GENCFG" "$MKIMAGE" "$SHIPPED_GENCFG"; do
  [ -e "$f" ] || { echo "missing input: $f" >&2; exit 1; }
done
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

rows() { grep -vE '^[[:space:]]*(#|$)' "$TABLE"; }

# ---------------------------------------------------------------------------------------------
CASE="medium-table"
n=$(rows | wc -l)
[ "$n" -eq 2 ] && ok "declares exactly 2 partitions" \
  || bad "declares $n partitions — the medium has no slots and needs no more"

read -r _ esp_size esp_type esp_fs esp_label _ < <(rows | sed -n 1p)
read -r rt_name rt_size rt_type _ rt_label _ < <(rows | sed -n 2p)

# 0700, NOT ef00, and the reasoning is measured rather than assumed. An EFI System Partition is
# hidden from users by Windows and macOS, which makes this installer's own advice — "copy
# wifi.conf.example next to it on another computer" — impossible, and loses the install log on the
# way back out. ABL does not select by type: a working ROCKNIX card is MBR (`dos`) with a plain
# 0xc FAT32 partition carrying /EFI/BOOT/bootaa64.efi and no EFI System Partition anywhere
# (measured 2026-08-24). The loader is found by CONTENT.
[ "$esp_type" = 0700 ] && ok "p1 is 0700, so every OS shows it (ABL boots by content, not type)" \
  || bad "p1 type is $esp_type — an ef00 here is invisible on Windows/macOS, where wifi.conf is written"
[ "$esp_fs" = vfat ] && ok "p1 is vfat" || bad "p1 fs is $esp_fs"
[ "$rt_name" = root ] && ok "p2 is the root" || bad "p2 is named $rt_name"
[ "$rt_size" = rest ] && ok "p2 takes the rest of the medium" \
  || bad "p2 is fixed at $rt_size — the root is sized by what got built"

# 11 characters is all a FAT label has room for; a longer one is silently truncated by mkfs.vfat,
# and then nothing that searches for it finds it.
[ "${#esp_label}" -le 11 ] && ok "the ESP label fits FAT ($esp_label, ${#esp_label} chars)" \
  || bad "the ESP label $esp_label is ${#esp_label} chars — FAT holds 11"
# It must NOT be one of the install's own labels: a dev card and an internal install already share
# those, and an installer whose /esp matched the TARGET's would write its failure log onto the disk
# it just failed to install.
case "$esp_label" in
  [Nn][Oo][Vv][Aa][Dd][Ee][Cc][Kk]*) bad "the ESP label is a novadeck-* one — it would collide with the target" ;;
  *) ok "the ESP label does not collide with an install's labels" ;;
esac
grep -q 'NDINSTALLER' "$ROOT/install/mkroot.sh" \
  && ok "mkroot.sh's fstab entry names the same label" \
  || bad "mkroot.sh does not mention NDINSTALLER — /esp would never mount"

# ---------------------------------------------------------------------------------------------
CASE="grub.cfg"
UUID=deadbeef-0000-1111-2222-333344445555
if ! "$GENCFG" "$UUID" "$T/installer.cfg" >/dev/null 2>"$T/err"; then
  bad "the generator failed: $(head -1 "$T/err")"
else
  ok "generates against a partition uuid"
  cfg="$T/installer.cfg"
  entries=$(grep -c '^menuentry ' "$cfg")
  [ "$entries" -gt 0 ] && ok "emits $entries menuentries" || bad "emits no menuentries"

  # Every board gets a normal entry and a debug twin, so the count is even and the halves match.
  normal=$(grep -c "^menuentry .* --id [a-z0-9-]*[^g] {$" "$cfg")
  debug=$(grep -c -- '--id .*-debug {$' "$cfg")
  [ "$debug" -gt 0 ] && ok "$debug debug-console entries" || bad "no debug entries"
  [ $((entries % 2)) -eq 0 ] && [ "$debug" -eq $((entries / 2)) ] \
    && ok "every board has exactly one debug twin" \
    || bad "$entries entries but $debug debug ones — the halves do not match"

  # The debug arg is what hands the panel to a getty instead of gamescope. It must be on the debug
  # entries and on NOTHING else, or every boot skips the GUI.
  d_with=$(grep -c 'novadeck.install.debug' "$cfg")
  [ "$d_with" -eq "$debug" ] \
    && ok "novadeck.install.debug appears on exactly the debug entries" \
    || bad "$d_with lines carry novadeck.install.debug but there are $debug debug entries"

  for want in "rootfstype=squashfs" "systemd.volatile=state" "root=PARTUUID=$UUID" "rootwait" " ro "; do
    grep -q -- "$want" "$cfg" && ok "the kernel line carries '$want'" \
      || bad "the kernel line is missing '$want'"
  done
  # Slot machinery must NOT leak in from the shipped generator: there is one root here, and a
  # novadeck.slot= on the cmdline would have the OS looking for a slot that does not exist.
  for unwanted in "novadeck.slot=" "novadeck.var=" "novadeck.efi=" "rootfstype=btrfs" "slotroot"; do
    grep -q -- "$unwanted" "$cfg" \
      && bad "the config carries '$unwanted' — that is slot machinery, and this medium has no slots" \
      || ok "no '$unwanted'"
  done
  # Boot-attempt counting demotes a slot that cannot boot. There is nothing to demote to here, so
  # it could only ever stop the recovery medium from starting.
  grep -q 'novadeck_bootattempts' "$cfg" \
    && bad "the config counts boot attempts — the medium would refuse itself" \
    || ok "no boot-attempt counting"

  # rotation is read ONCE, when the video driver builds the render target. Set after
  # terminal_output it is a silent no-op and the menu paints sideways on every board.
  rot=$(grep -n '^set rotation=' "$cfg" | head -1 | cut -d: -f1)
  tout=$(grep -n '^terminal_output gfxterm' "$cfg" | head -1 | cut -d: -f1)
  if [ -n "$rot" ] && [ -n "$tout" ] && [ "$rot" -lt "$tout" ]; then
    ok "rotation is set before terminal_output (line $rot < $tout)"
  else
    bad "rotation must be set BEFORE terminal_output (rotation=$rot terminal_output=$tout)"
  fi
  # THE MEDIUM REMEMBERS NOTHING, and that is the opposite of the shipped card on purpose. This one
  # travels between boards, so a saved choice means a card that installed a Pocket S2 preselecting
  # the S2 devicetree when it is next booted on an ACE — and booting a wrong DTB after a 3s timeout
  # is a worse outcome than making the operator pick.
  # Comments stripped first. The config EXPLAINS that it saves nothing, naming each of these, and a
  # plain grep matched that prose and failed on correct code — the second time in this session that
  # a "this string must be absent" assertion caught a comment instead of a line of config.
  grep -vE '^[[:space:]]*#' "$cfg" >"$T/cfg.code"
  for leftover in savedefault save_env load_env grubenv saved_entry; do
    grep -q "$leftover" "$T/cfg.code" \
      && bad "the config still references '$leftover' — the medium would remember a board" \
      || ok "no '$leftover' in the config"
  done
  grep -q '^set timeout=-1' "$cfg" && ok "the menu waits indefinitely, every boot" \
    || bad "the menu has a timeout — it would auto-boot a board nobody chose"

  # Every dtb the config names must exist as a source .dts, or the entry is unbootable.
  missing=0
  while read -r d; do
    [ -f "$DTS/$d.dts" ] || { bad "menuentry references $d.dtb, which has no .dts"; missing=1; }
  done < <(grep -o 'devicetree /dtbs/[^ ]*\.dtb' "$cfg" | sed 's|.*/||; s|\.dtb$||' | sort -u)
  [ "$missing" -eq 0 ] && ok "every referenced dtb has a source .dts"
fi

# ---------------------------------------------------------------------------------------------
CASE="dtb parity with the shipped generator"
# See the header: the catalog is shared data, the derivation rule is subtle, and a divergence is a
# board that boots from a card but not from the installer.
if "$SHIPPED_GENCFG" A "$T/shipped.cfg" >/dev/null 2>"$T/err2"; then
  grep -o 'devicetree [^ ]*/dtbs/[^ ]*\.dtb' "$T/shipped.cfg"   | sed 's|.*/||; s|\.dtb$||' | sort -u >"$T/shipped.dtbs"
  grep -o 'devicetree /dtbs/[^ ]*\.dtb' "$T/installer.cfg" | sed 's|.*/||; s|\.dtb$||' | sort -u >"$T/installer.dtbs"
  s=$(wc -l <"$T/shipped.dtbs"); i=$(wc -l <"$T/installer.dtbs")
  if diff -q "$T/shipped.dtbs" "$T/installer.dtbs" >/dev/null; then
    ok "both generators name the same $i DTBs"
  else
    bad "DTB sets differ (shipped $s, installer $i): $(diff "$T/shipped.dtbs" "$T/installer.dtbs" | tr '\n' ' ')"
  fi
else
  skip "the shipped generator did not run here: $(head -1 "$T/err2")"
fi

# ---------------------------------------------------------------------------------------------
CASE="mkimage guards"
# The argument is positional and both trees are directories full of a Linux system, so picking the
# wrong one is a one-word mistake that would produce an "installer" with no install code on it.
grep -q 'ID=novadeck-installer' "$MKIMAGE" \
  && ok "refuses a tree that does not identify as the installer" \
  || bad "mkimage.sh does not check which tree it was handed"
grep -q 'usr/lib/novadeck/pkgs' "$MKIMAGE" \
  && ok "refuses a half-finished bootstrap (checks the completion marker)" \
  || bad "mkimage.sh does not check the bootstrap completed"
grep -q 'NOVADECK_PARTITION_TABLE' "$MKIMAGE" \
  && ok "points genpart.sh at the medium table, not the shipped one" \
  || bad "mkimage.sh does not override the partition table — it would lay the 8-partition layout"
# steamcl is the A/B slot chooser. On a one-root medium its conf files would be fiction.
grep -qi 'steamcl' "$MKIMAGE" && grep -q 'mcopy.*steamcl' "$MKIMAGE" \
  && bad "mkimage.sh installs steamcl — there are no slots for it to choose between" \
  || ok "no steamcl on the medium (GRUB goes straight in at bootaa64.efi)"
grep -q 'EFI/BOOT/bootaa64.efi' "$MKIMAGE" \
  && ok "GRUB is at the removable-media path ABL loads" \
  || bad "nothing is written to /EFI/BOOT/bootaa64.efi — ABL would find nothing to boot"
# GRUB's prefix is baked in at build time as /EFI/steamos, relative to the partition it loads from.
grep -q 'EFI/steamos/grub.cfg' "$MKIMAGE" \
  && ok "the config is at \$prefix (/EFI/steamos/grub.cfg)" \
  || bad "the config is not at the prefix boot/grub.sh builds in"
grep -q 'grubenv' "$MKIMAGE" && grep -qE '^[^#]*mcopy.*grubenv' "$MKIMAGE" \
  && bad "mkimage writes a grubenv — this medium is meant to remember nothing" \
  || ok "no grubenv on the medium (nothing here saves state between boots)"

CASE="the Wi-Fi template is on the medium"
# The no-Wi-Fi screen tells the operator to copy wifi.conf.example, and until 2026-08-24 nothing
# ever put one on a card. netcfg reads /esp/novadeck/wifi.conf, so the template has to sit beside
# that path, on the boot partition that is typed 0700 so Windows and macOS will show it.
grep -q 'novadeck/wifi.conf.example' "$MKIMAGE" \
  && ok "mkimage writes it to /novadeck/ on the boot partition" \
  || bad "the file the screen tells the user to copy is not put on the medium"
grep -q 'fatdir "$esp" novadeck' "$MKIMAGE" \
  && ok "and creates the folder netcfg reads wifi.conf from" \
  || bad "the novadeck folder is not created"
grep -q 'die "missing' "$MKIMAGE" && grep -q 'WIFI_EXAMPLE' "$MKIMAGE" \
  && ok "a missing template fails the build rather than shipping bad instructions" \
  || bad "the template can go missing silently"

CASE="the medium says which build it is"
# Until this landed, every installer image ever built answered identically: the same NAME, the same
# ID, no version, no date. That is the first question asked at the fallback console -- the thing
# that exists for the moment something has gone wrong -- and the medium could not answer it.
grep -q '>"$BASE/etc/novadeck-release"' "$MKIMAGE" \
  && ok "mkimage writes /etc/novadeck-release, the path the shipped image uses too" \
  || bad "no per-build identity is written into the tree"
for f in NOVADECK_VARIANT NOVADECK_BUILD NOVADECK_VERSION NOVADECK_GIT NOVADECK_MODE; do
  grep -q "echo \"$f=" "$MKIMAGE" && ok "$f is stamped" || bad "$f is missing from the stamp"
done
# REWRITTEN, NEVER APPENDED. The tree is cached between builds, so `>>` would stack a fresh block on
# every `make installer` until os-release carried a dozen contradictory VERSION= lines, the last one
# winning by accident.
grep -q '>>"$BASE/etc/os-release"' "$MKIMAGE" \
  && bad "os-release is APPENDED to, and the tree it lands in is cached across builds" \
  || ok "os-release is rewritten from the committed file plus the stamp, so a rebuild cannot stack blocks"
grep -q 'cat "$OSRELEASE_SRC"' "$MKIMAGE" \
  && ok "and the static half comes from install/os-release rather than a second copy of it" \
  || bad "the rewritten os-release does not start from the committed file"
# THE MODE COMES FROM THE TREE. `NOVADECK_DEV=1 make installer-root` followed by a plain
# `make installer` must not stamp `release` on a medium carrying an authorized_keys and a Wi-Fi PSK;
# mkroot folds `dev:0|1` into the reuse marker precisely so this half can read it back.
grep -q "grep -qx 'dev:1' \"\$BASE/usr/lib/novadeck/pkgs\"" "$MKIMAGE" \
  && ok "the dev/release mode is read out of the root's own reuse marker" \
  || bad "the mode is not derived from the tree"
# Non-comment lines only: the block above EXPLAINS why it does not read that variable, and a naive
# grep reads its own rationale as the violation.
grep -qE '^[^#]*NOVADECK_DEV' "$MKIMAGE" \
  && bad "mkimage reads NOVADECK_DEV — a stale environment could disagree with what was baked in" \
  || ok "and never from the environment, which cannot disagree with the tree"
grep -q 'installer.release' "$MKIMAGE" \
  && ok "the same fields land beside the image, so a publisher need not open a squashfs to name it" \
  || bad "no identity sidecar is written next to installer.img"
# install/os-release is an INPUT to mkroot's reuse key: a per-build field there re-bootstraps the
# whole emulated root on every build.
grep -qE '^(VERSION_ID|BUILD_ID|VERSION)=' "$ROOT/install/os-release" \
  && bad "install/os-release carries a per-build field — it is hashed into mkroot's reuse key" \
  || ok "install/os-release stays static, as mkroot's cache key requires"
# And the identity has to reach the container at all.
grep -qE '^installer:.*' "$ROOT/Makefile" \
  && grep -A3 '^installer:' "$ROOT/Makefile" | grep -q '$(ID_ENV)' \
  && ok "the Makefile forwards \$(ID_ENV), or NOVADECK_VERSION would never reach the stamp" \
  || bad "make installer does not pass ID_ENV into the container"

CASE="the medium carries the Steam tree it builds /home from"
# THE MEDIUM CARRIES IT, since 2026-08-25. A card seeds /home from the directory with mkfs.ext4 -d;
# this one builds /home on someone else's disk months later, so the tree travels with it. It used to
# be downloaded from a content-addressed URL the medium derived from a baked pin, which bought
# nothing -- a medium is bound to one seed either way -- and cost a publisher, a workflow, a pin
# handed between CI jobs and 1.7 GB of tmpfs while rauc streams the bundle.
grep -q 'steam-seed.tar.zst' "$MKIMAGE" \
  && ok "mkimage stages the packed tree into the root" \
  || bad "nothing puts a Steam seed on the medium"
grep -q 'sha256sum "\$SEED_SRC"' "$MKIMAGE" \
  && ok "and derives the pin from the bytes it is placing" \
  || bad "the pin is not computed from the staged file"
# THE PIN IS NOT AN INPUT. It arrived as NOVADECK_SEED_SHA256 from a separate CI job while the seed
# was published elsewhere, so the hash and the bytes came from different places and could disagree.
grep -qE '^[^#]*NOVADECK_SEED_SHA256' "$MKIMAGE" "$ROOT/install/mkroot.sh" \
  && bad "a seed pin is still taken as an input — it must be computed from the staged file" \
  || ok "no pin input anywhere: one file is read, hashed, and both halves written from that read"
grep -q 'die "no Steam seed at' "$MKIMAGE" \
  && ok "a build with no seed fails loudly rather than shipping a medium that cannot install" \
  || bad "a missing seed is not refused"
# And the build actually depends on it, or `make installer` races the packer.
grep -qE '^installer:.*\$\(SEED_ARTIFACT\)' "$ROOT/Makefile" \
  && ok "make installer depends on the packed seed" \
  || bad "the installer target does not require the seed artifact"

CASE="the verifier looks at the seed's CONTENT, not just its hash"
VERIFY="$ROOT/install/verify-image.sh"
# THE PIN PROVES NOTHING ON ITS OWN. mkimage computes it from the file it stages, so a pin and its
# seed agree by construction -- point NOVADECK_SEED_TARBALL at the wrong file and the medium carries
# a perfectly self-consistent non-seed. The spine then hashes it before consent, the hash matches,
# the disk is CARVED, and the install dies at seed_home. Checked with a junk archive while writing
# this: 3 entries, no steamui.so, correctly refused.
grep -q "grep -qx './steamrtarm64/steamui.so'" "$VERIFY" \
  && ok "verify-image asserts the archive really is the Steam tree" \
  || bad "nothing checks the seed's content — a self-consistent wrong seed reaches the carve"
grep -q 'package/\.\*\\\.installed\|package/.*installed' "$VERIFY" \
  && ok "and that the completeness marker survived, so first boot needs no self-heal" \
  || bad "the .installed marker is not asserted on the medium"
# It must ride the pass that is already reading the seed, or it doubles the slowest check here.
grep -q 'tee >(zstd -dc' "$VERIFY" \
  && ok "in the same decompress that computes the hash" \
  || bad "the content check reads the seed a second time"

CASE="the verifier knows about everything the medium ships"
# install/verify-image.sh is the ONLY thing that opens the built image; this file and test-mkroot.sh
# read the scripts, and a script that says the right thing while producing the wrong image passes
# both. So the verifier's list of what must be on the medium has to keep up with what mkroot puts
# there — otherwise a file added to the image is a file nothing ever checks arrived. Asserted in
# this direction only: the verifier states its own expectations (deriving them from the builder
# would make it agree with the builder by construction), but it may not fall behind.
[ -f "$VERIFY" ] || bad "install/verify-image.sh is missing"
if [ -f "$VERIFY" ]; then
  mapfile -t SHIPS < <(sed -n '/^INSTALL_FILES=(/,/^)/p' "$ROOT/install/mkroot.sh" \
    | sed -e '1d' -e '$d' -e 's/#.*//' | tr ' ' '\n' | grep -v '^$')
  mapfile -t FOREIGN < <(sed -n '/^FOREIGN_FILES=(/,/^)/p' "$ROOT/install/mkroot.sh" \
    | sed -e '1d' -e '$d' -e '/^[[:space:]]*#/d' | tr -d '"' | tr ' ' '\n' | grep -v '^$')
  unchecked=""
  for f in "${SHIPS[@]}"; do
    grep -q -- "$f" "$VERIFY" || unchecked="$unchecked $f"
  done
  for spec in "${FOREIGN[@]}"; do
    grep -q -- "${spec##*:}" "$VERIFY" || unchecked="$unchecked ${spec##*:}"
  done
  [ -z "$unchecked" ] \
    && ok "verify-image.sh names all ${#SHIPS[@]} shipped files and all ${#FOREIGN[@]} searched ones" \
    || bad "these reach the medium and nothing verifies they arrived:$unchecked"
fi

printf '\ntest-mkimage.sh: %d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
