#!/usr/bin/env bash
# Pre-seed fex-emu's pinned x86 sysroot packages into <destdir>: the Arch Linux Archive first, its
# mirror second.
#
#   packages/fex-emu/fetch-source.sh <destdir>
#
# build-overlay.sh runs this before makepkg (the packages/<name>/fetch-source.sh convention, see
# packages/mesa/fetch-source.sh). makepkg skips a source file that is already in the build dir, so
# dropping the right filename there is all a fallback takes; makepkg has none of its own.
#
# WHY A MIRROR. archive.archlinux.org is one host. MEASURED 2026-11-21: it answered ping but never
# completed a TLS handshake for hours, and the rolling mirrors had already rotated these exact
# builds out (glibc r24 pinned, r78 current), so nothing else served them. Arch lists one dedicated
# archive mirror in its infrastructure docs (archlinux/infrastructure docs/servers.md, "Archive
# Mirrors"): umea.archive.pkgbuild.com, same /packages/<l>/<name>/ layout.
#
# THE MIRROR IS NOT TRUSTED, IT IS VERIFIED: every file must match the sha256 the PKGBUILD pins,
# whichever host answered, and makepkg checks the same sha256 again once the file is in place. A
# mismatch is a hard failure, never a fallback to something else.
#
# This file is not an input of packages/inputhash.sh, so editing it moves no lock row.
set -euo pipefail

DEST="${1:?usage: fetch-source.sh <destdir>}"
PKGDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRIMARY=https://archive.archlinux.org
MIRROR=https://umea.archive.pkgbuild.com

# Top-level assignments only: sourcing a PKGBUILD defines its functions, it does not run them.
mapfile -t URLS < <(bash -c "source '$PKGDIR/PKGBUILD' >/dev/null 2>&1; printf '%s\n' \"\${source[@]}\"")
mapfile -t SUMS < <(bash -c "source '$PKGDIR/PKGBUILD' >/dev/null 2>&1; printf '%s\n' \"\${sha256sums[@]}\"")
[ "${#URLS[@]}" -gt 0 ] && [ "${#URLS[@]}" -eq "${#SUMS[@]}" ] \
  || { echo "ERROR: packages/fex-emu/PKGBUILD: ${#URLS[@]} sources vs ${#SUMS[@]} sha256sums" >&2; exit 1; }

mkdir -p "$DEST"

fetch() {  # <url> <out>
  rm -f "$2"
  curl --fail --location --connect-timeout 20 --retry 2 --retry-connrefused \
       --max-time 600 --output "$2" "$1"
}

for i in "${!URLS[@]}"; do
  url="${URLS[$i]}" sum="${SUMS[$i]}"
  case "$url" in "$PRIMARY"/*) ;; *) continue ;; esac   # only the archive sources; git is makepkg's
  out="$DEST/${url##*/}"                               # makepkg's own name for it: the URL basename
  verify() { printf '%s  %s\n' "$sum" "$out" | sha256sum --check --strict --status; }

  if [ -s "$out" ] && verify; then
    echo "[fex-emu] source: ${url##*/} already present and verified" >&2
    continue
  fi
  if ! fetch "$url" "$out"; then
    echo "[fex-emu] source: archive unreachable for ${url##*/}, trying $MIRROR" >&2
    fetch "$MIRROR${url#"$PRIMARY"}" "$out" || {
      echo "ERROR: ${url##*/} failed at BOTH $PRIMARY and $MIRROR." >&2
      exit 1; }
  fi
  verify || {
    echo "ERROR: ${url##*/} does not match the sha256 pinned in packages/fex-emu/PKGBUILD ($sum)." >&2
    echo "       Got: $(sha256sum "$out" | cut -d' ' -f1)" >&2
    rm -f "$out"
    exit 1; }
  echo "[fex-emu] source: ${url##*/} verified against the pinned sha256" >&2
done
