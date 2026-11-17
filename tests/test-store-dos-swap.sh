#!/usr/bin/env bash
# Offline checks for game-launch's Boxtron target swap (rootfs/overlay/usr/lib/novadeck/
# novadeck_dostarget.py; .claude/plans/boxtron-dos.plan.md, phase 1 step 4).
#
#   tests/test-store-dos-swap.sh
#
# WHY THIS FILE EXISTS. game-launch fronts EVERY store launch, Proton ones included, and the swap
# rewrites the argv Steam built. The property that matters most is the negative one: a launch that
# is not Boxtron, or not a game we recorded, or not shaped the way we expect, must reach exec
# byte-for-byte as Steam built it. The positive case replaces the shortcut's exe (matched EXACTLY,
# never guessed) with the chosen DOSBox command line.
#
# WHAT IT CANNOT PROVE: the argv Steam really builds around a v1 compat tool (`--wait-before-run`
# or not, a reaper prefix or not). The swap is written to be agnostic about everything before the
# exe; the hardware gate confirms the layout.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIBDIR="$ROOT/rootfs/overlay/usr/lib/novadeck"
PASS=0 FAIL=0

out="$(python3 - "$LIBDIR" <<'PY'
import json, os, pathlib, sys, tempfile
sys.path.insert(0, sys.argv[1])

def ok(m): print(f"  ok   {m}")
def bad(m): print(f"  FAIL {m}")
def check(cond, m): (ok if cond else bad)(m)

import novadeck_dostarget as ds

tmp = pathlib.Path(tempfile.mkdtemp(prefix="dos-swap."))
home = tmp / "store"
home.mkdir()
mom = tmp / "Master of Magic"
OFF = mom / "Master of Magic Official Release" / "DOSBOX"
CP = mom / "Master of Magic Community Patch" / "DOSBOX"
for d in (OFF, CP):
    d.mkdir(parents=True)
    (d / "DOSBox.exe").write_bytes(b"MZ")
LAUNCHER = str(mom / "Launcher.exe")
OFF_ARGS = ["-conf", "../dosboxMOM.conf", "-conf", "../dosboxMOM_single.conf", "-noconsole", "-c", "exit"]
CP_ARGS = ["-conf", "..\\dosboxMOM.conf", "-conf", "..\\dosboxMOM_single.conf", "-noconsole", "-c", "exit"]
ROW = {"token": "gog:1207658855", "launcher_exe": LAUNCHER, "choice": None, "variants": [
    {"label": "Master of Magic Official Release", "exe": str(OFF / "DOSBox.exe"), "args": OFF_ARGS, "cwd": str(OFF)},
    {"label": "Master of Magic Community Patch", "exe": str(CP / "DOSBox.exe"), "args": CP_ARGS, "cwd": str(CP)},
]}
APPID = "4294843840"

def write(table):
    (home / ds.TARGETS_FILE).write_text(json.dumps(table))

BOX = "/usr/share/boxtron/run-dosbox"
chain = ["/home/deck/.local/share/Steam/ubuntu12_32/reaper", "SteamLaunch", f"AppId={APPID}", "--",
         BOX, "--wait-before-run", LAUNCHER]

print("== the swap")
write({APPID: ROW})
argv, cwd = ds.swap(chain, APPID, home)
check(argv == chain[:6] + [str(OFF / "DOSBox.exe")] + OFF_ARGS,
      "no choice → the FIRST variant replaces the launcher; everything before it is untouched")
check(cwd == str(OFF), "and the launch moves into that variant's cwd")

write({APPID: {**ROW, "choice": "Master of Magic Community Patch"}})
argv, cwd = ds.swap(chain, APPID, home)
check(argv[-len(CP_ARGS) - 1:] == [str(CP / "DOSBox.exe")] + CP_ARGS and cwd == str(CP),
      "a remembered choice picks its variant")

argv, _ = ds.swap(chain + ["-fullscreen"], APPID, home)
check(argv[-1] == "exit", "arguments Steam put after the launcher are dropped with it")

argv, _ = ds.swap(["/usr/share/boxtron//run-dosbox", LAUNCHER], APPID, home)
check(argv[1] == str(CP / "DOSBox.exe"), "Boxtron's entry point is recognised through a doubled slash")

write({APPID: {**ROW, "choice": "Caster of Magic"}})
argv, _ = ds.swap(chain, APPID, home)
check(argv[6] == str(OFF / "DOSBox.exe"), "a choice naming no variant falls back to the first")

print("== everything else reaches exec untouched")
write({APPID: ROW})
proton = ["/usr/share/steam/compatibilitytools.d/proton-cachyos-11.0-arm64/proton", "waitforexitandrun", LAUNCHER]
check(ds.swap(proton, APPID, home) == (proton, None), "a Proton launch of the same game is untouched")
check(ds.swap(chain, "999", home) == (chain, None), "an appid with no row is untouched")
check(ds.swap(chain, None, home) == (chain, None), "no appid is untouched")
other = chain[:-1] + [str(mom / "Other.exe")]
check(ds.swap(other, APPID, home) == (other, None), "a launch whose exe is not the recorded launcher is untouched")
before = [LAUNCHER, BOX]
check(ds.swap(before, APPID, home) == (before, None), "the launcher must come AFTER Boxtron's entry point")
check(ds.swap(chain, APPID, tmp / "no-such-home") == (chain, None), "no targets file is untouched")
(home / ds.TARGETS_FILE).write_text("{not json")
check(ds.swap(chain, APPID, home) == (chain, None), "an unreadable targets file is untouched")
write({APPID: {**ROW, "variants": [{**ROW["variants"][0], "exe": str(mom / "missing.exe")}]}})
check(ds.swap(chain, APPID, home) == (chain, None), "a variant whose exe is gone is untouched")
write({APPID: {**ROW, "variants": [{**ROW["variants"][0], "args": "-c exit"}]}})
check(ds.swap(chain, APPID, home) == (chain, None), "a variant with malformed args is untouched")
write({APPID: {**ROW, "variants": [{**ROW["variants"][0], "exe": "DOSBox.exe"}]}})
check(ds.swap(chain, APPID, home) == (chain, None), "a relative exe is untouched")
write({APPID: {**ROW, "variants": []}})
check(ds.swap(chain, APPID, home) == (chain, None), "a row with no variants is untouched")
write([1, 2])
check(ds.swap(chain, APPID, home) == (chain, None), "a targets file that is not a table is untouched")
check(chain[-1] == LAUNCHER, "swap never mutates the argv it was given")

print("== game-launch wiring")
main = (pathlib.Path(sys.argv[1]) / "game-launch").read_text()
check("novadeck_dostarget" in main, "game-launch imports the swap")
i_first, i_swap, i_exec = main.find("novadeck_firstrun.run("), main.find("novadeck_dostarget.swap("), main.find("os.execv(")
check(-1 < i_first < i_swap < i_exec, "the swap runs after the first-run steps and before exec")
PY
)"
rc=$?
printf '%s\n' "$out"
PASS=$((PASS + $(grep -c '^  ok ' <<<"$out" || true)))
FAIL=$((FAIL + $(grep -c '^  FAIL' <<<"$out" || true)))
[ "$rc" -eq 0 ] || { echo "  FAIL the dos-swap checks crashed (exit $rc)"; FAIL=$((FAIL + 1)); }

echo
echo "dos-swap: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
