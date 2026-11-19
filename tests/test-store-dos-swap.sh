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

# The cases below are about WHICH variant runs; asking the user is its own section further down.
# Until then the ask finds no plugin answering, which is what a real ask does with nobody there.
real_ask = ds.ask
asked = []
def no_answer(home_, appid_):
    asked.append(appid_)
    return None
ds.ask = no_answer

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

print("== asking which version (phase 3): only when there is a real choice to make")
write({APPID: ROW})
asked.clear()
ds.swap(chain, APPID, home)
check(asked == [APPID], "two variants and no remembered choice → the launch asks")
asked.clear()
write({APPID: {**ROW, "choice": "Master of Magic Community Patch"}})
ds.swap(chain, APPID, home)
check(asked == [], "a remembered choice is used without asking")
write({APPID: {**ROW, "variants": ROW["variants"][:1]}})
ds.swap(chain, APPID, home)
check(asked == [], "a single variant is used without asking")
write({APPID: ROW})
ds.swap(proton, APPID, home)
check(asked == [], "a Proton launch never asks")

ds.ask = lambda home_, appid_: "Master of Magic Community Patch"
argv, cwd = ds.swap(chain, APPID, home)
check(argv[6] == str(CP / "DOSBox.exe") and cwd == str(CP), "the answered variant runs")
ds.ask = lambda home_, appid_: ds.CANCEL
check(ds.swap(chain, APPID, home) == (None, None), "a cancelled pick means: do not launch")
ds.ask = lambda home_, appid_: "Caster of Magic"
argv, _ = ds.swap(chain, APPID, home)
check(argv[6] == str(OFF / "DOSBox.exe"), "an answer naming no variant falls back to the first")

print("== the ask itself, over the request spool")
import threading, time
ds.ask = real_ask
spool = home / ds.REQUEST_DIR
req = spool / f"{APPID}{ds.PICK_SUFFIX}"
ans = spool / f"{APPID}{ds.ANSWER_SUFFIX}"
fast = dict(take_timeout=0.6, answer_timeout=0.6, poll=0.02)
# An answered ask returns as soon as the answer lands, so its budgets can be roomy: a loaded CI
# runner missed 0.6 s once. Only the cases that must time out keep the short ones (cf. savesync).
roomy = dict(take_timeout=3, answer_timeout=3, poll=0.02)

def backend(answer, take=True, delay=0.05):
    """Play the plugin: take the request (unlink it), then answer — or not."""
    def run():
        end = time.time() + 5
        while not req.exists() and time.time() < end:
            time.sleep(0.01)
        time.sleep(delay)
        if take and req.exists():
            req.unlink()
            if answer is not None:
                ans.write_text(answer)
    t = threading.Thread(target=run)
    t.start()
    return t

t = backend("Master of Magic Community Patch")
got = ds.ask(home, APPID, **roomy)
t.join()
check(got == "Master of Magic Community Patch", f"taken and answered → the label ({got!r})")
check(not ans.exists() and not req.exists(), "the answer is consumed and no request is left behind")

t = backend("")
got = ds.ask(home, APPID, **roomy)
t.join()
check(got is ds.CANCEL, f"an empty answer is a cancel ({got!r})")

got = ds.ask(home, APPID, **fast)
check(got is None and not req.exists(), "not taken in time → None, and the request is WITHDRAWN (plugin down)")

t = backend(None)
got = ds.ask(home, APPID, take_timeout=3, answer_timeout=0.6, poll=0.02)
t.join()
check(got is None, "taken but never answered → None (the caller runs the first variant)")

spool.mkdir(exist_ok=True)
ans.write_text("Master of Magic Official Release")
t = backend("Master of Magic Community Patch")
got = ds.ask(home, APPID, **roomy)
t.join()
check(got == "Master of Magic Community Patch",
      f"a stale answer from an earlier launch is never mistaken for this one ({got!r})")

print("== game-launch wiring")
main = (pathlib.Path(sys.argv[1]) / "game-launch").read_text()
check("novadeck_dostarget" in main, "game-launch imports the swap")
i_first, i_swap, i_exec = main.find("novadeck_firstrun.run("), main.find("novadeck_dostarget.swap("), main.find("os.execv(")
check(-1 < i_first < i_swap < i_exec, "the swap runs after the first-run steps and before exec")
check("swapped is None" in main and "sys.exit(0)" in main[i_swap:i_exec],
      "a cancelled pick ends game-launch quietly (exit 0) before exec")
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
