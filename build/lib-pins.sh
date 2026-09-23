# shellcheck shell=bash
# novadeck base pins — the package-repo snapshot and the arm64 builder image cut from it.
#
# SOURCED, never executed (hence mode 0644, like the other lib-*.sh). Callers set ROOT first.
#
# WHY THIS FILE EXISTS — the same two guards used to be copied into six scripts
# (rootfs/customize-base.sh, installer/mkroot.sh, installer/genlock.sh, rootfs/genmanifest.sh,
# packages/build-overlay.sh, build/steam-seed/fetch-steam-seed.sh), and a copy that falls behind
# does not fail: it accepts a pin the others would refuse, or refuses one they accept, on whichever
# stage happens to run it. One definition, sourced everywhere.
#
# THE TWO PINS, and why the second is derived from the first:
#   build/snapshot.pin  the repo base URL every row of rootfs/manifest.lock is installed from.
#   build/builder.pin   the sha256 of that SAME snapshot's system.rootfs.zst — Valve's own aarch64
#                       root tarball, which ships base-devel. It is the execution environment for
#                       pacman and makepkg (it contributes no files to an image).
# The builder's URL is not written down anywhere: it is always $SNAPSHOT/system.rootfs.zst. So the
# builder cannot come from a different snapshot than the packages, and bumping the snapshot without
# re-hashing its tarball fails the fetch instead of quietly building against the old one.

if ! declare -F die >/dev/null 2>&1; then
  die() { printf '[lib-pins] ERROR: %s\n' "$1" >&2; exit 1; }
fi

# Pin = last non-comment, non-blank line of a pin file.
pin_line() { grep -vE '^[[:space:]]*(#|$)' "$1" | tail -1; }

# The validated snapshot URL. Accepts a named `mash-YYYYMMDD` snapshot under the official
# archlinux-deckard tree, with or without a `.N` revision:
#   - The unsuffixed name IS an alias — it is the first revision, and it will follow .1, .2 … when
#     they land. That is safe to pin only because rootfs/manifest.lock records a sha256 per package
#     FILE and rootfs/fetchlock.sh verifies every one: a republish fails the build loudly, it cannot
#     drift into an image. Prefer a .N revision whenever one exists.
#   - `main`, `dev`, `builds`, `pipeline`, `tmp` are moving CI aliases; nothing pins them.
#   - `.pvt` / `-pvt` revisions are refused: their meaning is unpublished, and we do not build
#     from bytes whose provenance we cannot state.
pins_snapshot() {
  local f="$ROOT/build/snapshot.pin" s name
  [ -f "$f" ] || die "no snapshot pin: $f"
  s="$(pin_line "$f")"
  case "$s" in
    https://holo-packages.steamos.cloud/archlinux-deckard/archlinux/*) ;;
    *) die "snapshot pin is not under the official archlinux-deckard tree: '$s'" ;;
  esac
  name="${s##*/}"
  [[ "$name" =~ ^mash-[0-9]{8}(\.[0-9]+)?$ ]] \
    || die "refusing snapshot '$name' (need mash-YYYYMMDD[.N]; no moving alias, no .pvt): '$s'"
  printf '%s\n' "$s"
}

pins_builder_sha() {
  local f="$ROOT/build/builder.pin" sha
  [ -f "$f" ] || die "no builder pin: $f"
  sha="$(pin_line "$f")"
  [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || die "builder pin is not a sha256: '$sha'"
  printf '%s\n' "$sha"
}

# The local tag the builder is imported under. Keyed on the TARBALL's sha256, because that is the
# only stable identity it has: `docker import` stamps a creation time into the image config, so the
# image ID differs on every import of the same bytes and cannot be pinned by digest.
pins_builder_ref() { printf 'novadeck/builder:%s\n' "$(pins_builder_sha)"; }

# One line for lock headers: where the builder came from.
pins_builder_desc() { printf '%s/system.rootfs.zst sha256:%s\n' "$(pins_snapshot)" "$(pins_builder_sha)"; }

# Make sure the builder image exists locally, importing it if not, and print its ref on stdout.
#
# An import is: fetch + sha256-verify the tarball, `docker import` it, then in one container point
# pacman at the pinned snapshot and PROVE the image is that snapshot — every installed package
# present in the snapshot at exactly the installed version. Only then is it committed under the ref.
# The vendor tarball's own mirrorlist names the snapshot through a CI host alias; ours replaces it,
# so every consumer's `pacman -Sy` resolves from the pin, not from whatever the tarball says.
pins_builder_ensure() {
  local snap sha ref tarball tmp cname
  snap="$(pins_snapshot)"; sha="$(pins_builder_sha)"; ref="$(pins_builder_ref)"
  if docker image inspect "$ref" >/dev/null 2>&1; then
    printf '%s\n' "$ref"; return 0
  fi
  command -v zstd >/dev/null 2>&1 || die "zstd not found on build host"

  tarball="$ROOT/work/builder/system.rootfs.$sha.zst"
  mkdir -p "$ROOT/work/builder"
  if [ ! -f "$tarball" ]; then
    echo "[lib-pins] fetching builder rootfs: $snap/system.rootfs.zst" >&2
    curl -fL --retry 3 -sS -o "$tarball.part" "$snap/system.rootfs.zst" \
      || die "builder rootfs download failed: $snap/system.rootfs.zst"
    mv "$tarball.part" "$tarball"
  fi
  if ! printf '%s  %s\n' "$sha" "$tarball" | sha256sum -c --quiet >/dev/null 2>&1; then
    rm -f "$tarball"
    die "builder rootfs sha256 mismatch for $snap/system.rootfs.zst (republished? bump build/builder.pin)"
  fi

  tmp="novadeck/builder-import:$sha"
  echo "[lib-pins] importing builder: $ref" >&2
  zstd -dc "$tarball" | docker import --platform linux/arm64 - "$tmp" >/dev/null \
    || die "docker import of the builder rootfs failed"

  # arm64 binfmt so the imported image can execute at all under qemu.
  if ! docker run --rm --platform linux/arm64 "$tmp" /usr/bin/true >/dev/null 2>&1; then
    echo "[lib-pins] registering arm64 binfmt (qemu) via tonistiigi/binfmt" >&2
    docker run --privileged --rm tonistiigi/binfmt --install arm64 >&2
  fi

  cname="novadeck-builder-import-${sha:0:12}"
  docker rm -f "$cname" >/dev/null 2>&1 || true
  if ! docker run --name "$cname" --platform linux/arm64 -e SNAPSHOT="$snap" "$tmp" \
      bash -euo pipefail -c '
        printf "Server = %s/\$repo/os/\$arch\n" "$SNAPSHOT" > /etc/pacman.d/mirrorlist
        pacman -Sy --noconfirm >&2
        foreign="$(pacman -Qmq || true)"
        [ -z "$foreign" ] || { printf "installed but absent from the snapshot:\n%s\n" "$foreign" >&2; exit 1; }
        drift="$(pacman -Sl | grep -F "[installed: " || true)"
        [ -z "$drift" ] || { printf "installed at a version the snapshot does not carry:\n%s\n" "$drift" >&2; exit 1; }
        rm -rf /var/lib/pacman/sync/*
      ' >&2; then
    docker rm -f "$cname" >/dev/null 2>&1 || true
    docker rmi "$tmp" >/dev/null 2>&1 || true
    die "builder rootfs does not match the pinned snapshot $snap"
  fi
  docker commit "$cname" "$ref" >/dev/null
  docker rm "$cname" >/dev/null
  docker rmi "$tmp" >/dev/null
  printf '%s\n' "$ref"
}
