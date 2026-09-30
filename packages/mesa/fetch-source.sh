#!/usr/bin/env bash
# Fetch the pinned mesa release tarball into <destdir>, upstream first, mirror second.
#
#   packages/mesa/fetch-source.sh <destdir>
#
# THE ONE FETCH FOR ALL THREE MESA BUILDS. packages/mesa (host, via makepkg), packages/mesa-x86
# (FEX guest) and packages/mesa-android (Android guest) build the same tarball for three targets;
# before this file each fetched it with its own bare `curl`, so an upstream outage broke all three
# separately and a mirror would have had to be added three times.
#
# WHY A MIRROR AT ALL. archive.mesa3d.org is one machine (annarchy.freedesktop.org) with no CDN in
# front of it -- mesa.freedesktop.org is Fastly-fronted but fills from the same origin, so it goes
# down with it. MEASURED 2026-08-23: both unreachable for over half an hour, which is long enough
# to fail a cold build of all three drivers and, in CI, a whole release run. Nothing about that
# outage is unusual for freedesktop infrastructure.
#
# THE MIRROR IS NOT TRUSTED, IT IS VERIFIED. Whichever host answers, the tarball must match the
# sha256 in packages/mesa/PKGBUILD -- the same hash that was checked against Eric Engestrom's PGP
# signature when the version was pinned (see the long provenance note in the PKGBUILD; that
# reasoning is the root of trust and this file does not weaken it). A mirror serving anything else
# is a hard failure, not a fallback to upstream. So the mirror's only power is to make a build
# succeed that would otherwise have failed; it cannot change what gets built.
#
# WHY FEDORA'S LOOKASIDE. It carries the PRISTINE upstream tarball, byte-identical -- confirmed
# for 26.2.1 by downloading it and comparing to our pinned sha256. It is independently hosted, and
# it is not a distro repack (Debian's mesa is repacked, Gentoo's distfiles did not have 26.2.1 at
# all, and sources.archlinux.org does not rehost mesa).
#
# THE COST IS ONE EXTRA FIELD PER BUMP: the lookaside path embeds the tarball's SHA512, so
# ./mirror.pin carries it. That file is deliberately NOT source.pin -- see the note in it -- and
# the value is discoverable in one request. Getting it wrong costs a 404 on the fallback path
# only, never a wrong build; leaving it empty restores the old upstream-or-bust behaviour.
#
# WHY THE BUMP GUIDANCE IS NOT IN source.pin OR THE PKGBUILD, where a reader would look first:
# packages/inputhash.sh hashes both of those files -- comments included -- into manifest.lock's
# `novadeck` rows, so a pointer comment in either one would force a `make relock` (a full
# re-resolve of every package) for a value that cannot change what is built. The bump path
# announces itself instead: after a version bump the stale mirror hash 404s and the error below
# says exactly what to refresh.
#
# CONNECT TIMEOUTS ARE DELIBERATE AND SHORT. The outage above cost ~9 minutes per build to
# discover, because curl's default has no connect timeout and each of three retries sat for ~135s.
# A host that will not complete a TCP handshake in 20s is down; the point of a fallback is to
# reach it quickly.
set -euo pipefail

DEST="${1:?usage: fetch-source.sh <destdir>}"
PKGDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Top-level assignments only -- sourcing a PKGBUILD defines its functions, it does not run them.
# This is the same read packages/mesa-x86 has always done, so the URL and hash have exactly one
# home: the PKGBUILD that also builds the host driver.
URL="$(bash -c "source '$PKGDIR/PKGBUILD' >/dev/null 2>&1; echo \"\${source[0]}\"")"
SHA256="$(bash -c "source '$PKGDIR/PKGBUILD' >/dev/null 2>&1; echo \"\${sha256sums[0]}\"")"
: "${URL:?packages/mesa/PKGBUILD yielded no source url}"
: "${SHA256:?packages/mesa/PKGBUILD yielded no sha256}"
TARBALL="${URL##*/}"

MIRROR_SHA512="$(sed -n 's/^sha512:[[:space:]]*//p' "$PKGDIR/mirror.pin" | head -1)"
MIRROR_URL=""
[ -n "$MIRROR_SHA512" ] \
  && MIRROR_URL="https://src.fedoraproject.org/repo/pkgs/mesa/${TARBALL}/sha512/${MIRROR_SHA512}/${TARBALL}"

mkdir -p "$DEST"
OUT="$DEST/$TARBALL"

verify() { printf '%s  %s\n' "$SHA256" "$OUT" | sha256sum --check --strict --status; }

# Idempotent: a tarball already sitting in the destination with the right hash is the answer. This
# is what lets the makepkg path pre-seed its build directory, and it makes a re-run after a failed
# build cost nothing.
if [ -s "$OUT" ] && verify; then
  echo "[mesa] source: $TARBALL already present and verified" >&2
  exit 0
fi

fetch() {  # <url> <label>
  rm -f "$OUT"
  echo "[mesa] source: trying $2" >&2
  curl --fail --location --connect-timeout 20 --retry 2 --retry-connrefused \
       --max-time 1800 --output "$OUT" "$1"
}

if ! fetch "$URL" "upstream ($URL)"; then
  if [ -z "$MIRROR_URL" ]; then
    echo "ERROR: mesa source fetch failed at upstream, and packages/mesa/mirror.pin declares no" >&2
    echo "       sha512, so there is no fallback. Either upstream is down (check" >&2
    echo "       https://archive.mesa3d.org/ by hand) or the pinned version moved." >&2
    exit 1
  fi
  echo "[mesa] source: upstream unreachable, falling back to the mirror" >&2
  fetch "$MIRROR_URL" "mirror ($MIRROR_URL)" || {
    echo "ERROR: mesa source fetch failed at BOTH upstream and the mirror." >&2
    echo "       A 404 on the mirror usually means mirror.pin's sha512 is stale or the" >&2
    echo "       version is not in Fedora yet -- re-read it from" >&2
    echo "       https://src.fedoraproject.org/repo/pkgs/mesa/${TARBALL}/sha512/" >&2
    exit 1; }
fi

# Whichever host answered. A mirror that serves the wrong bytes fails the build; it never silently
# becomes the thing we build.
verify || {
  echo "ERROR: $TARBALL does not match the sha256 pinned in packages/mesa/PKGBUILD ($SHA256)." >&2
  echo "       Got: $(sha256sum "$OUT" | cut -d' ' -f1)" >&2
  echo "       Do NOT update the pin to match -- that hash was verified against the upstream PGP" >&2
  echo "       signature (see the provenance note in the PKGBUILD)." >&2
  rm -f "$OUT"
  exit 1; }

echo "[mesa] source: $TARBALL verified against the pinned sha256" >&2
