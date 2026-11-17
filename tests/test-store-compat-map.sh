#!/usr/bin/env bash
# Offline checks for reading Steam's compat-tool mappings out of config.vdf
# (apps/decky/novadeck-stores/py_modules/novadeck_stores/compat_map.py;
# .claude/plans/boxtron-dos.plan.md, phase 2).
#
#   tests/test-store-compat-map.sh
#
# WHY THIS FILE EXISTS. reassert_compat re-sends our Proton to every store entry when SteamUI comes
# up, because SpecifyCompatTool lives in memory until Steam flushes config.vdf. Done blindly, that
# overwrote whatever the user picked in Properties -> Compatibility (Boxtron, Proton-GE) on every
# boot. It now re-sets only entries with NO mapping on disk, so this reader decides whose choice
# survives. Its failure mode must be the old behaviour: an unreadable file means "nothing is known
# mapped", never "everything is".
#
# The fixture's CompatToolMapping block is the shape read off a Pocket FIT on 2026-11-17 (tabs,
# per-appid {name, config, priority}).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STORES_PY="$ROOT/apps/decky/novadeck-stores/py_modules"
PASS=0 FAIL=0

out="$(python3 - "$STORES_PY" <<'PY'
import os, pathlib, sys, tempfile
sys.path.insert(0, sys.argv[1])

def ok(m): print(f"  ok   {m}")
def bad(m): print(f"  FAIL {m}")
def check(cond, m): (ok if cond else bad)(m)

from novadeck_stores import compat_map

CONFIG = '''"InstallConfigStore"
{
\t"Software"
\t{
\t\t"Valve"
\t\t{
\t\t\t"Steam"
\t\t\t{
\t\t\t\t"CompatToolMapping"
\t\t\t\t{
\t\t\t\t\t"0"
\t\t\t\t\t{
\t\t\t\t\t\t"name"\t\t"proton_experimental"
\t\t\t\t\t\t"config"\t\t""
\t\t\t\t\t\t"priority"\t\t"75"
\t\t\t\t\t}
\t\t\t\t\t"3556566146"
\t\t\t\t\t{
\t\t\t\t\t\t"name"\t\t"boxtron"
\t\t\t\t\t\t"config"\t\t""
\t\t\t\t\t\t"priority"\t\t"250"
\t\t\t\t\t}
\t\t\t\t\t"2981617462"
\t\t\t\t\t{
\t\t\t\t\t\t"name"\t\t""
\t\t\t\t\t\t"config"\t\t""
\t\t\t\t\t\t"priority"\t\t"250"
\t\t\t\t\t}
\t\t\t\t}
\t\t\t\t"SomethingElse"\t\t"with \\"escaped\\" quotes // not a comment"
\t\t\t}
\t\t}
\t}
}
'''

print("== the parser")
data = compat_map.parse(CONFIG)
check(isinstance(data, dict) and "InstallConfigStore" in data, "parses Steam's text VDF into nested dicts")
steam = data["InstallConfigStore"]["Software"]["Valve"]["Steam"]
check(steam["SomethingElse"] == 'with "escaped" quotes // not a comment',
      "escaped quotes and a // inside a string survive")
check(compat_map.parse('"a"\n{\n\t// a comment\n\t"b"\t"c"\n}\n') == {"a": {"b": "c"}}, "// comments are skipped")
for broken, why in (('"a"\n{\n\t"b"\t"c"\n', "an unclosed block"), ('"a"\n}', "a stray close brace"),
                    ('"a"', "a key with no value"), ('"a"\t"unterminated', "an unterminated string")):
    try:
        compat_map.parse(broken)
        bad(f"{why} raised nothing")
    except ValueError:
        ok(f"{why} raises ValueError")

print("== the mapped appids")
check(compat_map.mapped_from(data) == {3556566146},
      "an appid with a tool name is mapped; an empty name is not; the global default '0' is not an entry")
check(compat_map.mapped_from({"x": {"compattoolmapping": {"5": {"name": "proton"}}}}) == {5},
      "the block is found whatever the case and nesting")
check(compat_map.mapped_from({}) == set(), "no block → nothing mapped")

print("== reading the file")
uid = os.getuid()
tmp = pathlib.Path(tempfile.mkdtemp(prefix="compat-map."))
cfg = tmp / "config.vdf"
cfg.write_text(CONFIG)
check(compat_map.mapped_appids(str(cfg), uid) == {3556566146}, "the real file shape reads back the mapped appid")
check(compat_map.mapped_appids(str(tmp / "missing.vdf"), uid) is None, "a missing file → None (unknown), not an empty set")
(tmp / "broken.vdf").write_text('"a"\n{\n')
check(compat_map.mapped_appids(str(tmp / "broken.vdf"), uid) is None, "an unparseable file → None")
(tmp / "link.vdf").symlink_to(cfg)
check(compat_map.mapped_appids(str(tmp / "link.vdf"), uid) is None, "a symlink is refused (owner-checked open) → None")
check(compat_map.mapped_appids(str(cfg), uid + 1) is None, "a file the store user does not own → None")
PY
)"
rc=$?
printf '%s\n' "$out"
PASS=$((PASS + $(grep -c '^  ok ' <<<"$out" || true)))
FAIL=$((FAIL + $(grep -c '^  FAIL' <<<"$out" || true)))
[ "$rc" -eq 0 ] || { echo "  FAIL the compat-map checks crashed (exit $rc)"; FAIL=$((FAIL + 1)); }

echo
echo "compat-map: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
