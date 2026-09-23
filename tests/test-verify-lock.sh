#!/usr/bin/env bash
# Offline check that the lock-row verifier still covers BOTH manifests.
#
#   tests/test-verify-lock.sh
#
# WHY THIS EXISTS. packages/verify-lock-rows.sh is the fast gate: it decides, from committed files
# in about a second, whether a `novadeck` row names sources the tree can still produce. The slow
# gates (rootfs/fetchlock.sh, installer/mkroot.sh's resolve) make the same call correctly but only
# from inside a build, which is far too late to be useful — installer/v0.0.8 spent 56 minutes
# building a kernel to reach a verdict available here immediately.
#
# There are TWO locks, because the installer medium carries gamescope as well (installer/ui is a
# Wayland client and gamescope is its display server). The fast gate originally read only
# rootfs/manifest.lock, so a packages/gamescope change that relocked one manifest and not the other
# sailed past it — which is precisely how installer/v0.0.8 was cut against a tree that could not
# build. Coverage of the second lock is the whole point, and it is the kind of thing that regresses
# silently, since dropping it costs nothing until a release fails an hour in.
#
# The tests run the real script against a throwaway tree: packages/ symlinked per-package so the
# input hashes are the true ones, with copies of both locks that each case is free to corrupt.
# Host-only, no root, no network, no work/.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFIER="$ROOT/packages/verify-lock-rows.sh"
BOGUS="dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

[ -f "$VERIFIER" ] || { echo "no verifier: ${VERIFIER#"$ROOT"/}" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A tree the verifier can run in, with locks we own. The package dirs are symlinks, not copies:
# inputhash.sh must see the real sources or every row looks stale and the suite passes for the
# wrong reason.
mk_tree() {
  local t="$TMP/$1" d
  rm -rf "$t"
  mkdir -p "$t/packages" "$t/rootfs" "$t/installer" "$t/build"
  for d in "$ROOT"/packages/*/; do ln -s "${d%/}" "$t/packages/$(basename "${d%/}")"; done
  cp "$ROOT/packages/inputhash.sh" "$ROOT/packages/verify-lock-rows.sh" "$t/packages/"
  # The builder pin is an input to every novadeck row's hash (inputhash.sh reads it via lib-pins.sh).
  cp "$ROOT/build/lib-pins.sh" "$ROOT/build/snapshot.pin" "$ROOT/build/builder.pin" "$t/build/"
  cp "$ROOT/rootfs/manifest.lock" "$t/rootfs/manifest.lock"
  cp "$ROOT/installer/manifest.lock" "$t/installer/manifest.lock"
  printf '%s\n' "$t"
}

# Rewrite the first novadeck row's hash in $1 to something no package produces.
stale_first_row() {
  awk -v bogus="$BOGUS" '
    !done && $4 == "novadeck" { $5 = bogus; done = 1 }
    { print }
  ' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

run() { bash "$1/packages/verify-lock-rows.sh" 2>&1; }

# --- 1. the tree as committed passes ----------------------------------------------------------
# Also the assertion that both locks are currently correct, which is worth having on every push.
out="$(bash "$VERIFIER" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then ok "the committed tree passes"
else bad "the committed tree fails the verifier:"; printf '%s\n' "$out" | sed 's/^/       /'; fi

for lock in rootfs installer; do
  case "$lock" in
    rootfs)    relock="make relock" ;;
    installer) relock="make relock-installer" ;;
  esac

  # --- 2. a stale row in this lock is caught, and names ITS OWN relock target ------------------
  t="$(mk_tree "stale-$lock")"
  stale_first_row "$t/$lock/manifest.lock"
  out="$(run "$t")"; rc=$?

  if [ "$rc" -ne 0 ]; then ok "$lock/manifest.lock: a stale novadeck row fails the check"
  else bad "$lock/manifest.lock: a stale novadeck row PASSED — this lock is not covered"; fi

  if printf '%s' "$out" | grep -q "$lock/manifest.lock:"; then
    ok "$lock/manifest.lock: the report names the lock that is wrong"
  else
    bad "$lock/manifest.lock: the report does not say which lock is wrong"
  fi

  if printf '%s' "$out" | grep -qF "$relock"; then
    ok "$lock/manifest.lock: the report points at \`$relock\`"
  else
    bad "$lock/manifest.lock: the report does not point at \`$relock\`"
    printf '%s\n' "$out" | sed 's/^/       /'
  fi

  # --- 3. a lock with no novadeck rows must not pass trivially --------------------------------
  # Deleting rows is the shape a bad merge takes, and "zero rows checked" reads as success
  # everywhere else.
  t="$(mk_tree "empty-$lock")"
  grep -v ' novadeck ' "$t/$lock/manifest.lock" > "$t/$lock/manifest.lock.tmp" \
    && mv "$t/$lock/manifest.lock.tmp" "$t/$lock/manifest.lock"
  out="$(run "$t")"; rc=$?
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'refusing to pass trivially'; then
    ok "$lock/manifest.lock: a lock with no novadeck rows is refused"
  else
    bad "$lock/manifest.lock: a lock with no novadeck rows passed"
  fi
done

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
