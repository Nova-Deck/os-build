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

WORKDIR /src
ENTRYPOINT ["/bin/bash"]
