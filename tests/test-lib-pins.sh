#!/usr/bin/env bash
# Offline tests for build/lib-pins.sh — the snapshot and builder pin guards every build stage sources.
#
#   tests/test-lib-pins.sh
#
# No docker, no network. Run via `make test`.
#
# WHAT IS AT RISK: the guard is the only thing standing between a pin file and a build that
# silently tracks a moving alias. Every stage sources this one definition, so a regression here
# is a regression everywhere at once, and it shows up as a build that SUCCEEDS against the wrong
# repo. The cases below are the names that actually exist under archlinux-deckard/archlinux/.
set -uo pipefail

ROOT_REAL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_REAL/build/lib-pins.sh"
BASE=https://holo-packages.steamos.cloud/archlinux-deckard/archlinux

PASS=0; FAIL=0; CASE=""
ok()  { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/build"

# Run one lib function against a fake ROOT holding the given pin line. die() exits, so each call
# runs in its own bash.
run() {  # run <file> <line> <function>
  printf '# comment\n\n%s\n' "$2" > "$TMP/build/$1"
  bash -c 'ROOT="$1"; . "$2"; "$3"' _ "$TMP" "$LIB" "$3" 2>/dev/null
}
accepts() { local out; out="$(run snapshot.pin "$1" pins_snapshot)" && [ "$out" = "$1" ]; }

CASE=snapshot
for s in mash-20251118.3 mash-20260305 mash-20240705.2; do
  accepts "$BASE/$s" && ok "accepts $s" || bad "refused a real snapshot: $s"
done
for s in main dev builds pipeline tmp mash-20260305.1.pvt mash-20251118-pvt mash-20251118.3.pvt \
         mash-2026030 mash-20260305. mash-20260305/; do
  accepts "$BASE/$s" && bad "accepted $s" || ok "refuses $s"
done
accepts "https://holo-packages.steamos.cloud/holo-core-aarch64-preview/mash-20251118.3" \
  && bad "accepted the frozen preview mirror" || ok "refuses the preview mirror"
accepts "https://example.com/archlinux-deckard/archlinux/mash-20260305" \
  && bad "accepted a foreign host" || ok "refuses a foreign host"

CASE=builder
sha=7e3fb88454e1ac633b7488abb72d3ca0cc7d2578a38146fdd7d58b50fcbd60bf
[ "$(run builder.pin "$sha" pins_builder_sha)" = "$sha" ] && ok "accepts a sha256" || bad "refused a sha256"
for b in "${sha:0:63}" "${sha}0" "${sha^^}" "sha256:$sha" \
         "registry.gitlab.steamos.cloud/holo/holo-core-aarch64-preview/base-devel@sha256:$sha"; do
  run builder.pin "$b" pins_builder_sha >/dev/null && bad "accepted '$b'" || ok "refuses '${b:0:40}…'"
done
[ "$(run builder.pin "$sha" pins_builder_ref)" = "novadeck/builder:$sha" ] \
  && ok "ref is keyed on the tarball sha" || bad "ref is not novadeck/builder:<sha>"

# The builder URL is derived, never written: the description must name the snapshot's tarball.
printf '%s\n' "$BASE/mash-20260305" > "$TMP/build/snapshot.pin"
[ "$(run builder.pin "$sha" pins_builder_desc)" = "$BASE/mash-20260305/system.rootfs.zst sha256:$sha" ] \
  && ok "builder is derived from the snapshot pin" || bad "builder description does not follow the snapshot"

CASE=repo
# The committed pins must themselves pass, or every stage dies at its first line.
bash -c 'ROOT="$1"; . "$1/build/lib-pins.sh"; pins_snapshot && pins_builder_sha' _ "$ROOT_REAL" >/dev/null 2>&1 \
  && ok "committed build/snapshot.pin + build/builder.pin are valid" || bad "committed pins fail their own guard"
# Code lines only: build/builder.pin's own comment records what it replaced.
leftover="$(grep -rlE '^[^#]*base-devel\.digest'"$ROOT_REAL"/rootfs/*.sh "$ROOT_REAL"/installer/*.sh \
             "$ROOT_REAL"/packages/*.sh "$ROOT_REAL"/build "$ROOT_REAL"/Makefile "$ROOT_REAL"/.github 2>/dev/null || true)"
[ -z "$leftover" ] && ok "no stage still reads build/base-devel.digest" \
  || bad "still reads the deleted pin: $(printf '%s' "$leftover" | tr '\n' ' ')"

printf '\ntest-lib-pins.sh: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
