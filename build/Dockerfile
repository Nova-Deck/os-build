# novadeck-build — cross-compile build environment for the whole pipeline on x86_64
# hosts (kernel, rootfs/sdcard assembly, boot packaging, RAUC
# bundle). Carries the aarch64 toolchain plus every container stage's deps; source and
# artifacts stay on the host via a bind mount (work/ and out/ are gitignored). Re-runnable.
FROM ubuntu:26.04

ENV DEBIAN_FRONTEND=noninteractive
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
      rauc casync openssl squashfs-tools \
    && rm -rf /var/lib/apt/lists/*

# mkbootimg: AOSP Android boot-image packer (used by boot/backends/android-bootimg.sh).
# Not packaged for Ubuntu — vendor the single upstream script, pinned by commit +
# sha256 (cf. the kernel source pin). The lone top-level GKI-signing import pulls in
# the avbtool tree and is unused here, so neutralize it after verifying the pristine
# hash; the rest of mkbootimg is self-contained.
ARG MKBOOTIMG_COMMIT=d2bb0af5ba6d3198a3e99529c97eda1be0b5a093
ARG MKBOOTIMG_SHA256=37d84b3d162e0bc62e36c1f4e1c63c85ea0caa9f29be023eb2f8efe006ad948c
RUN curl -fsSL "https://android.googlesource.com/platform/system/tools/mkbootimg/+/${MKBOOTIMG_COMMIT}/mkbootimg.py?format=TEXT" \
      | base64 -d > /tmp/mkbootimg.py \
    && echo "${MKBOOTIMG_SHA256}  /tmp/mkbootimg.py" | sha256sum -c - \
    && sed -i 's/^from gki.generate_gki_certificate import generate_gki_certificate/def generate_gki_certificate(*a, **k):\n    raise NotImplementedError("GKI signing unsupported in novadeck")/' \
        /tmp/mkbootimg.py \
    && install -Dm0755 /tmp/mkbootimg.py /usr/local/bin/mkbootimg \
    && rm -f /tmp/mkbootimg.py \
    && mkbootimg --help >/dev/null

WORKDIR /src
ENTRYPOINT ["/bin/bash"]
