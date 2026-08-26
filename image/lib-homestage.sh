# shellcheck shell=bash
# novadeck /home staging — the deck user's home, built once and used by two writers.
#
# SOURCED, never executed (hence mode 0644, like lib-slotwrite.sh).
#
# WHY THIS FILE EXISTS, and it is the same argument lib-slotwrite.sh opens with: the pre-seeded
# /home is written twice -- once by image/make-sdcard.sh into a card image at build time, and once
# by installer/novadeck-install onto an internal disk on the device -- and the two must produce the
# same tree. The parts that drift silently are the ~/.steam compat symlinks: a missing sdk64 does
# not stop Steam starting, it makes an x86 title's SteamAPI_Init() fail at launch, on that medium
# only. So the layout lives here and both callers ask for it.
#
# THE SOURCE IS EITHER A DIRECTORY OR A TARBALL, which is what separates the two callers -- the
# same shape seed_var uses, for the same reason. make-sdcard.sh has work/steam-seed staged on the
# build host and passes the directory. The installer has no such tree: it has the published
# steam-seed-<pin>.tar.zst, 1.7 GB zstd (3.3 GB unpacked, measured 2026-08-21), and the mounted
# /home is the only place with room to put it, so
# it passes the tarball and this unpacks straight into the destination. A helper that only took a
# directory would force the installer to stage a second copy on a tmpfs that cannot hold one.

if ! declare -F die >/dev/null 2>&1; then
  die() { printf '[lib-homestage] ERROR: %s\n' "$1" >&2; exit 1; }
fi

# uid/gid 1000, baked into the base by rootfs/customize-base.sh. Numeric rather than resolved
# through a passwd file, because neither caller is resolving names through the target's root:
# make-sdcard.sh runs on the build host and the installer runs from the installer image.
DECK_UID=${DECK_UID:-1000}
DECK_GID=${DECK_GID:-1000}

# <home-root> is the directory that becomes the /home FILESYSTEM's root -- a staging dir for
# make-sdcard.sh (which then hands it to `mkfs.ext4 -d`), the mountpoint of the freshly created
# home partition for the installer. So this creates `deck/` inside it, not the home itself.
stage_deck_home() {  # <steam-seed-dir-or-tarball> <home-root>
  local src="$1" root="$2"
  local deckhome="$root/deck"

  # Resolve WHICH KIND of source before creating anything, as seed_var does: the installer's copy
  # is the expensive step and the argument is the cheap check.
  local mode
  if   [ -d "$src" ]; then mode=dir
  elif [ -f "$src" ]; then mode=tar
  else die "no Steam seed at $src -- neither a staged directory nor a published tarball"
  fi

  install -d "$deckhome/.local/share" "$deckhome/.steam" \
    || die "cannot create the deck home under $root"

  if [ "$mode" = dir ]; then
    cp -a "$src" "$deckhome/.local/share/Steam" \
      || die "cannot copy the Steam seed from $src"
  else
    # -p --numeric-owner mirrors the `cp -a` above: the tree is chown'd wholesale below, but the
    # MODES inside it are the seed's and must survive. tar masks permission bits off when it does
    # not think it is preserving them, even as root -- measured in seed_var, same trap.
    install -d "$deckhome/.local/share/Steam" || die "cannot create the Steam directory"
    tar -p --numeric-owner -xf "$src" -C "$deckhome/.local/share/Steam" \
      || die "cannot unpack the Steam seed $src"
  fi

  # The HOME-relative ~/.steam compat symlinks, mirroring SteamOS's layout. Relative and not
  # absolute: make-sdcard.sh builds this under a mktemp dir and the installer builds it under a
  # /run mountpoint, so an absolute link would be right in neither place and wrong only at boot.
  ln -sfn ../.local/share/Steam            "$deckhome/.steam/steam"
  ln -sfn ../.local/share/Steam            "$deckhome/.steam/root"
  ln -sfn ../.local/share/Steam/linuxarm64 "$deckhome/.steam/sdkarm64"
  # x86 Steam SDK/runtime compat symlinks. A native x86-64 Linux game under system-FEX dlopen()s
  # ~/.steam/sdk64/steamclient.so (32-bit -> sdk32); Steam's reaper also resolves ubuntu12_{32,64}
  # via bin{32,64}. Without these the game's SteamAPI_Init() fails ("cannot open
  # sdk64/steamclient.so") and it exits/crashes. The link targets (linux{32,64}, ubuntu12_{32,64})
  # are populated by the arm64 client on demand when it first runs an x86 title; the symlinks must
  # pre-exist so it can.
  ln -sfn ../.local/share/Steam/linux32     "$deckhome/.steam/sdk32"
  ln -sfn ../.local/share/Steam/linux64     "$deckhome/.steam/sdk64"
  ln -sfn ../.local/share/Steam/ubuntu12_32 "$deckhome/.steam/bin32"
  ln -sfn ../.local/share/Steam/ubuntu12_64 "$deckhome/.steam/bin64"
  # No compat tool is seeded into the deck home. The arm64 Proton that runs x86 Windows games lives
  # in the root slot at /usr/share/steam/compatibilitytools.d, added to the client's search set via
  # STEAM_EXTRA_COMPAT_TOOLS_PATHS (exported by novadeck-steam) -- so it is available on first boot
  # without being copied into (and then going stale in) the user's Steam directory, and it is
  # replaced atomically with the OS slot.

  chown -R "$DECK_UID:$DECK_GID" "$deckhome" \
    || die "cannot give $deckhome to the deck user"
}
