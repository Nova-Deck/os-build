#!/usr/bin/env bash
# Offline tests for rootfs/guard-rootfs.sh assertion 11 — file ownership and setuid.
#
#   tests/test-guard.sh
#
# WHY THIS ONE ASSERTION HAS A SUITE AND THE OTHER ELEVEN DO NOT. The rest of the guard reads a
# declaration that ships inside the tree (seal.list, trim.list, the pin, the lock) and compares it
# to files — build a fixture wrong and the fixture is what is wrong. Assertion 11 has no
# declaration to disagree with: it reads the tree's own /etc/passwd and answers a question about
# every inode. That makes it the one assertion that can go quietly vacuous — a passwd it cannot
# read, an id set it builds empty, a permit list it never consults — and pass a tree it never
# looked at. A guard that passes vacuously is worse than no guard, which is the argument the guard
# itself makes about its own preconditions.
#
# It also guards the more expensive direction. The assertion exists because a /usr owned end to end
# by uid 1001 shipped through every other assertion; if it ever stops firing, the next tree of that
# shape ships too, and it is found on hardware.
#
# HOW THE FIXTURES WORK, and why the suite never looks at the guard's exit code. A minimal stage
# cannot satisfy assertions 6, 7 and 9 (no RAUC keyring, no Decky loader, no id pin), so the guard
# ALWAYS exits non-zero here and its verdict says nothing about assertion 11. Every case below
# greps the assertion's own output instead. That coupling has one useful side effect worth naming:
# the guard records out/images/rootfs.sizes only after a clean run, so a fixture can never
# overwrite the real build's size baseline.
#
# No root needed, and deliberately so — the ids the cases use are the ones the test runner already
# owns, made undeclared by leaving them out of the fixture's passwd rather than by chowning.
#
# Runs on the host with no root, no docker, no network and no built tree. Run via `make test`.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT/rootfs/guard-rootfs.sh"

PASS=0; FAIL=0
ok()  { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }

[[ -f $GUARD ]] || { echo "missing input: $GUARD" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

RUN_UID="$(id -u)"
RUN_GID="$(id -g)"

# A stage that clears the guard's preconditions and nothing more. Those preconditions exit the
# script outright (the seal not having run is not a finding, it is a broken invocation), so every
# case needs them even though none of them is what is under test.
mkstage() {
  local s="$1" db="$1/usr/lib/novadeck/pkgdb/pacman-7.0-1"
  install -d "$db" "$s/etc" "$s/usr/bin"
  printf 'pkg pacman\n'                  >"$s/usr/lib/novadeck/seal.list"
  printf 'path /usr/share/doc\n'         >"$s/usr/lib/novadeck/trim.list"
  printf '%%NAME%%\npacman\n'            >"$db/desc"
  printf '%%FILES%%\nusr/bin/pacman\n'   >"$db/files"
  printf 'root:x:0:0::/root:/bin/bash\n' >"$s/etc/passwd"
  printf 'root:x:0:\n'                   >"$s/etc/group"
  : >"$s/usr/bin/hello"
}

# The runner owns every file it just created, so declaring its ids is what makes a fixture "clean".
declare_runner_uid() { printf 'runner:x:%s:%s::/:/bin/false\n' "$RUN_UID" "$RUN_GID" >>"$1/etc/passwd"; }
declare_runner_gid() { printf 'runner:x:%s:\n' "$RUN_GID" >>"$1/etc/group"; }

# Assertion 11's own output, from the numbered header to the start of assertion 12.
guard11() { bash "$GUARD" "$1" 2>&1 | sed -n '/^  11\. file ownership and setuid$/,/^    size:/p'; }

echo "assertion 11 passes a clean tree"

stage="$TMP/clean"; mkstage "$stage"; declare_runner_uid "$stage"; declare_runner_gid "$stage"
clean="$(guard11 "$stage")"

if grep -q 'paths, every uid and gid declared by this tree' <<<"$clean"; then
  ok "a tree whose ids it all declares passes"
else
  bad "a clean tree did not pass assertion 11 -- every build would now fail on it: $clean"
fi
# The count is the proof it walked something. An assertion that reports "0 paths" has found a way
# to look at nothing and call it clean, which is the failure this whole suite is about.
if [[ "$(sed -n 's/.*ok  \([0-9]\+\) paths.*/\1/p' <<<"$clean")" -gt 5 ]]; then
  ok "it reports how many paths it walked, and the count is not zero"
else
  bad "assertion 11 reported no meaningful path count -- it may be passing without walking the tree"
fi
if grep -q 'setuid/setgid files, all permitted' <<<"$clean"; then
  ok "a tree with no setuid files passes the setuid half"
else
  bad "the setuid half did not report on a clean tree: $clean"
fi

echo
echo "an id the tree cannot name is a failure"

stage="$TMP/uid"; mkstage "$stage"; declare_runner_gid "$stage"      # gid declared, uid not
out="$(guard11 "$stage")"
if grep -q "GUARD FAIL: paths owned by an id" <<<"$out" && grep -q "uid $RUN_UID" <<<"$out"; then
  ok "a file owned by an undeclared uid fails, and the message names the uid"
else
  bad "an undeclared uid did not fail assertion 11: $out"
fi

stage="$TMP/gid"; mkstage "$stage"; declare_runner_uid "$stage"      # uid declared, gid not
out="$(guard11 "$stage")"
if grep -q "gid $RUN_GID" <<<"$out"; then
  ok "a file owned by an undeclared gid fails, and the message names the gid"
else
  bad "an undeclared gid did not fail assertion 11 -- the group half is not being checked: $out"
fi

# Reporting by owner rather than by path is what keeps a miscopied subtree legible. It is also the
# only reason this assertion is safe to point at a 90k-file tree: the 1001 defect was ONE wrong id
# across all of /usr, and a per-file list of it is not something anyone reads.
stage="$TMP/many"; mkstage "$stage"; declare_runner_gid "$stage"
install -d "$stage/usr/share/a" "$stage/usr/share/b"
: >"$stage/usr/share/a/one"; : >"$stage/usr/share/b/two"
out="$(guard11 "$stage")"
if [[ "$(grep -c "GUARD FAIL: paths owned by an id" <<<"$out")" == 1 ]] \
   && grep -qE "uid $RUN_UID.*[0-9]+ paths, e\.g\. /" <<<"$out"; then
  ok "many files with one wrong id report once, by owner, with a count and an example"
else
  bad "the ownership failure is not summarised by owner: $out"
fi

echo
echo "the setuid permit list is read in one direction"

stage="$TMP/suid"; mkstage "$stage"; declare_runner_uid "$stage"; declare_runner_gid "$stage"
install -m 4755 /dev/null "$stage/usr/bin/sneaky"
install -m 2755 /dev/null "$stage/usr/bin/sneaky-sgid"
install -m 4755 /dev/null "$stage/usr/bin/su"        # on the permit list
out="$(guard11 "$stage")"
if grep -q '/usr/bin/sneaky$' <<<"$out"; then
  ok "an unpermitted setuid file fails"
else
  bad "a setuid root binary the permit list does not name was not caught: $out"
fi
if grep -q '/usr/bin/sneaky-sgid$' <<<"$out"; then
  ok "an unpermitted setgid file fails too"
else
  bad "setgid is not being checked -- only the setuid bit is: $out"
fi
if ! grep -q '/usr/bin/su$' <<<"$out"; then
  ok "a permitted setuid file (usr/bin/su) is not flagged"
else
  bad "the permit list is being ignored -- every real tree would fail: $out"
fi

# An entry vanishing is the trim doing its job, not a regression. If this ever became a failure,
# removing a package would start failing builds for the wrong reason.
stage="$TMP/absent"; mkstage "$stage"; declare_runner_uid "$stage"; declare_runner_gid "$stage"
out="$(guard11 "$stage")"
if ! grep -q 'GUARD FAIL: setuid' <<<"$out"; then
  ok "permitted entries absent from the tree are not a failure"
else
  bad "a permitted setuid file missing from the tree failed the build -- the list is being read as required, not permitted: $out"
fi

echo
echo "the permit list itself is well formed"

# Read the array back out of the guard, the way tests/test-mkroot.sh reads mkroot.sh's file lists:
# a permit entry is matched against `find -printf %P`, which never has a leading slash, so a single
# "/usr/bin/..." entry would silently never match and quietly stop permitting that file.
permit="$(sed -n '/^SETUID_PERMITTED=(/,/^)/p' "$GUARD" | sed '1d;$d' | sed 's/#.*//' | tr -s ' \n' '\n' | grep -v '^$')"
if [[ -n $permit ]]; then
  ok "the guard declares a setuid permit list ($(wc -l <<<"$permit") entries)"
else
  bad "no SETUID_PERMITTED entries found in the guard -- the setuid half permits nothing or was renamed"
fi
if ! grep -q '^/' <<<"$permit"; then
  ok "every permit entry is tree-relative (no leading slash)"
else
  bad "a permit entry starts with '/', which can never match find's %P: $(grep '^/' <<<"$permit")"
fi

echo
echo "it does not pass vacuously"

# The one shape that would make this assertion worthless: no name database to check against. It
# must say so rather than build an empty id set, against which nothing is ever declared -- or, the
# other way round, skip the walk and report success.
stage="$TMP/nopasswd"; mkstage "$stage"; rm -f "$stage/etc/passwd"
out="$(guard11 "$stage")"
if grep -q 'cannot name its own files' <<<"$out" && ! grep -q 'every uid and gid declared' <<<"$out"; then
  ok "a tree with no /etc/passwd fails loudly instead of passing"
else
  bad "assertion 11 did not fail on a tree with no /etc/passwd -- it can pass vacuously: $out"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
