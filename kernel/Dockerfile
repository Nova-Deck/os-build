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

WORKDIR /src
ENTRYPOINT ["/bin/bash"]
