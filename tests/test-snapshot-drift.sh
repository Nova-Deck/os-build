#!/usr/bin/env bash
# Offline checks for build/snapshot-drift.py, which upstream-watch.yml's deckard-drift job runs
# daily against the pinned snapshot's live core/extra dbs.
#
#   tests/test-snapshot-drift.sh
#
# WHY THIS FILE EXISTS. The job's only output on a healthy day is silence, so a checker that
# passes everything looks exactly like a snapshot that never moves. Each drift kind is planted
# here and must be reported, and each "cannot see" input must exit 2 (red) rather than 0. The
# last case runs the checker over the REAL locks against a db built from their own rows, so a
# lock format change that stops it parsing fails here instead of in the watcher.
#
# Host-only, no network, no work/.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/build/snapshot-drift.py"
A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
B="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
C="cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# mkdb <out> <name version sha>... — a pacman sync db: an xz tarball of <name>-<ver>/desc files.
mkdb() {
  python3 -I - "$@" <<'PY'
import io, sys, tarfile
out, rows = sys.argv[1], sys.argv[2:]
with tarfile.open(out, "w:xz") as tar:
    for row in rows:
        name, ver, sha = row.split()
        desc = f"%FILENAME%\n{name}-{ver}-aarch64.pkg.tar.zst\n\n%NAME%\n{name}\n\n" \
               f"%VERSION%\n{ver}\n\n%SHA256SUM%\n{sha}\n\n%ARCH%\naarch64\n\n"
        data = desc.encode()
        info = tarfile.TarInfo(f"{name}-{ver}/desc"); info.size = len(data)
        tar.addfile(info, io.BytesIO(data))
PY
}

# run <expected rc> <label> <args...> — leaves stdout in $OUT.
run() {
  local want="$1" label="$2" rc
  shift 2
  OUT="$(python3 -I "$CHECK" "$@" 2>"$TMP/err")"; rc=$?
  if [ "$rc" -eq "$want" ]; then ok "$label (exit $rc)"; else bad "$label: exit $rc, want $want — $(cat "$TMP/err")"; fi
}

has() { grep -qF -- "$2" <<<"$OUT" && ok "$1" || bad "$1: no '$2' in: $OUT"; }

cat >"$TMP/lock" <<EOF
# header
foo 1.0-1 aarch64 snapshot $A
bar 2.0-1 any stripped $B
ours 3.0-1 aarch64 novadeck $C
blob r1 - prebuilt $C
EOF

echo "== a matching snapshot is clean"
mkdb "$TMP/core.db" "foo 1.0-1 $A"
mkdb "$TMP/extra.db" "bar 2.0-1 $B"
run 0 "rows split across core and extra all match" --db "$TMP/core.db" --db "$TMP/extra.db" "$TMP/lock"

echo "== each drift kind is reported"
mkdb "$TMP/extra.db" "bar 2.0-1 $C"
run 1 "a re-hashed package drifts" --db "$TMP/core.db" --db "$TMP/extra.db" "$TMP/lock"
has "  ...and names it as a sha256 change" "SHA256 $TMP/lock bar 2.0-1"
mkdb "$TMP/extra.db" "bar 2.0-2 $B"
run 1 "a re-versioned package drifts" --db "$TMP/core.db" --db "$TMP/extra.db" "$TMP/lock"
has "  ...and names both versions" "lock=2.0-1 snapshot=2.0-2"
mkdb "$TMP/extra.db" "other 1-1 $B"
run 1 "a package gone from the snapshot drifts" --db "$TMP/core.db" --db "$TMP/extra.db" "$TMP/lock"
has "  ...and is named GONE" "GONE $TMP/lock bar 2.0-1"
grep -q 'ours\|blob' <<<"$OUT" && bad "novadeck/prebuilt rows were checked: $OUT" \
  || ok "novadeck and prebuilt rows are not the snapshot's to judge"

echo "== a watcher that cannot see goes red"
mkdb "$TMP/empty.db"
run 2 "a db with no packages" --db "$TMP/empty.db" "$TMP/lock"
printf 'not a tarball' >"$TMP/junk.db"
run 2 "an unreadable db" --db "$TMP/junk.db" "$TMP/lock"
run 2 "a missing db" --db "$TMP/nope.db" "$TMP/lock"
printf 'ours 3.0-1 aarch64 novadeck %s\n' "$C" >"$TMP/nosnap.lock"
run 2 "a lock with no snapshot rows" --db "$TMP/core.db" "$TMP/nosnap.lock"
printf 'foo 1.0-1 aarch64\n' >"$TMP/bad.lock"
run 2 "a malformed lock row" --db "$TMP/core.db" "$TMP/bad.lock"

echo "== the real locks parse"
mapfile -t real < <(grep -hvE '^#' "$ROOT/rootfs/manifest.lock" "$ROOT/installer/manifest.lock" \
  | awk '$4 == "snapshot" || $4 == "stripped" { print $1, $2, $5 }' | sort -u)
mkdb "$TMP/real.db" "${real[@]}"
run 0 "both committed locks check clean against their own rows (${#real[@]} packages)" \
  --db "$TMP/real.db" "$ROOT/rootfs/manifest.lock" "$ROOT/installer/manifest.lock"

echo
echo "snapshot-drift: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
