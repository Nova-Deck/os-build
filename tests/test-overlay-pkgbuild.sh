#!/usr/bin/env bash
# Offline checks for the overlay builder's PKGBUILD edit (packages/overlay-pkgbuild.py) and for
# makepkg's integrity flags in packages/build-overlay.sh (#150).
#
#   tests/test-overlay-pkgbuild.sh
#
# WHY THIS FILE EXISTS. build-overlay.sh appends the pin's patches to a recipe's source=(). makepkg
# checks every source against every checksum array, entry by entry, so each injected patch needs a
# 'SKIP' in each array, or the build fails. That used to be answered with `makepkg --skipinteg`,
# which turned EVERY checksum off: no upstream tarball in the overlay was ever verified, and a stale
# checksum in a PKGBUILD built without complaint (gogdl's check-dry-run.py, 2026-11-19). These
# checks keep the arrays aligned for every real recipe, and keep --skipinteg out.
#
# Bash and python3 only; nothing is fetched or built.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EDIT="$ROOT/packages/overlay-pkgbuild.py"
BUILDER="$ROOT/packages/build-overlay.sh"
PASS=0
FAIL=0
ok()  { echo "  ok   $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }
check() { if eval "$1"; then ok "$2"; else bad "$2"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# The lengths makepkg compares: source=() and each generic checksum array, after sourcing.
lengths() {
  ( set +u; CARCH=aarch64; srcdir=/nonexistent
    # shellcheck disable=SC1090
    source "$1" >/dev/null 2>&1
    printf 'source=%s' "${#source[@]}"
    for k in ck md5 sha1 sha224 sha256 sha384 sha512 b2; do
      declare -p "${k}sums" >/dev/null 2>&1 || continue
      eval "printf ' %s=%s' ${k}sums \${#${k}sums[@]}"
    done )
}
# True when every declared generic array is as long as source=(), and some array is declared
# whenever there is a source (makepkg refuses sources with no checksums: "Integrity checks are
# missing").
aligned() {
  local l n arrays; l="$(lengths "$1")"; n="${l%% *}"; n="${n#source=}"
  arrays=""; [ "$l" = "${l#* }" ] || arrays="${l#* }"
  [ -n "$arrays" ] || { [ "$n" = 0 ]; return; }
  for kv in $arrays; do [ "${kv#*=}" = "$n" ] || return 1; done
}
skips() {  # how many trailing SKIPs the named array ends with
  ( set +u; source "$1" >/dev/null 2>&1; eval "a=(\"\${${2}[@]}\")"; c=0
    for ((i=${#a[@]}-1; i>=0; i--)); do [ "${a[i]}" = SKIP ] || break; c=$((c+1)); done; echo "$c" )
}

echo "== the edit on fixtures"
cat > "$TMP/one" <<'EOF'
pkgname=one
pkgrel=3
source=("https://example.org/one-1.0.tar.gz" "one.conf")
sha256sums=('aaaa'
            'bbbb')
prepare() {
  cd "one-1.0"
}
EOF
python3 "$EDIT" "$TMP/one" --suffix 1 a.patch b.patch
check 'grep -qx "pkgrel=3.1" "$TMP/one"' "pkgrel gets the pin's suffix"
check '[ "$(lengths "$TMP/one")" = "source=4 sha256sums=4" ]' "two patches: source and sha256sums both grow by two ($(lengths "$TMP/one"))"
check '[ "$(skips "$TMP/one" sha256sums)" = 2 ] && grep -q "aaaa" "$TMP/one"' "the real sums stay; the patches are SKIP"
check 'grep -A1 "^  cd \"one-1.0\"" "$TMP/one" | grep -q "patch -p1 < \"\$srcdir/a.patch\""' "the patch step follows prepare()'s first cd"

cat > "$TMP/two" <<'EOF'
pkgname=two
pkgrel=1
source=("https://example.org/two.tar.gz")
sha512sums=('cccc')
b2sums=('dddd')
sha256sums_aarch64=('eeee')
source_aarch64=("https://example.org/two-arm.bin")
prepare() {
  cd two
}
EOF
python3 "$EDIT" "$TMP/two" --suffix 1 x.patch
check '[ "$(skips "$TMP/two" sha512sums)" = 1 ] && [ "$(skips "$TMP/two" b2sums)" = 1 ]' "EVERY declared array gets the SKIP, not just the first"
check '! grep -q "sha256sums_aarch64+=" "$TMP/two" && ! grep -q "^sha256sums+=" "$TMP/two"' "architecture arrays are left alone, and no array the recipe lacks is added"
check 'aligned "$TMP/two"' "two arrays stay as long as source=() ($(lengths "$TMP/two"))"

cat > "$TMP/none" <<'EOF'
pkgname=none
pkgrel=2
source=()
prepare() {
  cd "$srcdir"
}
EOF
python3 "$EDIT" "$TMP/none" --suffix 1 only.patch
check '[ "$(lengths "$TMP/none")" = "source=1 sha256sums=1" ]' "no array at all (novadeck-gpu-priority): sha256sums is created for the patch ($(lengths "$TMP/none"))"

printf 'pkgname=p\npkgrel=5\nsource=(x)\nb2sums=(SKIP)\n' > "$TMP/plain"
python3 "$EDIT" "$TMP/plain" --suffix 1
check 'grep -qx "pkgrel=5.1" "$TMP/plain" && ! grep -q "+=" "$TMP/plain"' "no patches: only the pkgrel moves"

printf 'pkgname=nocd\npkgrel=1\nsource=()\nprepare() {\n  true\n}\n' > "$TMP/nocd"
cp "$TMP/nocd" "$TMP/nocd.orig"
python3 "$EDIT" "$TMP/nocd" --suffix 1 p.patch 2>/dev/null; rc=$?
check '[ "$rc" = 3 ] && cmp -s "$TMP/nocd" "$TMP/nocd.orig"' "no cd in prepare(): exit 3, and the PKGBUILD is left as it was"

echo "== every real recipe, edited as build-overlay.sh edits it"
pin_field() { sed -n "s/^$2:[[:space:]]*//p" "$1" | head -1; }
for pin in "$ROOT"/packages/*/source.pin; do
  dir="$(dirname "$pin")"; name="$(basename "$dir")"
  pb="$(pin_field "$pin" pkgbuild_local)"
  [ -n "$pb" ] || { bad "$name: no pkgbuild_local (a fetched recipe would need this check too)"; continue; }
  cp "$dir/$pb" "$TMP/$name.PKGBUILD"
  # shellcheck disable=SC2046
  if ! python3 "$EDIT" "$TMP/$name.PKGBUILD" --suffix "$(pin_field "$pin" pkgrel_suffix)" \
       $(pin_field "$pin" patches) 2>"$TMP/err"; then
    bad "$name: the edit failed ($(cat "$TMP/err"))"; continue
  fi
  l="$(lengths "$TMP/$name.PKGBUILD")"
  if aligned "$TMP/$name.PKGBUILD"; then ok "$name: $l"; else bad "$name: arrays not as long as source=() ($l)"; fi
done

echo "== makepkg's integrity flags in build-overlay.sh"
calls="$(grep -n -E '^[^#]*makepkg ' "$BUILDER")"
check '[ -n "$calls" ] && ! grep -q -- "--skipinteg" <<<"$calls"' "no makepkg call passes --skipinteg (it turns every checksum off)"
check 'grep -E "makepkg -sf " <<<"$calls" | grep -q -- "--skippgpcheck"' "the build passes --skippgpcheck (an empty keyring cannot check the signed tags)"
check 'grep -q -- "--verifysource" <<<"$calls"' "--verify-sources runs makepkg --verifysource"
check 'grep -q "packages/overlay-pkgbuild.py" "$BUILDER"' "the builder edits PKGBUILDs through overlay-pkgbuild.py, the code tested here"

echo
echo "overlay-pkgbuild: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
