# novadeck-build — cross-compile build environment for the whole pipeline on x86_64
# hosts (kernel, rootfs/sdcard assembly, boot packaging, RAUC
# bundle). Carries the aarch64 toolchain plus every container stage's deps; source and
# artifacts stay on the host via a bind mount (work/ and out/ are gitignored). Re-runnable.
FROM ubuntu:26.04

ENV DEBIAN_FRONTEND=noninteractive

# rauc is the ONE apt package here pinned to an exact version, and it is deliberate. Everything
# else in the list below (compilers, mkfs tools, curl) only has to work — a newer one produces the
# same artifact. rauc does not: it WRITES the update bundle, and the device's rauc has to be able
# to install what it wrote. That pairing is already load-bearing (packages/rauc builds the DEVICE
# side at 1.15.2 precisely because 1.14 cannot install a dm-verity bundle on kernel >= 6.19), so
# letting the bundle WRITER float means the two halves of the update path can drift apart with no
# signal until a device refuses a bundle — and this device has no serial console to ask why.
#
# The cost of an exact pin is that the build BREAKS when Ubuntu supersedes this version and drops
# the old binary from the archive (Ubuntu has no per-package snapshot the way our pacman side
# does). That is the intended trade: a loud build failure that makes someone re-verify the
# writer/installer pair, rather than a silent version change under a working-looking build.
# To bump: check `apt-cache madison rauc` in this base image, update the pin, and re-run the HW
# `rauc install` test before trusting the bundles it produces.
ARG RAUC_VERSION=1.15.1-1

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential \
      gcc-aarch64-linux-gnu \
      bc bison flex \
      dwarves \
      libssl-dev libelf-dev \
      kmod cpio rsync \
      openssh-client \
      xz-utils patch device-tree-compiler \
      curl ca-certificates \
      make python3 \
      btrfs-progs gdisk dosfstools mtools e2fsprogs \
      casync openssl squashfs-tools \
      "rauc=${RAUC_VERSION}" \
    && rm -rf /var/lib/apt/lists/*

# Boot stage (Phase 5): the two-stage UEFI chain, steamcl (stage 1) + GRUB (stage 2).
#
# steamos-efi ships no configure, so it needs the autotools; it links against gnu-efi for arm64
# and generates its console font at build time through fontconfig + grub-mkfont. Ubuntu's
# gnu-efi:arm64 installs to plain /usr/lib (crt0-efi-aarch64.o, elf_aarch64_efi.lds,
# /usr/lib/pkgconfig/gnu-efi.pc) rather than a multiarch dir — the fork's efi_cpu AC_SUBST maps
# target_cpu arm64 -> aarch64 to find it.
#
# GRUB is built from the GNU 2.14 RELEASE tarball, which vendors gnulib — so there is no
# ./bootstrap and no gnulib checkout to pin. It does still need ./autogen.sh, because our patch
# adds a module to grub-core/Makefile.core.def and the tables generated from that manifest ship
# pre-generated: hence autogen (the AutoGen tool, which gentpl.py drives), autoconf-archive and
# autopoint on top of the autotools above. It also needs gawk: grub-core's genmoddep.awk uses
# asorti(), which mawk does not implement, and Ubuntu's default awk is mawk.
#
# grub-common carries the host-side tools both stages use: grub-mkfont (steamcl's font and ours),
# grub-mkimage, grub-editenv (seeding the stage-2 env block) and grub-script-check (which
# images/test-stage2-grub.sh runs over the generated grub.cfg files).
RUN dpkg --add-architecture arm64 && apt-get update && apt-get install -y --no-install-recommends \
      gnu-efi:arm64 \
      libc6-dev-arm64-cross \
      autoconf automake libtool pkg-config gettext \
      autogen autoconf-archive autopoint \
      gawk \
      fontconfig fonts-dejavu-core libfreetype-dev \
      grub-common \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
ENTRYPOINT ["/bin/bash"]
