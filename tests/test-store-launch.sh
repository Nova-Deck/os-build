#!/usr/bin/env bash
# Offline checks for alien-games milestone 6: the launch path (.claude/plans/alien-games-launch.plan.md).
#
#   tests/test-store-launch.sh
#
# WHY THIS FILE EXISTS. Model B hands the launch to Steam (Exe = the game binary + a compat tool),
# so the risky parts to get right offline are: resolving the installed game's executable from each
# store's own metadata, deciding which compat tool a platform wants (Windows → Proton, native →
# none), and the managed-install-root ownership test that replaces the retired stub's basename.
#
# WHAT IT CANNOT PROVE: that setting a compat tool makes Steam build SLR4+Proton, that the title
# renders, or that game-launch fronts the composed chain. Those are the hardware gate.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STORES_PY="$ROOT/apps/decky/novadeck-stores/py_modules"
PASS=0 FAIL=0 SKIP=0
ok()  { printf '  ok   %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL %s\n' "$*"; FAIL=$((FAIL + 1)); }

pysuite() {
  local name="$1" out rc
  out="$(python3 - "$STORES_PY")"
  rc=$?
  printf '%s\n' "$out"
  PASS=$((PASS + $(grep -c '^  ok ' <<<"$out" || true)))
  FAIL=$((FAIL + $(grep -c '^  FAIL' <<<"$out" || true)))
  [ "$rc" -eq 0 ] || bad "the $name checks crashed (exit $rc) — every check after the crash never ran"
}

echo "== resolve, compat decision, managed-root ownership"
pysuite "launch" <<'PY'
import json, os, pathlib, sys, tempfile
sys.path.insert(0, sys.argv[1])

def ok(m): print(f"  ok   {m}")
def bad(m): print(f"  FAIL {m}")

from novadeck_stores import launch

# -- compat tool decision --
(ok if launch.compat_tool("windows") == "proton-cachyos-11.0-arm64" else bad)(
    "a Windows title wants our arm64 Proton")
(ok if launch.compat_tool("linux") is None else bad)(
    "a native Linux title wants NO compat tool — bare binfmt+FEX")

tmp = pathlib.Path(tempfile.mkdtemp(prefix="store-launch."))
uid = os.getuid()

# -- Epic: resolved from legendary's installed.json (a file read, no launch invocation) --
lgd = tmp / "legendary"
lgd.mkdir()
install_dir = tmp / "Games" / "Epic" / "Breathedge"
install_dir.mkdir(parents=True)
(lgd / "installed.json").write_text(json.dumps({
    "0a20": {"app_name": "0a20", "title": "Breathedge",
             "install_path": str(install_dir), "executable": "Breathedge.exe"}}))
p = {"LEGENDARY_CONFIG_PATH": str(lgd), "NOVADECK_STORE_UID": str(uid),
     "NOVADECK_STORE_USER": os.environ.get("USER", "nobody")}
t = launch.resolve_target("epic", "0a20", p, {})
(ok if t and t["exe"] == str(install_dir / "Breathedge.exe") and t["platform"] == "windows" else bad)(
    f"Epic resolves exe = install_path/executable from installed.json ({t})")
(ok if launch.resolve_target("epic", "missing", p, {}) is None else bad)(
    "an Epic game not in installed.json resolves to None, never a guess")

# -- GOG Windows: primary playTask from goggame-<id>.info --
gog_dir = tmp / "Games" / "GOG" / "Witcher"
gog_dir.mkdir(parents=True)
(gog_dir / "goggame-123.info").write_text(json.dumps({"playTasks": [
    {"category": "document", "path": "manual.pdf"},
    {"category": "game", "path": "bin/witcher.exe", "isPrimary": True},
    {"category": "game", "path": "bin/other.exe"},
]}))
rec = {"path": str(gog_dir), "platform": "windows"}
t = launch.resolve_target("gog", "123", p, rec)
(ok if t and t["exe"] == str(gog_dir / "bin/witcher.exe") and t["platform"] == "windows" else bad)(
    f"GOG Windows resolves the PRIMARY game playTask ({t})")

# A title whose primary is a `launcher` chooser (Master of Magic's real shape) — match GOG's signal.
mom = tmp / "Games" / "GOG" / "MoM"
mom.mkdir(parents=True)
(mom / "goggame-456.info").write_text(json.dumps({"playTasks": [
    {"category": "launcher", "path": "Launcher.exe", "isPrimary": True},
    {"category": "game", "path": "DOSBOX/DOSBox.exe"},
    {"category": "document", "path": "manual.pdf"},
]}))
t = launch.resolve_target("gog", "456", p, {"path": str(mom), "platform": "windows"})
(ok if t and t["exe"] == str(mom / "Launcher.exe") else bad)(
    f"a launcher-category isPrimary task is the entry point, not a game task ({t})")

# -- GOG native Linux: the install-root start.sh, no compat tool --
rec_linux = {"path": str(gog_dir), "platform": "linux"}
t = launch.resolve_target("gog", "123", p, rec_linux)
(ok if t and t["exe"] == str(gog_dir / "start.sh") and t["platform"] == "linux" else bad)(
    f"GOG native resolves install-root start.sh ({t})")
(ok if launch.compat_tool(t["platform"]) is None else bad)(
    "and a native resolution carries no compat tool")

# -- managed-root ownership: Exe under a <volume>/Games/<store> root --
vols = [{"path": str(tmp), "label": "Internal", "free": 1}]
roots = launch.managed_roots({"NOVADECK_STORE_USER": "x"}, vols=vols)
(ok if launch.under_managed_root(str(install_dir / "Breathedge.exe"), roots) else bad)(
    "a game under <vol>/Games/Epic is ours")
(ok if launch.under_managed_root(str(gog_dir / "bin/witcher.exe"), roots) else bad)(
    "a game under <vol>/Games/GOG is ours")
(ok if not launch.under_managed_root("/usr/bin/retroarch", roots) else bad)(
    "a foreign binary outside our tree is not ours")
(ok if not launch.under_managed_root(str(tmp / "Games" / "Epic"), roots) else bad)(
    "the store root dir itself (no game under it) is not a game we own")
# a symlink that points out of the tree does not launder ownership
evil = tmp / "Games" / "Epic" / "escape"
os.symlink("/usr/bin/sh", evil)
(ok if not launch.under_managed_root(str(evil), roots) else bad)(
    "a symlink from inside the tree to /usr/bin is not ours (realpath defeats it)")
(ok if not launch.under_managed_root("", roots) and not launch.under_managed_root(None, roots) else bad)(
    "an empty or missing Exe is not ours")
PY

echo
echo "== protonfixes ids (UMU_ID + STORE) from the umu database"
pysuite "protonfix" <<'PY'
import pathlib, sys, tempfile
sys.path.insert(0, sys.argv[1])

def ok(m): print(f"  ok   {m}")
def bad(m): print(f"  FAIL {m}")

from novadeck_stores import launch

db = pathlib.Path(tempfile.mkdtemp(prefix="store-pfx.")) / "umu-database.csv"
db.write_text(
    "TITLE,STORE,CODENAME,UMU_ID,COMMON ACRONYM (Optional),NOTE (Optional),EXE_STRINGS (Optional)\n"
    "Age of Wonders,gog,1207658883,umu-61500,aow,,\n"
    "Age of Wonders,humble,ageofwonders,umu-61500,aow,,\n"
    "Borderlands 3,egs,Catnip,umu-397540,bl3,,\n"
    'Evil,gog,666,"umu-1; rm -rf ~",,,\n')

(ok if launch.protonfix_env("gog", "1207658883", db) == "STORE=gog UMU_ID=umu-61500" else bad)(
    "a GOG title is matched by its product id")
(ok if launch.protonfix_env("epic", "Catnip", db) == "STORE=egs UMU_ID=umu-397540" else bad)(
    "an Epic title is matched by legendary's app_name, under the database's `egs` store")
(ok if launch.protonfix_env("gog", "Catnip", db) == "" else bad)(
    "a codename only matches within its own store")
(ok if launch.protonfix_env("gog", "999", db) == "" else bad)(
    "a title the database does not know gets no ids — STORE alone would still key on the appid")
(ok if launch.protonfix_env("gog", "666", db) == "" else bad)(
    "a UMU_ID that is not umu-<alnum> is refused — LaunchOptions go through a shell")
(ok if launch.protonfix_env("gog", "1207658883", db.parent / "absent.csv") == "" else bad)(
    "no database means no ids, never a failed launch")
(ok if launch.PROTONFIX_DB.startswith(
    f"/usr/share/steam/compatibilitytools.d/{launch.WINDOWS_COMPAT_TOOL}/") else bad)(
    "the database read is the one shipped inside the Proton the titles run on")
PY

echo
echo "== first-run steps: what the plugin decides (first_run.py)"
pysuite "first_run" <<'PY'
import json, os, pathlib, sys, tempfile
sys.path.insert(0, sys.argv[1])

def ok(m): print(f"  ok   {m}")
def bad(m): print(f"  FAIL {m}")

from novadeck_stores import first_run

tmp = pathlib.Path(tempfile.mkdtemp(prefix="store-firstrun."))
p = {"NOVADECK_STORE_HOME": str(tmp), "GOGDL_CONFIG_PATH": str(tmp / "gogdl"),
     "NOVADECK_STORE_UID": str(os.getuid())}
manifests = tmp / "gogdl" / "heroic_gogdl" / "manifests"
manifests.mkdir(parents=True)

def install(gid, exe=None):
    d = tmp / "Games" / "GOG" / gid
    (d / "gog-support" / gid).mkdir(parents=True)
    if exe:
        (d / "gog-support" / gid / exe).write_text("MZ")
    return str(d)

# Witcher EE's real v2 shape (gogdl manifest on the S2, 2026-10-31).
w = install("1207658924", "galaxy_the_witcher_enhanced_edition_2.1.0.15.exe")
(manifests / "1207658924").write_text(json.dumps({
    "version": 2, "baseProductId": "1207658924", "buildId": "58076094395251196",
    "HGLInstallLanguage": "en-US", "HGLdlcs": [],
    "products": [{"productId": "1207658924", "temp_executable": "galaxy_the_witcher_enhanced_edition_2.1.0.15.exe"}]}))
steps, build_id = first_run.gog_steps(p, "1207658924", w)
argv = steps[0]["argv"] if steps else []
(ok if len(steps) == 1 and argv[0] == f"{w}/gog-support/1207658924/galaxy_the_witcher_enhanced_edition_2.1.0.15.exe" else bad)(
    f"a v2 temp_executable becomes one step on the support installer ({argv[:1]})")
win = "Z:" + w.replace("/", "\\")
(ok if f"/DIR={win}" in argv and "/VERYSILENT" in argv and "/ProductId=1207658924" in argv
     and "/buildId=58076094395251196" in argv and f"/supportDir={win}\\gog-support\\1207658924" in argv else bad)(
    "with the HW-proven arguments: silent, the install dir through Z:, product, build, support dir")
(ok if steps and steps[0]["env"] == {"FEX_X87REDUCEDPRECISION": "0"} and steps[0]["cwd"] == w else bad)(
    "run from the install dir with reduced x87 precision OFF — what un-garbles these installers")

# ISI-driven v2 and a missing exe give nothing; v1 support_commands are honoured.
i = install("111")
(manifests / "111").write_text(json.dumps({"version": 2, "scriptInterpreter": True,
    "products": [{"productId": "111", "temp_executable": "x.exe"}]}))
(ok if first_run.gog_steps(p, "111", i)[0] == [] else bad)(
    "a manifest that wants GOG's script interpreter gets no step (ISI lives in the redist we skip)")
m = install("222")
(manifests / "222").write_text(json.dumps({"version": 2,
    "products": [{"productId": "222", "temp_executable": "absent.exe"}]}))
(ok if first_run.gog_steps(p, "222", m)[0] == [] else bad)("a support exe that is not on disk gets no step")
v1 = install("333", "setup_333.exe")
(manifests / "333").write_text(json.dumps({"version": 1, "product": {"timestamp": 1,
    "support_commands": [{"gameID": "333", "executable": "setup_333.exe", "languages": ["Neutral"]},
                         {"gameID": "333", "executable": "setup_333.exe", "languages": ["Polish"]}]}}))
(ok if len(first_run.gog_steps(p, "333", v1)[0]) == 1 else bad)(
    "v1 support_commands give one step per English/Neutral command, none for other languages")
t = install("444", "ok.exe")
(manifests / "444").write_text(json.dumps({"version": 2,
    "products": [{"productId": "444", "temp_executable": "../ok.exe"}]}))
(ok if first_run.gog_steps(p, "444", t)[0] == [] else bad)(
    "an exe name with a path separator is refused — it would leave the product's support dir")
(ok if first_run.gog_steps(p, "999", w) == ([], None) else bad)("no gogdl manifest, no steps")

# build(): installed Windows GOG entries only, keyed by unsigned appid, id carries the build.
registry = {
    "gog:1207658924": {"appid": -733526434, "platform": "windows", "title": "Witcher"},
    "gog:333": {"appid": 5, "state": "shelf", "title": "Shelf"},
    "gog:222": {"appid": 6, "platform": "windows", "title": "No exe"},
    "epic:Catnip": {"appid": 7, "platform": "windows", "title": "BL3"},
}
records = {"gog:1207658924": {"path": w}, "gog:333": {"path": v1}, "gog:222": {"path": m}}
table = first_run.build(p, registry, records)
(ok if list(table) == [str(-733526434 & 0xFFFFFFFF)] else bad)(
    f"only the installed Windows GOG entry with a step is in the table, under its unsigned appid ({list(table)})")
(ok if table and next(iter(table.values()))["id"] == "gog:1207658924:58076094395251196" else bad)(
    "and its id names the build, so an update's new support installer runs again")
PY

echo
echo "== first-run steps: what a launch does with them (novadeck_firstrun.py)"
FR_OUT="$(python3 - "$ROOT/rootfs/overlay/usr/lib/novadeck" <<'PY'
import json, os, pathlib, stat, sys, tempfile
sys.path.insert(0, sys.argv[1])

def ok(m): print(f"  ok   {m}")
def bad(m): print(f"  FAIL {m}")

import novadeck_firstrun as fr
fr.log = lambda m: None

# The real composed chain (console_log, HW 2026-10-25), shell-split.
chain = ["/home/deck/.local/share/Steam/linuxarm64/steam-launch-wrapper", "--oom-score-adjust", "900", "--",
         "/home/deck/.local/share/Steam/steamrtarm64/reaper", "SteamLaunch", "AppId=4089089214", "--",
         "/home/deck/.local/share/Steam/steamapps/common/SteamLinuxRuntime_4-arm64/_v2-entry-point",
         "--verb=waitforexitandrun", "--",
         "/usr/share/steam/compatibilitytools.d/proton-cachyos-11.0-arm64/proton", "waitforexitandrun",
         "/home/deck/Games/Epic/Iris/PhoenixPointWin64.exe"]
pre = fr.chain_prefix(chain)
(ok if pre == chain[:-1] else bad)("the chain is cut right after Proton's verb, everything before it kept")
(ok if fr.chain_prefix(["/usr/bin/start.sh"]) is None else bad)("a launch with no Proton in it has no prefix")

tmp = pathlib.Path(tempfile.mkdtemp(prefix="firstrun."))
log = tmp / "calls.jsonl"
proton = tmp / "proton"
proton.write_text("#!/usr/bin/env python3\nimport json,os,sys\n"
                  f"open({str(log)!r},'a').write(json.dumps({{'argv':sys.argv[1:],'x87':os.environ.get('FEX_X87REDUCEDPRECISION'),'cwd':os.getcwd()}})+'\\n')\n"
                  "sys.exit(int(os.environ.get('FAKE_RC','0')))\n")
proton.chmod(0o755)
launch = [str(proton), "waitforexitandrun", "/games/w/launcher.exe"]
home = tmp / "home"; home.mkdir()
compat = tmp / "compatdata" / "123"
os.environ["STEAM_COMPAT_DATA_PATH"] = str(compat)
step = {"argv": ["/games/w/gog-support/1/setup.exe", "/VERYSILENT"], "cwd": str(tmp), "env": {"FEX_X87REDUCEDPRECISION": "0"}}
def table(entry): (home / "first-run.json").write_text(json.dumps({"123": entry}))
def calls(): return [json.loads(l) for l in log.read_text().splitlines()] if log.exists() else []

table({"id": "gog:1:b1", "steps": [step]})
rec = fr.run(launch, "123", home)
c = calls()
(ok if len(c) == 1 and c[0]["argv"] == ["waitforexitandrun", "/games/w/gog-support/1/setup.exe", "/VERYSILENT"] else bad)(
    f"the step runs through the launch's own chain with the game swapped for it ({c[:1]})")
(ok if c and c[0]["x87"] == "0" and c[0]["cwd"] == str(tmp) else bad)("with the step's env and cwd")
(ok if json.loads((compat / "novadeck-first-run.json").read_text())["id"] == "gog:1:b1" else bad)(
    "the outcome is recorded in the prefix, creating the compat dir when Proton has not yet")
(ok if fr.run(launch, "123", home) is None and len(calls()) == 1 else bad)("a recorded id is done: the next launch runs nothing")
(ok if "FEX_X87REDUCEDPRECISION" not in os.environ else bad)("the step's env never leaks into the game's")

table({"id": "gog:1:b2", "steps": [step]})
os.environ["FAKE_RC"] = "3"
rec = fr.run(launch, "123", home)
(ok if len(calls()) == 2 and rec["results"][0]["result"] == 3 else bad)("a new build id runs the steps again")
(ok if fr.run(launch, "123", home) is None and len(calls()) == 2 else bad)(
    "a FAILED step is recorded and not retried every launch — a hung installer must not stall every Play")
os.environ.pop("FAKE_RC")

(compat / "novadeck-first-run.json").unlink()
for name, entry in (("a relative exe", {"id": "x", "steps": [{"argv": ["setup.exe"]}]}),
                    ("a non-string arg", {"id": "x", "steps": [{"argv": ["/a.exe", 3]}]}),
                    ("no steps", {"id": "x", "steps": []}), ("no id", {"steps": [step]})):
    table(entry)
    (ok if fr.run(launch, "123", home) is None and len(calls()) == 2 else bad)(f"{name} is refused, nothing runs")
table({"id": "gog:1:b3", "steps": [step]})
(ok if fr.run(launch, "999", home) is None and fr.run(["/usr/bin/start.sh"], "123", home) is None and len(calls()) == 2 else bad)(
    "another appid, or a launch without Proton, runs nothing")
os.environ.pop("STEAM_COMPAT_DATA_PATH")
(ok if fr.run(launch, "123", home) is None and len(calls()) == 2 else bad)("no compat data path (not a Proton launch) runs nothing")

src = pathlib.Path(sys.argv[1], "game-launch").read_text()
main = src[src.index("def main"):]
(ok if main.index("novadeck_firstrun.run") < main.index("write_config(") else bad)(
    "game-launch runs the steps BEFORE it tunes — the installer gets its own FEX settings, not the game's")
PY
)"
printf '%s\n' "$FR_OUT"
PASS=$((PASS + $(grep -c '^  ok ' <<<"$FR_OUT" || true)))
FAIL=$((FAIL + $(grep -c '^  FAIL' <<<"$FR_OUT" || true)))
grep -q 'game-launch runs the steps BEFORE' <<<"$FR_OUT" || bad "the novadeck_firstrun checks crashed before the end"

echo
echo "test-store-launch.sh: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
