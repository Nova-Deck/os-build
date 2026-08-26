# shellcheck shell=bash
# novadeck hardware-staging library — sourced by installer/hw-select-target.sh and
# installer/hw-install.sh. Not executable, not shipped: it exists on the BUILD HOST only.
#
# WHAT IT IS FOR. Every hardware gate in the install path runs real install code on a real device,
# and the only device available to run it on is a dev card — which carries the SHIPPED image. The
# shipped image is not the installer image (plan Phase 6): four binaries the install path calls are
# absent from it, and `command -v` on the build host proves nothing about that, because an offline
# suite inherits the HOST's PATH. So each of those binaries has to travel with the script that needs
# it, pinned by sha256 the way every other external artifact in this tree is pinned.
#
# THE FOUR, and what each is load-bearing for:
#
#   sgdisk    (gptfdisk)   reads and writes the GPT. select-target.sh and carve.sh both refuse
#                          outright without it.
#   mdir      (mtools)     reads ESP CONTENT at a byte offset — how select-target.sh's rule 3b
#                          decides whether a foreign ESP is one ABL would boot. Its absence is what
#                          let the FIT's ROCKNIX install go undetected before the rule failed closed.
#   mkfs.vfat (dosfstools) the shared ESP and both efi partitions. lib-slotwrite.sh's mkfs_esp and
#                          mkfs_efi call it by name.
#   partprobe (parted)     re-reads the table after the carve. carve.sh treats it as best-effort but
#                          novadeck-install's recon() requires it outright, deliberately: a spine
#                          that discovered a missing tool AFTER userdata was gone would have charged
#                          the user their Android data for an error it could have printed at second
#                          zero. That asymmetry is the whole point of recon(), so the stager honours
#                          the hard requirement rather than routing around it.
#
# DT_NEEDED CLOSURES, checked against rootfs/manifest.lock rather than assumed. Three of the four
# are satisfied by packages the image already carries — libuuid/libblkid (util-linux-libs),
# libpopt (popt), libstdc++/libgcc_s (gcc-libs), libdevmapper (device-mapper). `partprobe` is the
# exception: it needs libparted.so.2, which nothing on the image provides, so the library is staged
# beside it and reached through LD_LIBRARY_PATH. mkfs.fat and mdir need libc and nothing else.
#
# Re-check every closure after a snapshot bump. A new dependency surfaces on the DEVICE as a loader
# error, not here as a failed fetch.
#
# To bump a pin: `make relock`, then change the VERSION and the SHA256 in the table together, and
# re-derive the closure. The repo the package comes from is part of the pin — dosfstools is in
# `core` and the other three are in `extra`, and a wrong repo is a 404 rather than a wrong file.

# The snapshot is READ from rootfs/manifest.lock rather than duplicated here, so a `make relock`
# cannot leave the stager fetching from a snapshot the image no longer uses.
hwstage_init() {  # <repo-root>
  HWSTAGE_ROOT="$1"
  HWSTAGE_SNAPSHOT="$(sed -n 's|^# repo snapshot: *||p' "$HWSTAGE_ROOT/rootfs/manifest.lock" | head -1)"
  [ -n "$HWSTAGE_SNAPSHOT" ] \
    || { echo "no '# repo snapshot:' line in rootfs/manifest.lock" >&2; return 1; }
  HWSTAGE_CACHE="$HWSTAGE_ROOT/work/hw-stage"
  mkdir -p "$HWSTAGE_CACHE/bin" "$HWSTAGE_CACHE/lib"
}

# The pin table. One row per STAGED FILE, not per package — parted contributes two, which is why
# the local name is a column rather than the basename of the member.
#
#   <repo> <package-filename> <sha256> <member-inside-the-package> <subdir/local-name>
hwstage_pin() {  # <name>
  case "$1" in
    sgdisk)    echo "extra gptfdisk-1.0.10-1-aarch64.pkg.tar.zst 6512d21ab6b504d36f45bec0c4b0f692179ff4a916707e0f050a1c56f4181704 usr/bin/sgdisk bin/sgdisk" ;;
    # mtools is a MULTI-CALL binary that dispatches on argv[0], and `mdir` ships as a symlink to it.
    # A symlink is not a file scp can carry on its own, so the dispatch target is copied under the
    # name we want it answered by.
    mdir)      echo "extra mtools-1:4.0.49-1-aarch64.pkg.tar.zst 1dde2158e72277060b0a7722d223985200cc377a8dc1e1d7b8adcfbc474d0aa4 usr/bin/mtools bin/mdir" ;;
    # Same shape: mkfs.vfat is a link to mkfs.fat, and the two are the same program.
    mkfs.vfat) echo "core dosfstools-4.2-5-aarch64.pkg.tar.zst 385092d21ec0830909157ea4669f135cd95d509208160ef5313e5516b35c86ff usr/bin/mkfs.fat bin/mkfs.vfat" ;;
    partprobe) echo "extra parted-3.6-2-aarch64.pkg.tar.zst 64b6728b4e62058653d7142d0c9eac84dbeaa572b32eb777a367543983c28540 usr/bin/partprobe bin/partprobe" ;;
    # Staged under its SONAME, which is what partprobe's DT_NEEDED names. The versioned filename in
    # the package is reached through a symlink the package also ships, and we carry neither symlink.
    libparted) echo "extra parted-3.6-2-aarch64.pkg.tar.zst 64b6728b4e62058653d7142d0c9eac84dbeaa572b32eb777a367543983c28540 usr/lib/libparted.so.2.0.5 lib/libparted.so.2" ;;
    *) echo "hwstage: no pin for '$1'" >&2; return 1 ;;
  esac
}

# Fetch once, cached under work/hw-stage (gitignored). The package is verified BEFORE it is
# unpacked: a mismatch removes the download rather than leaving a poisoned cache that the next run
# would accept because the file exists.
hwstage_fetch() {  # <name>...
  local name repo pkg sha member out local_pkg url got
  for name in "$@"; do
    read -r repo pkg sha member out < <(hwstage_pin "$name") || return 1
    [ -e "$HWSTAGE_CACHE/$out" ] && continue
    local_pkg="$HWSTAGE_CACHE/${pkg//:/_}"
    if [ ! -f "$local_pkg" ]; then
      # The only character in these names needing encoding is an epoch's colon, and tar would read
      # a `name:path` argument as a REMOTE host — hence the colon-free local filename above.
      url="$HWSTAGE_SNAPSHOT/$repo/os/aarch64/${pkg//:/%3A}"
      echo "[hwstage] fetching $pkg" >&2
      # Downloaded to .part and only renamed after the hash matches, so an interrupted fetch cannot
      # leave a partial file that the NEXT run finds present and therefore never verifies.
      curl -fsSL -o "$local_pkg.part" "$url" || { rm -f "$local_pkg.part"; return 1; }
      got="$(sha256sum "$local_pkg.part" | cut -d' ' -f1)"
      [ "$got" = "$sha" ] || { rm -f "$local_pkg.part"
        echo "sha256 mismatch for $pkg: got $got, pinned $sha" >&2; return 1; }
      mv "$local_pkg.part" "$local_pkg"
    fi
    tar -I zstd -C "$HWSTAGE_CACHE" -xf "$local_pkg" "$member" || return 1
    cp "$HWSTAGE_CACHE/$member" "$HWSTAGE_CACHE/$out" || return 1
    case "$out" in bin/*) chmod +x "$HWSTAGE_CACHE/$out" ;; esac
    # The extraction path is scratch: leaving usr/bin and usr/lib in the cache would put a second,
    # unpinned copy of every staged file beside the pinned one, under a name a later glob could pick.
    rm -rf "${HWSTAGE_CACHE:?}/usr"
  done
}

hwstage_path() {  # <name> -> the staged file on the BUILD HOST
  local repo pkg sha member out
  read -r repo pkg sha member out < <(hwstage_pin "$1") || return 1
  printf '%s\n' "$HWSTAGE_CACHE/$out"
}

# The dev card's throwaway key (dev.env mints it). IdentitiesOnly, so an agent holding many keys
# cannot spend the server's auth attempts before this one is offered.
hwstage_ssh_opts() {  # -> sets SSHOPTS
  local key="$HWSTAGE_ROOT/work/dev-ssh/id_ed25519"
  SSHOPTS=(-o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
  [ -f "$key" ] && SSHOPTS+=(-i "$key")
}
