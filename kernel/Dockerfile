# novadeck kernel build environment — aarch64 cross toolchain on x86_64 hosts.
# Image carries only the toolchain + kernel build deps; source and artifacts stay
# on the host via a bind mount (work/ and out/ are gitignored). Re-runnable.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential \
      gcc-aarch64-linux-gnu \
      bc bison flex \
      libssl-dev libelf-dev \
      kmod cpio rsync \
      xz-utils patch device-tree-compiler \
      curl ca-certificates \
      make python3 \
    && rm -rf /var/lib/apt/lists/*

# pil-squasher: reassembles split Qualcomm .mdt + .bNN images into a single .mbn
# (used by firmware/extract.sh). Not packaged for Ubuntu — build the single upstream
# source file, pinned by commit + sha256 (cf. the kernel source pin).
ARG PIL_SQUASHER_COMMIT=3c9f8b8756ba6e4dbf9958570fd4c9aea7a70cf4
ARG PIL_SQUASHER_SHA256=a527c778b14ddf05302a1e3649ff6f84fc3a472ddba51434cdf663c5d29f8e6f
RUN curl -fsSL "https://raw.githubusercontent.com/linux-msm/pil-squasher/${PIL_SQUASHER_COMMIT}/pil-squasher.c" \
      -o /tmp/pil-squasher.c \
    && echo "${PIL_SQUASHER_SHA256}  /tmp/pil-squasher.c" | sha256sum -c - \
    && gcc -O2 -Wall -o /usr/local/bin/pil-squasher /tmp/pil-squasher.c \
    && rm -f /tmp/pil-squasher.c \
    && pil-squasher 2>&1 | grep -q '<mbn output>'

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
