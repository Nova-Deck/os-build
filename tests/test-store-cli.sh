#!/usr/bin/env bash
# Offline checks for the two store CLIs: the legendary and gogdl overlay packages, their pins, and
# their place in PKGS and the lock.
#
#   tests/test-store-cli.sh
#
# WHY THIS FILE EXISTS. Both packages land INERT — alien-games milestone 1 ships them with nothing
# on the image calling either one — so every ordinary signal that a package is wrong is absent.
# There is no service to fail, no UI to go blank, no journal line. A misspelled dependency, a pin
# that names a different package than its PKGBUILD builds, or a name that never made it into PKGS
# would sit in the tree looking finished until milestone 3 tried to use it. These are all decisions
# the committed files make about each other, which is exactly what can be checked on the host with
# no root, no device, no container and no network.
#
# THE ONE CHECK THIS CANNOT DO, and it is the one a bump is most likely to get wrong: whether
# `_xdelta_commit` still matches the submodule pointer in upstream's .gitmodules at the pinned tag.
# That needs the network, and an offline suite that reaches out is a suite that fails on a plane.
# What is checked here is internal coherence — the commit in the variable is the commit in the URL,
# so the two cannot drift apart. Matching them to UPSTREAM is a human step at bump time, and
# packages/gogdl/source.pin says so where whoever does the bump will be reading.
#
# The other things this deliberately CANNOT prove: that either binary runs, that either can reach
# its store, and that gogdl's C extension compiled. Those are the build and the HW gate.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKGDIR="$ROOT/packages"
CUSTOMIZE="$ROOT/rootfs/customize-base.sh"
LOCK="$ROOT/rootfs/manifest.lock"

PASS=0; FAIL=0; SKIP=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

pin_field() { sed -n "s/^$2:[[:space:]]*//p" "$1" | head -1; }

# pkgbuild_field <file> <var> — the RHS of a top-level `var=...` assignment, quotes stripped. Only
# used on scalars (pkgname, pkgver, arch, _xdelta_commit); arrays go through pkgbuild_array.
pkgbuild_field() {
  sed -n "s/^$2=//p" "$1" | head -1 | tr -d "'\"()"
}

# pkgbuild_array <file> <var> — the items of a top-level `var=(...)` array, one per line.
#
# Written with awk rather than `sed -n '/^var=(/,/)/p'` because that range does NOT close on the
# line it opens on: a single-line `depends=('python' 'python-requests')` runs on to the NEXT line
# holding a ')' and swallows makedepends whole. Nor with `tr -d "depends=()'"`, which deletes those
# CHARACTERS everywhere and turns python-requests into ytho-rqut. Both were written here first and
# both passed a green-looking suite while checking the wrong strings.
pkgbuild_array() {
  awk -v v="$2" '
    index($0, v "=(") == 1 { inarr = 1; sub("^" v "=\\(", ""); }
    inarr { line = $0; sub(/\).*$/, "", line); print line; if ($0 ~ /\)/) exit }
  ' "$1" | tr -d "'\"" | tr ' ' '\n' | grep -v '^$'
}

# --- both packages: pin and recipe agree ---------------------------------------------------
for pkg in legendary gogdl; do
  pin="$PKGDIR/$pkg/source.pin"
  pkgbuild="$PKGDIR/$pkg/PKGBUILD"

  if [ ! -f "$pin" ] || [ ! -f "$pkgbuild" ]; then
    bad "$pkg: source.pin and PKGBUILD must both exist (found pin=$([ -f "$pin" ] && echo y || echo n) pkgbuild=$([ -f "$pkgbuild" ] && echo y || echo n))"
    continue
  fi
  ok "$pkg: source.pin + PKGBUILD present"

  # The pin's name IS the work/ build dir and the repo entry. A pin naming one package and a
  # PKGBUILD building another produces an artifact nothing resolves, and build-overlay says
  # nothing about it.
  [ "$(pin_field "$pin" name)" = "$pkg" ] \
    && ok "$pkg: source.pin name matches the directory" \
    || bad "$pkg: source.pin name is '$(pin_field "$pin" name)', expected '$pkg'"

  [ "$(pkgbuild_field "$pkgbuild" pkgname)" = "$pkg" ] \
    && ok "$pkg: PKGBUILD pkgname matches the pin" \
    || bad "$pkg: PKGBUILD pkgname is '$(pkgbuild_field "$pkgbuild" pkgname)', expected '$pkg'"

  # Local recipe, not a fetched holo one: neither package exists in any holo repo, so the
  # pkgbuild_repo/path/ref triple would have nothing to fetch.
  [ "$(pin_field "$pin" pkgbuild_local)" = "PKGBUILD" ] \
    && ok "$pkg: pin declares the local PKGBUILD" \
    || bad "$pkg: pin has no 'pkgbuild_local: PKGBUILD' (a fetched pin would need repo/path/ref)"

  # pkgrel_suffix is what makes pacman prefer our build on a later upgrade. It must be an integer;
  # build-overlay turns N into pkgrel N.<suffix>.
  case "$(pin_field "$pin" pkgrel_suffix)" in
    ''|*[!0-9]*) bad "$pkg: pkgrel_suffix must be an integer, got '$(pin_field "$pin" pkgrel_suffix)'" ;;
    *)           ok  "$pkg: pkgrel_suffix is an integer" ;;
  esac

  grep -q '^sha256sums=' "$pkgbuild" \
    && ok "$pkg: sources are pinned by sha256" \
    || bad "$pkg: no sha256sums — an upstream retag would go unnoticed"

  # Every dependency has to resolve. The lock is the list of what the image actually installs, so a
  # name absent from it is a name pacman could not find — which is how gtk2 was learned.
  deps="$(pkgbuild_array "$pkgbuild" depends)"
  missing=""
  for d in $deps; do
    grep -qE "^${d} " "$LOCK" || missing="$missing $d"
  done
  if [ -n "$missing" ]; then
    bad "$pkg: depends not present in rootfs/manifest.lock:$missing (relock, or the name is wrong)"
  else
    ok "$pkg: every depends name has a row in rootfs/manifest.lock"
  fi

  # In PKGS, or the package is built and never installed.
  grep -qE "^PKGS=\(.*[( ]${pkg}[ )]" "$CUSTOMIZE" \
    && ok "$pkg: named in PKGS" \
    || bad "$pkg: not in PKGS — it would build into the overlay and never reach the image"
done

# --- legendary is arch-independent, gogdl is not -------------------------------------------
# This is the distinction the PRD got wrong before the packages existed ("the store CLIs are
# Python"), and it is load-bearing: gogdl compiles a C extension, so an `any` package would ship a
# .so built for whatever built it.
[ "$(pkgbuild_field "$PKGDIR/legendary/PKGBUILD" arch)" = "any" ] \
  && ok "legendary: arch=any (pure Python, no compiled artifact)" \
  || bad "legendary: arch is '$(pkgbuild_field "$PKGDIR/legendary/PKGBUILD" arch)', expected any"

[ "$(pkgbuild_field "$PKGDIR/gogdl/PKGBUILD" arch)" = "aarch64" ] \
  && ok "gogdl: arch=aarch64 (it builds the gogdl_xdelta3 extension)" \
  || bad "gogdl: arch is '$(pkgbuild_field "$PKGDIR/gogdl/PKGBUILD" arch)', expected aarch64"

# --- gogdl: the submodule trap --------------------------------------------------------------
GOGDL="$PKGDIR/gogdl/PKGBUILD"
XCOMMIT="$(pkgbuild_field "$GOGDL" _xdelta_commit)"

case "$XCOMMIT" in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f])
    ok "gogdl: _xdelta_commit is a full 40-char sha" ;;
  *)
    bad "gogdl: _xdelta_commit is '$XCOMMIT' — must be a full 40-char commit, not a branch or tag" ;;
esac

# Two sources, because GitHub ships the submodule directory EMPTY. One source is the failure mode
# this package exists to avoid re-discovering. Counted by the `name::url` separator every entry
# here uses, NOT by a literal `::http` — the first source builds its URL from $url, so a grep for
# the scheme sees one of the two and reports a shape that is not there.
gogdl_sources="$(pkgbuild_array "$GOGDL" source | grep -c '::')"
[ "$gogdl_sources" -eq 2 ] \
  && ok "gogdl: two sources (the tarball's xdelta3/ is an empty submodule dir)" \
  || bad "gogdl: expected 2 sources, found $gogdl_sources — a one-source build cannot compile the extension"

[ "$(pkgbuild_array "$GOGDL" sha256sums | grep -cE "^[0-9a-f]{64}$")" -eq 2 ] \
  && ok "gogdl: both sources carry a sha256" \
  || bad "gogdl: sha256sums does not cover both sources"

# The variable and the URL cannot drift apart. (Matching either to UPSTREAM is the bump-time human
# step — see this file's header.)
grep -q "xdelta/archive/\${_xdelta_commit}.tar.gz" "$GOGDL" \
  && ok "gogdl: the xdelta source URL is built from _xdelta_commit, so they cannot disagree" \
  || bad "gogdl: the xdelta source URL does not interpolate _xdelta_commit — the pin and the fetch can drift"

# prepare() has to put the xdelta repo root AT xdelta3/, one level: gogdl_xdelta3.c includes
# <xdelta3/xdelta3.h> and pyproject sets include-dirs = ["xdelta3"].
sed -n '/^prepare()/,/^}/p' "$GOGDL" | grep -q 'mv .*xdelta3$' \
  && ok "gogdl: prepare() moves the xdelta tree to xdelta3/" \
  || bad "gogdl: prepare() does not place the xdelta tree at xdelta3/ — the include path would not resolve"

# rmdir, not rm -rf: if upstream ever ships real content there, this must fail loudly.
sed -n '/^prepare()/,/^}/p' "$GOGDL" | grep -q 'rmdir xdelta3' \
  && ok "gogdl: prepare() rmdirs the placeholder (fails loudly if it is ever non-empty)" \
  || bad "gogdl: prepare() should rmdir the empty placeholder, not force-remove it"

# --- the suite is wired in -------------------------------------------------------------------
grep -q 'test-store-cli.sh' "$ROOT/Makefile" \
  && ok "this suite is wired into make test (a suite nothing runs is documentation)" \
  || bad "tests/test-store-cli.sh is not in the Makefile test target"

printf '\n%s: %d passed, %d failed, %d skipped\n' "$(basename "$0")" "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
