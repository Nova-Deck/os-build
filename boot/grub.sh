#!/usr/bin/env bash
# novadeck GRUB (stage 2) build.
#
# Builds the per-slot stage-2 bootloader for arm64-efi from the pinned GNU GRUB 2.14 release
# tarball plus boot/patches/grub/ (the novadeck boot-attempts module), and generates the two
# per-slot grub.cfg files that go with it. Emits:
#   out/boot/grubaa64.efi
#   out/boot/grub-a.cfg, out/boot/grub-b.cfg
#   out/boot/fonts/dejavu-mono.pf2
#   out/boot/grubenv
#
#   boot/grub.sh
#
# Run inside the build image (needs the arm64 toolchain, the autotools + autogen, gawk and
# grub-common — see build/Dockerfile):
#   docker run --rm -v "$PWD":/src -w /src novadeck-build boot/grub.sh
#
# There is no ./bootstrap step and no gnulib checkout: the release tarball already vendors gnulib.
# See boot/grub.pin for why that matters and what the patch set covers.
set -euo pipefail
shopt -s nullglob

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/out/boot"
WORK="${WORK:-$ROOT/work/grub}"
PATCHES="$ROOT/boot/patches/grub"
mkdir -p "$OUT/fonts" "$WORK"

PIN="$ROOT/boot/grub.pin"
[ -f "$PIN" ] || { echo "missing pin: $PIN" >&2; exit 1; }
pin() { sed -n "s/^$1:[[:space:]]*//p" "$PIN" | head -1; }
GRUBVER="$(pin version)"
TARBALL="$WORK/grub-${GRUBVER}.tar.xz"

[ -f "$TARBALL" ] || curl -fSL -o "$TARBALL" "$(pin url)"
echo "$(pin sha256)  $TARBALL" | sha256sum -c - \
  || { echo "sha256 mismatch for grub — refusing to build" >&2; exit 1; }

SRCDIR="$WORK/src"
rm -rf "$SRCDIR"; mkdir -p "$SRCDIR"
tar -C "$SRCDIR" --strip-components=1 -xf "$TARBALL"

# Applied in lexical order, exactly as kernel/build.sh does (rename files to reorder). A reject is
# fatal: a partially patched GRUB builds fine and silently omits the module.
for p in "$PATCHES"/*.patch; do
  echo "[grub] patch $(basename "$p")"
  patch -p1 -d "$SRCDIR" --no-backup-if-mismatch <"$p" \
    || { echo "patch FAILED: $(basename "$p")" >&2; exit 1; }
done

# Patch 0003 adds a module to grub-core/Makefile.core.def, GRUB's module manifest. That file is
# input to autogen (via gentpl.py), which writes grub-core/Makefile.core.am, which automake INLINES
# into grub-core/Makefile.in — and the release tarball ships all of those pre-generated, from
# before our module existed. So the manifest edit does nothing until the chain is re-run:
# autogen.sh is gentpl.py + autogen + autoreconf, in that order.
#
# This is the one autotools step in the GRUB build. It is not the tarball's `bootstrap`: bootstrap
# is what needs a separately-checked-out gnulib at an exact revision, and the release tarball
# already vendors gnulib under grub-core/lib/gnulib. Hence no gnulib pin.
echo "[grub] autogen.sh (regenerating the module tables for the novadeck stanza)"
( cd "$SRCDIR" && ./autogen.sh )
grep -q novadeck "$SRCDIR/grub-core/Makefile.in" \
  || { echo "autogen.sh did not pick up the novadeck module — is patch 0003 applied?" >&2; exit 1; }

BUILDDIR="$WORK/build"
rm -rf "$BUILDDIR"; mkdir -p "$BUILDDIR"
cd "$BUILDDIR"

# TARGET_CFLAGS carries -fshort-wchar, which the novadeck module needs so its L"..." UCS-2 path
# literals are 2-byte as the firmware expects (see boot/grub.pin). -Os has to be repeated:
# configure only defaults TARGET_CFLAGS to -Os when it is EMPTY, and then appends its own flags to
# whatever it found (configure.ac:93-101), so setting it here replaces the default rather than
# adding to it.
echo "[grub] configuring arm64-efi"
"$SRCDIR/configure" \
  --target=arm64-pc-linux \
  --disable-nls \
  --with-platform=efi \
  --disable-werror \
  TARGET_CFLAGS="-Os -fshort-wchar" \
  TARGET_CC=aarch64-linux-gnu-gcc \
  TARGET_OBJCOPY=aarch64-linux-gnu-objcopy \
  TARGET_STRIP=aarch64-linux-gnu-strip \
  TARGET_NM=aarch64-linux-gnu-nm \
  TARGET_RANLIB=aarch64-linux-gnu-ranlib \
  TARGET_LD=aarch64-linux-gnu-ld

# AWK=gawk: grub-core/genmoddep.awk uses asorti(), which mawk does not implement, and mawk is
# Ubuntu's default /usr/bin/awk. Without this the module dependency table comes out empty and the
# resulting image fails at runtime rather than at build time.
echo "[grub] building (AWK=gawk)"
make -j"$(nproc)" AWK=gawk

# The stage-2 module set. GRUB 2.14 has no `saveenv` (merged into `loadenv`) and no `menu` (merged
# into `normal`).
#   part_gpt fat btrfs      the three filesystems the chain touches: GPT, the ESP/efi vfat, the
#                           slot root's btrfs (where Image/initramfs/dtbs live)
#   loadenv                 load_env/save_env against the ESP's grubenv -- the saved board choice
#   regexp                  derives the boot disk from $root; see boot/gen-grub-cfg.sh
#   search*                 the fallback path when that derivation fails
#   probe                   --part-uuid, which turns those derived devices into the PARTUUIDs the
#                           cmdline names. Stock GRUB builds it and we simply never embedded it;
#                           without it here the generated config's probe calls are "unknown
#                           command" and every boot silently takes the PARTLABEL fallback.
#   novadeck                novadeck_bootattempts, called once per boot by the generated grub.cfg
MODULES="boot linux part_gpt fat btrfs loadenv search search_fs_file \
search_fs_uuid search_label chain reboot halt sleep test true echo read \
configfile regexp probe normal minicmd gfxterm efi_gop font all_video novadeck"

echo "[grub] grub-mkimage"
test -f grub-core/novadeck.mod || { echo "novadeck.mod was not built — is patch 0003 applied?" >&2; exit 1; }
./grub-mkimage -d grub-core -O arm64-efi -p /EFI/steamos $MODULES \
  -o "$OUT/grubaa64.efi"

# Boot font. Prefer the tree-built grub-mkfont (needs libfreetype-dev in the container); fall back
# to the distro grub-common one, which is the same GRUB 2.14.
#
# SIZE IS THE ONLY MENU-SCALE LEVER WE HAVE. gfxterm draws the menu in a fixed-size bitmap font at
# whatever resolution the firmware hands us, and we never set gfxmode -- GRUB's default is already
# `auto`, i.e. the panel's preferred (native) mode. So the menu's physical size is set here and
# nowhere else; adding `set gfxmode=auto` to grub.cfg would parse, ship and change nothing.
#
# Forcing a small gfxmode instead is NOT the alternative it looks like: these are Qualcomm ABL/GOP
# devices that generally expose only the native mode, so the request falls back to native silently
# -- and it would also change what gfxpayload=keep hands the kernel.
#
# 32px because the catalog spans 1.78x in linear density: most boards are 1080 wide, the Pocket
# S2/S2K are 1440x2560. At 16px the menu was unreadable there. Rotated 270 this gives roughly
# 60x33 cells on a 1080 board and 80x45 on an S2 -- comfortable at both ends. Revisit if a panel
# outside that range joins the catalog.
MKFONT="$BUILDDIR/grub-mkfont"
[ -x "$MKFONT" ] || MKFONT="$(command -v grub-mkfont)"
"$MKFONT" -s 32 /usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf \
  -o "$OUT/fonts/dejavu-mono.pf2"

file "$OUT/grubaa64.efi" "$OUT/fonts/dejavu-mono.pf2"
file "$OUT/grubaa64.efi" | grep -q "ARM64" || { echo "grubaa64.efi not ARM64" >&2; exit 1; }

# A pristine stage-2 env block, built HERE by grub-editenv and shipped as an artifact, because the
# two places that need one cannot make it themselves. It goes to the shared ESP as
# /EFI/steamos/grubenv, and `save_env` writes the user's board choice into it so the choice survives
# slot updates (the ESP is the only partition an A/B update does not replace).
#
#   images/make-sdcard.sh  mcopy's this file rather than running `grub-editenv create` a second time
#   the internal installer  cp's it out of /usr/lib/novadeck/boot/ of the root it just wrote
#
# THE INSTALLER IS WHY IT IS AN ARTIFACT AT ALL. grub-editenv is not on the shipped image -- no grub
# in customize-base.sh's PKGS -- so the device cannot create one, and adding grub to the installer's
# package list to write 1024 bytes of constant is a dependency for nothing. Everything else the
# installer writes is per-disk and has to be generated there (see lib-slotwrite.sh's parts.env, which
# is hand-rolled for exactly that reason); this one is a constant, so it ships as a constant.
#
# EMPTY IS THE ASSERTION THAT MATTERS. grub-editenv is being run on a build host, and a block that
# arrived carrying a `saved_entry` would pin every device flashed or installed from this build to
# one board -- and it would boot, on the machine that built it, which is the failure that never gets
# noticed. `list` on a pristine block prints nothing.
echo "[grub] grub-editenv create -> grubenv"
rm -f "$OUT/grubenv"
grub-editenv "$OUT/grubenv" create
[ "$(wc -c <"$OUT/grubenv")" = 1024 ] \
  || { echo "grubenv is $(wc -c <"$OUT/grubenv") bytes, not 1024 -- grub_envblk_open only requires the signature to FIT, so a wrong-length block reads back fine and is not the object a card carries" >&2; exit 1; }
[ -z "$(grub-editenv "$OUT/grubenv" list)" ] \
  || { echo "grubenv is not pristine -- it carries: $(grub-editenv "$OUT/grubenv" list | tr '\n' ' ')" >&2; exit 1; }

# The per-slot configs. Generation is a separate script on purpose: it needs no toolchain, so
# images/test-stage2-grub.sh can produce and assert them on a bare host with no cross-build.
"$ROOT/boot/gen-grub-cfg.sh" A "$OUT/grub-a.cfg"
"$ROOT/boot/gen-grub-cfg.sh" B "$OUT/grub-b.cfg"

echo "[grub] done -> $OUT"
ls -l "$OUT" "$OUT/fonts"
