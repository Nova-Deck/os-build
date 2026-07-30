#!/usr/bin/env bash
# novadeck lock rows — do images/manifest.lock's `novadeck` rows still name the sources in packages/?
#
#   packages/verify-lock-rows.sh
#
# Runs in about a second, on any machine, from COMMITTED FILES ONLY: no work/, no overlay repo, no
# container, no network. That is the entire point — see below.
#
# WHY THIS EXISTS AS A SEPARATE, EARLIER CHECK. images/fetchlock.sh already makes exactly this
# comparison and refuses to install when it fails, so nothing here is a new claim. What is new is
# WHEN it can be made. fetchlock needs a populated work/repo/<arch> plus the ~382 snapshot packages
# it verifies alongside ours, so the first thing that runs it on a clean machine is the overlay
# pipeline's cold-machine retrieval job — after `plan`, after up to several hours of aarch64
# compiles, and after publishing to the store. A wrong lock row is decided by two files a reviewer
# can read; waiting until an arm64 runner has finished to find out is a post-mortem dressed as a
# check, which is the same complaint fetchlock's own header makes about the shape it replaced.
#
# THE FAILURE THIS WAS WRITTEN FOR (ab3121b, fixed in 5f15a19). A commit moved packages/mesa's
# PKGBUILD and updated one manifest.lock row: the one whose name matched the package DIRECTORY. The
# mesa PKGBUILD emits five packages and the image installs three, and all three rows carry the
# pkgbase's input hash. `mesa` moved to the new hash; `vulkan-freedreno` and
# `vulkan-mesa-device-select` kept the old one, so the lock asserted two different provenances for
# artifacts built in a single pass. The same commit's fex-emu row was correct for no better reason
# than fex-emu emitting one package. One-directory-one-row is the wrong mental model and it looks
# right on 7 of our 8 packages.
#
# TWO CHECKS, AND THE SECOND IS THE FALLBACK RATHER THAN THE POINT:
#
#   attributed    The row's artifact filename is claimed by some packages/*/artifact.pin, so we know
#                 WHICH package owns it and can require the row to carry that package's current
#                 hash. This is the check that names mesa when a mesa sibling is stale.
#
#   membership    No pin claims that filename — normal right after a pkgver bump, since the pins
#                 still list the previous version's filenames. Ownership is unknown, so all we can
#                 require is that the row's hash is the current hash of SOME package. That still
#                 catches a stale row (a hash no package produces any more); it cannot catch a row
#                 attributed to the wrong package. Degraded, never silent: the count is reported.
#
# WHY OWNERSHIP COMES FROM THE PINS AND NOT FROM work/repo/<arch>/.stamps/<name>.files. The stamps
# are the only COMPLETE mapping — one PKGBUILD can emit several packages and only the builder knows
# which — but they exist only after a build, which would defeat the purpose of a check meant to run
# before one. packages/verify-pins.sh reaches for the pins over the stamps on its verify path for a
# related reason (the stamps are the builder's claim about itself); here it is availability. Neither
# script trusts a stamp to describe a tree it did not build.
#
# WHAT THIS DELIBERATELY DOES NOT CHECK: the `snapshot`/`stripped` rows' sha256s (those are third
# party bytes, and confirming them means downloading them — fetchlock's job), the artifact BYTES of
# our own packages (packages/verify-pins.sh, release builds only), and whether the lock's package
# SET is still the right closure (only a re-resolve can answer that: `make relock`).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCK="$ROOT/images/manifest.lock"

log() { printf '[lock] %s\n' "$*" >&2; }
die() { printf '[lock] %s\n' "$*" >&2; exit 1; }

pin_field() { sed -n "s/^$2:[[:space:]]*//p" "$1" | head -1; }

[ -f "$LOCK" ] || die "no lock: ${LOCK#"$ROOT"/}"

# --- what the tree says right now ------------------------------------------------------------
# Stable order (the glob), matching build-overlay.sh, overlay-store.sh and verify-pins.sh.
declare -A HASHOF=()     # package name -> current input hash
declare -A DIROF=()      # package name -> repo-relative dir, for error messages
declare -A OWNER=()      # artifact filename -> owning package name
shopt -s nullglob
for pin in "$ROOT"/packages/*/source.pin; do
  dir="$(dirname "$pin")"
  pname="$(pin_field "$pin" name)"
  [ -n "$pname" ] || die "${pin#"$ROOT"/}: missing name"
  HASHOF["$pname"]="$("$ROOT/packages/inputhash.sh" "$dir")"
  DIROF["$pname"]="${dir#"$ROOT"/}"

  # artifact.pin is optional here: a package with no pin yet simply contributes no ownership, and
  # its rows fall through to the membership check below.
  apin="$dir/artifact.pin"
  [ -f "$apin" ] || continue
  while read -r kind _sha file; do
    [ "$kind" = "artifact:" ] || continue
    [ -n "$file" ] || die "${apin#"$ROOT"/}: malformed artifact line"
    OWNER["$file"]="$pname"
  done < "$apin"
done
shopt -u nullglob
[ ${#HASHOF[@]} -gt 0 ] || die "no packages/*/source.pin found"

# The set of hashes the tree can currently produce, for the membership fallback.
declare -A VALID=()
for pname in "${!HASHOF[@]}"; do VALID["${HASHOF[$pname]}"]=1; done

# --- compare every novadeck row -------------------------------------------------------------
# Field 4 is the provenance class and 1/2/3 reconstruct the filename, exactly as fetchlock.sh and
# verify-pins.sh do it. Explicit 5-field read so a future column cannot land in the last variable.
#
# Report every problem rather than dying on the first: this failure arrives in groups by nature —
# one source change moves every row of a split package — and seeing one row at a time is how
# "you updated 1 of 3" reads as three unrelated bugs.
stale=""        # hash no package produces any more
misattributed=""  # owned by a package whose hash is different
rows=0 attributed=0 unattributed=0
while read -r name ver arch src sha; do
  case "$name" in ''|'#'*) continue ;; esac
  [ "$src" = novadeck ] || continue
  rows=$((rows + 1))
  file="$name-$ver-$arch.pkg.tar.zst"

  owner="${OWNER["$file"]:-}"
  if [ -n "$owner" ]; then
    attributed=$((attributed + 1))
    want="${HASHOF["$owner"]}"
    if [ "$sha" != "$want" ]; then
      misattributed+="  $name ($file)"$'\n'
      misattributed+="    lock: $sha"$'\n'
      misattributed+="    tree: $want   (${DIROF[$owner]}: source.pin + patches + PKGBUILD)"$'\n'
    fi
    continue
  fi

  unattributed=$((unattributed + 1))
  if [ -z "${VALID["$sha"]:-}" ]; then
    stale+="  $name ($file): $sha"$'\n'
  fi
done < "$LOCK"

[ "$rows" -gt 0 ] || die "${LOCK#"$ROOT"/} has no novadeck rows — refusing to pass trivially"

fail=0

if [ -n "$misattributed" ]; then
  echo "[lock] these novadeck rows name sources that have MOVED:" >&2
  printf '%s' "$misattributed" >&2
  echo "  A row's hash is packages/inputhash.sh over its OWNING package's committed sources, and one" >&2
  echo "  PKGBUILD can own several rows — a split package's rows all carry the pkgbase's hash and" >&2
  echo "  must move together. Updating the row whose name matches the package directory is the" >&2
  echo "  mistake this check exists to catch." >&2
  echo "  Adopt the source change deliberately:  make relock" >&2
  fail=1
fi

if [ -n "$stale" ]; then
  echo "[lock] these novadeck rows carry a hash NO package in the tree produces:" >&2
  printf '%s' "$stale" >&2
  echo "  No packages/*/artifact.pin claims these filenames, so the owning package could not be" >&2
  echo "  named — expected right after a pkgver bump, when the pins still list the old version." >&2
  echo "  Either way the sources these rows describe are gone:  make relock" >&2
  fail=1
fi

[ "$fail" -eq 0 ] || exit 1

# Say which mode each row was checked in. An all-unattributed pass is a WEAKER statement than an
# all-attributed one, and a check that reports both identically invites trusting the weak one.
msg="$rows novadeck row(s) agree with packages/ ($attributed attributed"
[ "$unattributed" -gt 0 ] && msg+=", $unattributed by hash membership only"
log "$msg)"
