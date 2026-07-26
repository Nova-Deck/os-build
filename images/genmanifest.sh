#!/usr/bin/env bash
# novadeck package manifest generator -> images/manifest.lock  (Phase 4a step 1).
#
# Records EXACTLY what the customized base contains, so a base rebuild is a reviewable
# diff instead of a 395-package black box. Runs on the HOST against the already-exported
# base tree — no container, no emulation: everything it needs is a file.
#
#   images/genmanifest.sh [base-rootfs-dir]     (default: work/base)
#
# WHY sha256 and not just name-version: our mirror pin used to be the UNSUFFIXED snapshot
# path, which is an alias tracking the newest revision (see snapshot.pin). Revisions can
# republish the same package version built from the same source at a different pkgrel-less
# artifact, so equal versions do NOT prove equal package files. The hash is the only field
# that actually detects that.
#
# Five provenance classes, because they are pinned by genuinely different mechanisms and
# conflating them would overstate what we verify:
#
#   snapshot  installed from the pinned repo revision; hash = the .pkg.tar.zst we installed
#   novadeck  built from source by packages/build-overlay.sh; hash = our own build artifact
#   base      arrived INSIDE the pinned base image and was never downloaded, so there is no
#             package file to hash. Pinned by base.digest (itself a sha256) — recorded with
#             a '-' hash rather than silently omitted, because they are on the image.
#   prebuilt  not pacman packages at all: the tarballs/blobs in packages/*/prebuilt.pin,
#             already sha256-pinned there. Carried so the lock covers the whole image.
#   stripped  present in the tree this reads, ABSENT from the release image: named in
#             images/seal.list and deleted by images/seal-rootfs.sh (Phase 4a step 3).
#
# That last class is the one thing here that is not simply "what the database says". Sealing
# deletes files while PRESERVING the database as provenance, so the database keeps listing
# packages the shipped image no longer has — left alone, the lock and the image would diverge
# silently. Reading the same declaration the sealer reads keeps one artifact describing the
# real image, and makes a change to what we strip show up in the same reviewable diff as a
# change to what we install. This file learns one input; it learns nothing about sealing.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASE="${1:-${BASE_ROOTFS:-$ROOT/work/base}}"
LOCK="$ROOT/images/manifest.lock"
CACHE="$ROOT/work/pacman-cache"
OVERLAY_REPO="$ROOT/work/repo/aarch64"
LOCALDB="$BASE/var/lib/pacman/local"
MARKER="$BASE/usr/lib/novadeck/pkgs"
SEALLIST="$ROOT/images/seal.list"

[ -d "$LOCALDB" ] || { echo "no pacman local db under $BASE (customize the base first)" >&2; exit 1; }

# The lock describes the RELEASE image — the tree the step-4 seal guard runs against. A test base
# additionally carries the on-device bring-up tooling (TEST_PKGS in customize-base.sh), and
# locking that would both overstate what ships and put the tooling on the release install path.
# customize-base.sh records `test:1` in the marker precisely so this is detectable rather than
# inferred from a package-name blocklist that would drift from TEST_PKGS.
if grep -qx 'test:1' "$MARKER" 2>/dev/null; then
  echo "refusing to relock a TEST base: ${MARKER#"$ROOT"/} says test:1" >&2
  echo "  rebuild release first (unset NOVADECK_TEST), then \`make relock\`" >&2
  exit 1
fi

# Index the two package directories ONCE by exact filename. Deliberately not a per-package
# glob: the cache accumulates stale versions (e.g. mesa 26.1.4 alongside 26.1.5), so a glob
# would happily match the wrong artifact. Exact name-version-arch or nothing.
declare -A PKGFILE
index_dir() {
  local dir="$1" src="$2" f
  [ -d "$dir" ] || return 0
  for f in "$dir"/*.pkg.tar.zst; do
    [ -e "$f" ] || continue
    PKGFILE["$(basename "$f")"]="$src	$f"
  done
}
# Cache first, overlay second, so the overlay OVERWRITES on collision — matching pacman.conf
# repo ORDER, where the overlay repo sits ahead of the snapshot repos and order beats version.
index_dir "$CACHE" snapshot
index_dir "$OVERLAY_REPO" novadeck

# The seal's `pkg` rows (images/seal.list) — the packages that are in the tree below but not on
# the release image. Only the row kind is read; expanding a name to its files is the sealer's
# job, not this one's.
declare -A STRIPPED
[ -f "$SEALLIST" ] || { echo "no removal list: $SEALLIST" >&2; exit 1; }
while read -r kind value _; do
  case "$kind" in pkg) STRIPPED["$value"]=1 ;; esac
done < "$SEALLIST"

# One row per installed package, read straight out of the local db's desc files. Field order
# in desc is not guaranteed, so each is matched by its own %KEY% rather than by position.
desc_field() { sed -n "/^%$2%\$/{n;p;q}" "$1"; }

rows=""
missing=0
stripped_seen=0
for d in "$LOCALDB"/*/; do
  desc="$d/desc"
  [ -f "$desc" ] || continue
  name="$(desc_field "$desc" NAME)"
  ver="$(desc_field "$desc" VERSION)"
  arch="$(desc_field "$desc" ARCH)"
  [ -n "$name" ] && [ -n "$ver" ] || { echo "malformed desc: $desc" >&2; exit 1; }
  arch="${arch:-any}"

  entry="${PKGFILE["$name-$ver-$arch.pkg.tar.zst"]:-}"
  if [ -n "$entry" ]; then
    src="${entry%%	*}"; file="${entry#*	}"
    sha="$(sha256sum "$file" | cut -d' ' -f1)"
  else
    # Came with the base image: covered by base.digest, no artifact of ours to hash.
    src=base; sha='-'
    missing=$((missing + 1))
  fi

  # Reclassify what the seal removes. Every package on the list arrives inside the base image
  # today (pacman and archlinux-keyring are `base` metapackage dependencies — which is exactly
  # why sealing has to delete files rather than run pacman -R), so nothing installable is being
  # hidden here. Refuse the case that WOULD hide something: a stripped snapshot/novadeck row
  # still has to be fetched and installed before it can be deleted, and images/fetchlock.sh
  # keys that off the class — so silently rewriting it would drop the package from the install
  # and leave the seal declaring a name that never arrived.
  if [ -n "${STRIPPED["$name"]:-}" ]; then
    if [ "$src" != base ]; then
      echo "seal.list strips '$name', but it installs from '$src' — not supported yet" >&2
      echo "  fetchlock.sh treats 'stripped' as non-installable; teach it the install path first" >&2
      exit 1
    fi
    src=stripped
    stripped_seen=$((stripped_seen + 1))
  fi
  rows+="$name $ver $arch $src $sha"$'\n'
done

# A name on the removal list that is not installed means the list has drifted from the tree,
# and the seal would fail the same way mid-build. Catch it here, at relock, where the fix is
# a one-line edit rather than a 20-minute rebuild.
if [ "$stripped_seen" -ne "${#STRIPPED[@]}" ]; then
  echo "${SEALLIST#"$ROOT"/} declares ${#STRIPPED[@]} packages, only $stripped_seen are installed:" >&2
  for p in "${!STRIPPED[@]}"; do
    grep -q "^$p " <<<"$rows" || echo "  $p" >&2
  done
  exit 1
fi

# Prebuilt pins: name/version/sha256 are already declared and host-verified by
# customize-base.sh, so read them from the pin rather than re-deriving.
pin_field() { sed -n "s/^$2:[[:space:]]*//p" "$1" | head -1; }
for pin in "$ROOT"/packages/*/prebuilt.pin; do
  [ -e "$pin" ] || continue
  p_name="$(pin_field "$pin" name)"
  p_ver="$(pin_field "$pin" version)"
  p_sha="$(pin_field "$pin" sha256)"
  [ -n "$p_name" ] && [ -n "$p_sha" ] || { echo "$pin: missing name/sha256" >&2; exit 1; }
  rows+="$p_name ${p_ver:--} - prebuilt $p_sha"$'\n'
done

snapshot="$(grep -vE '^[[:space:]]*(#|$)' "$ROOT/snapshot.pin" 2>/dev/null | tail -1 || true)"
basedigest="$(grep -vE '^[[:space:]]*(#|$)' "$ROOT/base.digest" | tail -1)"

{
  echo "# novadeck package manifest — GENERATED by images/genmanifest.sh, do not hand-edit."
  echo "# Regenerate with \`make relock\` after any deliberate package change; review the diff."
  echo "#"
  echo "# base image:    $basedigest"
  echo "# repo snapshot: ${snapshot:-<unpinned>}"
  echo "#"
  echo "# name version arch source sha256   (source: snapshot|novadeck|base|prebuilt|stripped)"
  echo "# 'base' rows carry no hash: they ship inside the base image, pinned by its digest."
  echo "# 'stripped' rows are in the build tree but NOT on the image: images/seal.list removes them."
  printf '%s' "$rows" | LC_ALL=C sort
} >"$LOCK"

echo "[novadeck] manifest -> ${LOCK#"$ROOT"/}" >&2
awk '!/^#/ {n[$4]++; t++} END {for (s in n) printf "  %-9s %4d\n", s, n[s]; printf "  %-9s %4d\n", "TOTAL", t}' "$LOCK" >&2
