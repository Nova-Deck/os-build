#!/usr/bin/env bash
# novadeck overlay input hash — the one definition of "which sources is this package built from".
#
#   packages/inputhash.sh <package-dir>     # e.g. packages/mesa
#
# Prints a 64-char hex digest of the package's COMMITTED build inputs: its source.pin, the
# patches the pin declares, and the local PKGBUILD if it has one. Nothing else — everything
# makepkg fetches is downstream of these files (the pin carries pkgbuild_ref, a local PKGBUILD
# carries pkgver + the upstream source's own sha256sums), so hashing them pins the build.
#
# FIVE CALLERS, ONE FORMULA, and they have to agree or the build breaks in confusing ways:
#
#   packages/build-overlay.sh   incremental-rebuild cache key (work/repo/<arch>/.stamps/<n>.hash)
#   images/genmanifest.sh       writes it into images/manifest.lock as the `novadeck` rows' pin
#   images/fetchlock.sh         re-derives it and refuses the install when the lock disagrees
#   packages/overlay-store.sh   the GHCR tag each package is published under and retrieved by
#   packages/verify-pins.sh     ties an artifact.pin to the sources it was built from, so a pin
#                               that predates a source change reports as STALE rather than as a
#                               byte mismatch
#
# WHY THIS IS THE `novadeck` ROWS' PIN AND NOT THE BUILT ARTIFACT'S SHA256. Our overlay builds
# are not bit-reproducible: rebuilding from identical inputs moves every artifact's sha256, so an
# artifact hash in the lock only ever verified on the machine that last ran `make relock` — it
# said "you rebuilt", never "the inputs changed", and it made a clean CI runner fail every run.
# This hash says the thing that is actually true across machines: these bytes were built from the
# reviewed sources. It is a WEAKER claim about the artifact and a STRONGER one about provenance.
#
# The artifact claim is made separately, by packages/*/artifact.pin, and only for RELEASE builds —
# which is why it can be a byte hash at all: those bytes come from the store, not from whichever
# machine happens to be building. Two questions, two files, neither overloaded.
#
# PATH INDEPENDENCE IS THE WHOLE POINT, and it is the one thing easy to get wrong here. The
# obvious `sha256sum "${inputs[@]}" | sha256sum` is WRONG: sha256sum prints "<hash>  <path>", so
# the digest follows the checkout directory and a developer's /home/... never agrees with a CI
# runner's workspace. Hash the CONTENT COLUMN only. (That was the real bug in the formula this
# replaced — it was inlined in build-overlay.sh, where a per-machine cache key made it harmless,
# and it would have silently defeated the lock the moment the value crossed a machine.)
#
# Filenames still count, just indirectly: the patch list and the PKGBUILD name are fields IN
# source.pin, which is itself hashed, so renaming a patch moves the digest.
set -euo pipefail

DIR="${1:?usage: packages/inputhash.sh <package-dir>}"
PIN="$DIR/source.pin"
[ -f "$PIN" ] || { echo "no source.pin in $DIR" >&2; exit 1; }

pin_field() { sed -n "s/^$2:[[:space:]]*//p" "$1" | head -1; }

name="$(pin_field "$PIN" name)"
: "${name:?$PIN: missing name}"

# Declared order, not glob order: the pin lists its patches in application order, and a stable
# input order is what makes the digest reproducible rather than filesystem-dependent.
inputs=("$PIN")
for p in $(pin_field "$PIN" patches); do
  src="$DIR/patches/$p"
  [ -f "$src" ] || { echo "$name: missing patch $src (declared in $PIN)" >&2; exit 1; }
  inputs+=("$src")
done
local_pb="$(pin_field "$PIN" pkgbuild_local)"
if [ -n "$local_pb" ]; then
  [ -f "$DIR/$local_pb" ] || { echo "$name: missing local PKGBUILD $DIR/$local_pb (declared in $PIN)" >&2; exit 1; }
  inputs+=("$DIR/$local_pb")
fi

sha256sum "${inputs[@]}" | cut -d' ' -f1 | sha256sum | cut -c1-64
