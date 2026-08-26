#!/usr/bin/env bash
# novadeck INSTALLER manifest generator -> install/manifest.lock  (Phase 6).
#
#   install/genlock.sh [installer-rootfs-dir]        (default: work/installer-base)
#
# Peer of rootfs/genmanifest.sh, which does the same job for the shipped image. Runs on the HOST
# against the already-bootstrapped tree — no container, no emulation: everything it needs is a file.
# The output format is IDENTICAL (`name version arch source sha256`), which is what lets
# rootfs/fetchlock.sh materialize either lock with no idea which image it describes.
#
# WHY A SECOND LOCK RATHER THAN ONE COVERING BOTH IMAGES (decided 2026-08-24). The installer's set
# is not a subset of the shipped one: gptfdisk, dosfstools, mtools and parted are in none of
# rootfs/manifest.lock's 399 rows, because none of them ships on a device. Folding them in would
# make the shipped image's reviewed artifact describe ~40 rows of content that image never carries,
# and "the lock is green" would stop meaning "this is what is on the device". Two locks, each
# describing exactly one image, one mechanism, one format.
#
# WHY THIS IS SMALLER THAN rootfs/genmanifest.sh, rather than a flag on it. That script is bound to
# the release image in three ways this one has no analogue for, and each would have become a
# conditional in a file whose whole value is being reviewable:
#   - it reads rootfs/conf/seal.list to reclassify the `stripped` rows. There is no seal here: the
#     installer keeps its pacman, deliberately (see install/pkgs.list).
#   - it refuses a `dev:1` base. install/mkroot.sh has no dev mode to refuse.
#   - it walks packages/*/prebuilt.pin by auto-discovery, which is exactly the behaviour
#     install/pygame-ce.pin exists OUTSIDE packages/ to avoid. This one reads the prebuilt rows out
#     of the marker install/mkroot.sh wrote into the tree, so the lock describes the tree that was
#     built rather than re-deriving the intent behind it.
#
# THREE PROVENANCE CLASSES, pinned by genuinely different mechanisms — the same three
# rootfs/manifest.lock uses, minus `stripped`:
#
#   snapshot  installed from the pinned repo revision; hash = the .pkg.tar.zst we installed.
#   novadeck  built from source by packages/build-overlay.sh; hash = packages/inputhash.sh over the
#             package's COMMITTED SOURCES, NOT the built artifact. Our overlay builds are not
#             bit-reproducible, so an artifact hash moves on every rebuild from identical inputs and
#             only ever verifies on the machine that last relocked. See rootfs/fetchlock.sh's header
#             for the full reasoning; this lock inherits it unchanged, because it is the same
#             work/repo/aarch64 and the same packages/*/source.pin behind both images.
#   prebuilt  not pacman packages at all: the sha256-pinned tarballs/wheels install/mkroot.sh
#             places by name. Carried so the lock covers the whole image, exactly as the shipped
#             one does. rootfs/fetchlock.sh skips them — they are placed, not installed.
#
# Every installed package must be traceable to a file that can be hashed. A row with no file means
# something reached the tree outside the install path, and this fails on it rather than recording a
# '-' hash: an unhashable row is a row fetchlock.sh cannot verify, so writing one would produce a
# lock that silently describes less than the image contains.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASE="${1:-${INSTALLER_ROOTFS:-$ROOT/work/installer-base}}"
LOCK="$ROOT/install/manifest.lock"
CACHE="$ROOT/work/pacman-cache"
OVERLAY_REPO="$ROOT/work/repo/aarch64"
SNAPFILE="$ROOT/snapshot.pin"
PINFILE="$ROOT/base-devel.digest"
LOCALDB="$BASE/var/lib/pacman/local"
MARKER="$BASE/usr/lib/novadeck/pkgs"
PREBUILT_MARKER="$BASE/usr/lib/novadeck/prebuilt.manifest"

[ -d "$LOCALDB" ] || {
  echo "no pacman local db under ${BASE#"$ROOT"/} — bootstrap the installer root first:" >&2
  echo "  NOVADECK_RESOLVE=1 install/mkroot.sh" >&2
  exit 1
}
# The marker is written LAST by mkroot.sh, so its presence is what proves the bootstrap ran to
# completion. Without this check a tree that died mid-transaction would be locked as if it were
# the whole image, and the missing packages would come back as fetchlock rows that simply are not
# there rather than as a build failure.
[ -f "$MARKER" ] || {
  echo "${MARKER#"$ROOT"/} is absent — that tree is a half-finished bootstrap, not an image" >&2
  exit 1
}
# The lock describes the RELEASE installer. A dev tree additionally carries remote access (sshd
# enabled, a baked authorized_keys), and while that adds no PACKAGES today — openssh is declared for
# both — locking one would record a marker claiming to describe a medium that is not the one we
# publish. mkroot.sh records dev:1 precisely so this is detectable rather than inferred. `make
# relock-installer` clears NOVADECK_DEV for the same reason `make relock` does.
if grep -qx 'dev:1' "$MARKER" 2>/dev/null; then
  echo "refusing to lock a DEV installer root: ${MARKER#"$ROOT"/} says dev:1" >&2
  echo "  rebuild release first (unset NOVADECK_DEV), or just run \`make relock-installer\`" >&2
  exit 1
fi

# Index the two package directories ONCE by exact filename. Deliberately not a per-package glob:
# the cache accumulates stale versions, so a glob would happily match the wrong artifact. Exact
# name-version-arch or nothing.
declare -A PKGFILE
index_dir() {
  local dir="$1" src="$2" f
  [ -d "$dir" ] || return 0
  for f in "$dir"/*.pkg.tar.zst; do
    [ -e "$f" ] || continue
    PKGFILE["$(basename "$f")"]="$src	$f"
  done
}
# Cache first, overlay second, so the overlay OVERWRITES on collision — matching the repo ORDER in
# rootfs/conf/pacman.conf, where the overlay sits ahead of the snapshot repos and order beats version.
index_dir "$CACHE" snapshot
index_dir "$OVERLAY_REPO" novadeck

# Overlay artifact -> the input hash of the source pin that produced it. The mapping comes from the
# per-package artifact lists packages/build-overlay.sh writes, because one PKGBUILD can emit
# several packages and only the builder knows which.
declare -A PINHASH
for pin in "$ROOT"/packages/*/source.pin; do
  [ -e "$pin" ] || continue
  pname="$(sed -n 's/^name:[[:space:]]*//p' "$pin" | head -1)"
  [ -f "$OVERLAY_REPO/.stamps/$pname.files" ] || continue
  h="$("$ROOT/packages/inputhash.sh" "$(dirname "$pin")")"
  while read -r f; do
    [ -n "$f" ] && PINHASH["$f"]="$h"
  done < "$OVERLAY_REPO/.stamps/$pname.files"
done

# One row per installed package, read straight out of the local db's desc files. Field order in
# desc is not guaranteed, so each is matched by its own %KEY% rather than by position.
desc_field() { sed -n "/^%$2%\$/{n;p;q}" "$1"; }

rows=""
unfiled=""
missing=0
for d in "$LOCALDB"/*/; do
  desc="$d/desc"
  [ -f "$desc" ] || continue
  name="$(desc_field "$desc" NAME)"
  ver="$(desc_field "$desc" VERSION)"
  arch="$(desc_field "$desc" ARCH)"
  [ -n "$name" ] && [ -n "$ver" ] || { echo "malformed desc: $desc" >&2; exit 1; }
  arch="${arch:-any}"

  entry="${PKGFILE["$name-$ver-$arch.pkg.tar.zst"]:-}"
  if [ -z "$entry" ]; then
    unfiled+="  $name-$ver-$arch"$'\n'
    missing=$((missing + 1))
    continue
  fi
  src="${entry%%	*}"; file="${entry#*	}"
  if [ "$src" = novadeck ]; then
    # Pinned by its sources, not its bytes (header). No fallback to the artifact sha: that would
    # write a row rootfs/fetchlock.sh reads with the other meaning.
    sha="${PINHASH["$(basename "$file")"]:-}"
    [ -n "$sha" ] || {
      echo "$(basename "$file"): built into the overlay repo but no source pin claims it" >&2
      echo "  ${OVERLAY_REPO#"$ROOT"/}/.stamps is stale or absent -> rebuild: make overlay" >&2
      exit 1
    }
  else
    sha="$(sha256sum "$file" | cut -d' ' -f1)"
  fi
  rows+="$name $ver $arch $src $sha"$'\n'
done

if [ "$missing" -gt 0 ]; then
  echo "$missing installed package(s) have no package file in ${CACHE#"$ROOT"/} or ${OVERLAY_REPO#"$ROOT"/}:" >&2
  printf '%s' "$unfiled" >&2
  echo "  the lock cannot describe a package it cannot hash. Likely cause: the pacman cache was" >&2
  echo "  cleared since the root was built -> rebuild: FORCE=1 NOVADECK_RESOLVE=1 install/mkroot.sh" >&2
  exit 1
fi

# Prebuilt rows, read from the marker mkroot.sh wrote into the tree (see the header on why this is
# the tree's own record rather than a re-walk of the pin files). Its columns are
# `name version sha256 kind dest strip mode`; only the first three reach the lock, and `arch` is
# the literal `any` because none of these is a pacman package with an architecture field.
prebuilts=0
if [ -s "$PREBUILT_MARKER" ]; then
  while read -r p_name p_ver p_sha _rest; do
    [ -n "$p_name" ] || continue
    rows+="$p_name $p_ver any prebuilt $p_sha"$'\n'
    prebuilts=$((prebuilts + 1))
  done < "$PREBUILT_MARKER"
fi

SNAPSHOT="$(grep -vE '^[[:space:]]*(#|$)' "$SNAPFILE" | tail -1)"
BUILDER="$(grep -vE '^[[:space:]]*(#|$)' "$PINFILE" | tail -1)"

{
  cat <<EOF
# novadeck INSTALLER package manifest — GENERATED by install/genlock.sh, do not hand-edit.
# Regenerate with \`make relock-installer\` after any change to install/pkgs.list; review the diff.
#
# This describes the INSTALLER image (install/mkroot.sh), NOT the image that ships on a device —
# that one is rootfs/manifest.lock. The two are separate artifacts on purpose: the installer
# carries partition and filesystem tools that no device ever gets, and a single lock covering both
# would stop meaning "this is what is on the device". See this generator's header.
#
# repo snapshot: $SNAPSHOT
# built in:      $BUILDER   (execution environment only — contributes no files)
#
# name version arch source sha256   (source: snapshot|novadeck|prebuilt)
# Every row carries a real hash: the root is bootstrapped from packages, so there is no content on
# the image that no package file put there. The hash column pins two different things, because
# these classes are pinned by genuinely different mechanisms:
#   snapshot/prebuilt  the FILE — the exact bytes fetched and installed or placed.
#   novadeck           the SOURCES — packages/inputhash.sh over that package's source.pin +
#     patches + local PKGBUILD. These are built here and are not bit-reproducible, so an artifact
#     hash would move on every rebuild from unchanged inputs. Rows sharing a hash come from one
#     split PKGBUILD (mesa emits three).
# There is no 'stripped' class here: the installer keeps its pacman and is never sealed.
EOF
  printf '%s' "$rows" | sort
} >"$LOCK"

echo "[novadeck] wrote ${LOCK#"$ROOT"/}: $(printf '%s' "$rows" | grep -c .) rows ($prebuilts prebuilt)" >&2
