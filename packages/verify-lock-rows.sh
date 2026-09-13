#!/usr/bin/env bash
# novadeck lock rows — do the manifests' `novadeck` rows still name the sources in packages/?
#
# BOTH LOCKS, because there are two and only one of them is in the obvious place. The installer
# medium carries gamescope (installer/ui is a Wayland client and gamescope is its display server,
# installer/pkgs.list:69), so a change under packages/gamescope invalidates rootfs/manifest.lock AND
# installer/manifest.lock, and they have to move together. 3e76935 relocked one of them; the other
# was caught by installer/mkroot.sh's own resolve — which runs AFTER the kernel, so installer/v0.0.8
# spent 56 minutes building 7.2.5 to reach a verdict decidable here in a second from a bare clone.
#
#   packages/verify-lock-rows.sh
#
# Runs in about a second, on any machine, from COMMITTED FILES ONLY: no work/, no overlay repo, no
# container, no network. That is the entire point — see below.
#
# WHY THIS EXISTS AS A SEPARATE, EARLIER CHECK. rootfs/fetchlock.sh already makes exactly this
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
# THE CHECK IS MEMBERSHIP: every novadeck row must carry a hash that SOME package in the tree
# currently produces. A row whose hash no package produces any more is stale, which is exactly the
# mesa case above — the two siblings kept a digest that had stopped existing the moment mesa's
# sources moved, so all three rows are caught even though nothing here knows mesa owns them.
#
# WHAT MEMBERSHIP CANNOT CATCH, stated so the gap is not mistaken for coverage: a row carrying a
# hash that is current for a DIFFERENT package. Ownership would answer that, and it used to be
# available — packages/*/artifact.pin listed each package's artifact filenames, so a filename could
# be traced back to its owner. Those pins were part of the artifact-store machinery retired
# 2026-08-04 and are gone. The stamps under work/repo/<arch>/.stamps/<name>.files are the only other
# complete mapping and they exist only after a build, which defeats the purpose of a check meant to
# run before one (this runs in `make test`, on a bare clone, with no work/ at all).
#
# WHAT THIS DELIBERATELY DOES NOT CHECK: the `snapshot`/`stripped` rows' sha256s (those are third
# party bytes, and confirming them means downloading them — fetchlock's job), and whether the lock's
# package SET is still the right closure (only a re-resolve can answer that: `make relock`).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCK="$ROOT/rootfs/manifest.lock"
INSTALLER_LOCK="$ROOT/installer/manifest.lock"

log() { printf '[lock] %s\n' "$*" >&2; }
die() { printf '[lock] %s\n' "$*" >&2; exit 1; }

pin_field() { sed -n "s/^$2:[[:space:]]*//p" "$1" | head -1; }

# --- what the tree says right now ------------------------------------------------------------
# Stable order (the glob), matching build-overlay.sh.
declare -A HASHOF=()     # package name -> current input hash
declare -A DIROF=()      # package name -> repo-relative dir, for error messages
shopt -s nullglob
for pin in "$ROOT"/packages/*/source.pin; do
  dir="$(dirname "$pin")"
  pname="$(pin_field "$pin" name)"
  [ -n "$pname" ] || die "${pin#"$ROOT"/}: missing name"
  HASHOF["$pname"]="$("$ROOT/packages/inputhash.sh" "$dir")"
  DIROF["$pname"]="${dir#"$ROOT"/}"
done
shopt -u nullglob
[ ${#HASHOF[@]} -gt 0 ] || die "no packages/*/source.pin found"

# The set of hashes the tree can currently produce. This is what a row is checked against.
declare -A VALID=()
for pname in "${!HASHOF[@]}"; do VALID["${HASHOF[$pname]}"]=1; done

# --- compare every novadeck row -------------------------------------------------------------
# Field 4 is the provenance class and 1/2/3 reconstruct the filename, exactly as fetchlock.sh does
# it. Explicit 5-field read so a future column cannot land in the last variable.
#
# Report every problem rather than dying on the first: this failure arrives in groups by nature —
# one source change moves every row of a split package — and seeing one row at a time is how
# "you updated 1 of 3" reads as three unrelated bugs.
fail=0

check_lock() {
  local lock="$1" relock="$2" rel="${1#"$ROOT"/}"
  local stale="" rows=0 name ver arch src sha file

  [ -f "$lock" ] || die "no lock: $rel"

  while read -r name ver arch src sha; do
    case "$name" in ''|'#'*) continue ;; esac
    [ "$src" = novadeck ] || continue
    rows=$((rows + 1))
    file="$name-$ver-$arch.pkg.tar.zst"
    if [ -z "${VALID["$sha"]:-}" ]; then
      stale+="  $name ($file): $sha"$'\n'
    fi
  done < "$lock"

  [ "$rows" -gt 0 ] || die "$rel has no novadeck rows — refusing to pass trivially"

  if [ -n "$stale" ]; then
    echo "[lock] $rel: these novadeck rows carry a hash NO package in the tree produces:" >&2
    printf '%s' "$stale" >&2
    echo "  A row's hash is packages/inputhash.sh over its OWNING package's committed sources, and one" >&2
    echo "  PKGBUILD can own several rows — a split package's rows all carry the pkgbase's hash and" >&2
    echo "  must move together. Updating only the row whose name matches the package directory is the" >&2
    echo "  mistake this check exists to catch (mesa emits five packages; the image installs three)." >&2
    echo "  Adopt the source change deliberately:  $relock" >&2
    fail=1
    return
  fi

  log "$rel: $rows novadeck row(s) carry a hash packages/ still produces"
}

check_lock "$LOCK" "make relock"
check_lock "$INSTALLER_LOCK" "make relock-installer"

[ "$fail" -eq 0 ] || exit 1
