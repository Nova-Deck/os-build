#!/usr/bin/env bash
# Offline checks for the Epic cloud-save sync, before launch and after exit
# (.claude/plans/epic-cloud-saves.plan.md, steps 4 and 5; design §3).
#
#   tests/test-store-epicsync.sh
#
# WHY THIS FILE EXISTS. Before a cloud-enabled Epic game starts, game-launch asks legendary what a
# sync would do (`sync-saves --dry-run`, our patch 0001) and acts on the status: a cloud-only change
# is downloaded after the local folder is backed up (legendary deletes the local saves BEFORE it
# fetches the cloud's); a local-only change waits for the upload after exit; a conflict is the
# user's call. The machinery (lock, budget, picker, backups, status) is the GOG sync's, which
# tests/test-store-savesync.sh covers; this file covers what is Epic's: legendary's argv and
# verdicts, {EpicID}, the backup that follows the game's filters, and the whole-install refusal.
#
# legendary is stubbed (the `run` parameter), so this runs offline. WHAT IT CANNOT PROVE: that
# Epic's cloud answers the way the stub does. That is the phase 3 HW gate.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/rootfs/overlay/usr/lib/novadeck"

out="$(python3 - "$LIB" <<'PY'
import json, os, pathlib, subprocess, sys, tempfile
sys.path.insert(0, sys.argv[1])

def ok(m): print(f"  ok   {m}")
def bad(m): print(f"  FAIL {m}")
def check(cond, m): (ok if cond else bad)(m)

import novadeck_epicsaves as es
import novadeck_savesync as ss
ss.log = lambda m: logs.append(m)
logs = []

tmp = pathlib.Path(tempfile.mkdtemp(prefix="epicsync."))
home = tmp / "stores"
lgd = home / "legendary"
lgd.mkdir(parents=True)
(home / "gogdl").mkdir()
EPIC_ID = "0123456789abcdef0123456789abcdef"
(lgd / "user.json").write_text(json.dumps({"account_id": EPIC_ID, "displayName": "x"}))
paths = {"NOVADECK_STORE_HOME": str(home), "NOVADECK_GOGDL_AUTH": str(home / "gogdl" / "auth.json"),
         "GOGDL_CONFIG_PATH": str(home / "gogdl"), "LEGENDARY_CONFIG_PATH": str(lgd)}
prefix = tmp / "compatdata" / "2607617071" / "pfx"
user = prefix / "drive_c" / "users" / "steamuser"
user.mkdir(parents=True)
install = tmp / "Games" / "Epic" / "doom64"
install.mkdir(parents=True)
GID = "5b60142e120c4f2d88027595c21d4a04"
TOKEN = f"epic:{GID}"
APPID = "2607617071"
DOOM = "{UserSavedGames}/Nightdive Studios/DOOM 64/saves/"
SAVES = user / "Saved Games" / "Nightdive Studios" / "DOOM 64" / "saves"
SP = str(SAVES)

def epic_row(enabled=True, location=DOOM, include=None, exclude=None, supported=True, cloud=True):
    c = {"supported": supported, "enabled": enabled, "location": location, "include": include,
         "exclude": exclude} if cloud else None
    (home / "epic-cloud.json").write_text(json.dumps(
        {APPID: {"token": TOKEN, "gid": GID, "install": str(install), "cloud": c}}))

def local(files, where=SAVES):
    where.mkdir(parents=True, exist_ok=True)
    for name, text in files.items():
        (where / name).parent.mkdir(parents=True, exist_ok=True)
        (where / name).write_text(text)

def verdict(status, local_newest=1795040000.0, cloud_newest=1795050000.0, path=SP, app=GID):
    return {"app_name": app, "status": status, "save_path": path, "local_newest": local_newest,
            "cloud_newest": cloud_newest, "cloud_manifest": "2026.11.19-10.00.00.manifest",
            "last_sync": 1795000000.0}

class Legendary:
    """Stands in for subprocess.run(legendary ...). verdicts: --save-path -> dry-run JSON (or str)."""
    def __init__(self, verdicts=None, rc=0, real_rc=0, stderr="", raise_on=None):
        self.calls, self.envs, self.verdicts = [], [], verdicts or {}
        self.rc, self.real_rc, self.stderr, self.raise_on = rc, real_rc, stderr, raise_on
    def __call__(self, argv, **kw):
        self.calls.append(argv)
        self.envs.append(kw.get("env") or {})
        path = argv[argv.index("--save-path") + 1]
        if self.raise_on and self.raise_on in argv:
            raise subprocess.TimeoutExpired(argv, kw.get("timeout"))
        if "--dry-run" in argv:
            v = self.verdicts.get(path)
            out = v if isinstance(v, str) else json.dumps(v)
            return subprocess.CompletedProcess(argv, self.rc, stdout=out + "\n", stderr=self.stderr)
        if self.real_rc == 0 and ("--skip-upload" in argv or "--force-download" in argv):
            p = pathlib.Path(path)  # legendary deletes the local saves, then writes the cloud's
            for f in (p.rglob("*") if p.exists() else []):
                if f.is_file():
                    f.unlink()
            p.mkdir(parents=True, exist_ok=True)
            (p / "slot1.dsg").write_text("from the cloud")
        return subprocess.CompletedProcess(argv, self.real_rc, stdout="", stderr=self.stderr)
    def real(self):
        return [c for c in self.calls if "--dry-run" not in c]

def run(leg, choose=None, appid=APPID):
    os.environ.pop(ss.STARTED_ENV, None)
    logs.clear()
    return ss.pre_launch(appid, paths=paths, prefix=str(prefix), run=leg, choose=choose)

def after(leg, appid=APPID):
    logs.clear()
    return ss.post_exit(appid, str(prefix), paths=paths, run=leg)

def backups():
    d = home / ss.BACKUPS / TOKEN / "saves"
    return sorted(d.iterdir()) if d.exists() else []

def status():
    f = home / "gogdl" / ss.STATUS
    return json.loads(f.read_text()).get(TOKEN) if f.exists() else None

print("== when nothing is asked of legendary")
for row, m in (({"enabled": False}, "cloud sync off for the game"),
               ({"supported": False, "enabled": False}, "a game without cloud saves"),
               ({"cloud": False}, "no metadata cached yet (cloud None)")):
    epic_row(**row)
    leg = Legendary()
    check(run(leg) == [] and not leg.calls, f"{m}: legendary is never called")
epic_row()
check(run(Legendary(), appid="999") == [], "an appid with no row: nothing")
row = ss.cloud_row(str(home), APPID)
check(row and row["store"] == "epic" and row["cloud"]["locations"] == [{"name": "saves", "location": DOOM}],
      f"an Epic row reads as one location named 'saves', so the shared machinery runs it ({row})")

print("== the dry run")
leg = Legendary({SP: verdict("same_age")})
res = run(leg)
dry = leg.calls[0] if leg.calls else []
check(dry == [es.LEGENDARY, "sync-saves", GID, "--save-path", SP, "--dry-run"],
      f"legendary sync-saves <app> --save-path <the resolved folder> --dry-run ({dry})")
env = leg.envs[0] if leg.envs else {}
check(env.get("LEGENDARY_CONFIG_PATH") == str(lgd), "legendary runs with the store's config dir")
os.environ["LD_PRELOAD"] = "/game/hook.so"
run(Legendary({SP: verdict("same_age")}))
leg = Legendary({SP: verdict("same_age")})
run(leg)
check("LD_PRELOAD" not in leg.envs[0], "the game's LD_PRELOAD is not handed to legendary")
os.environ.pop("LD_PRELOAD")
check(res == [{"name": "saves", "action": "none", "did": "nothing"}] and not leg.real(),
      f"same_age: nothing ({res})")
for st, action in (("no_save", "none"), ("local_newer", "upload")):
    leg = Legendary({SP: verdict(st)})
    res = run(leg)
    check(res and res[0]["action"] == action and res[0]["did"] == "nothing" and not leg.real(),
          f"{st}: nothing before the launch ({res})")
leg = Legendary({SP: "not json"})
res = run(leg)
check(res and res[0]["did"] == "skipped" and "no verdict" in res[0]["reason"], f"garbage: skipped ({res})")
leg = Legendary({SP: verdict("same_age", app="SomeOtherGame")})
res = run(leg)
check(res and res[0]["did"] == "skipped", f"a verdict for another game is not this one's ({res})")
leg = Legendary({SP: verdict("unsupported")})
res = run(leg)
check(res and res[0]["did"] == "skipped" and "unsupported" in res[0]["reason"] and not leg.real(),
      f"legendary says unsupported: skipped, saying so ({res})")
leg = Legendary({SP: verdict("remote_newer")}, rc=1, stderr="[cli] ERROR: Login failed! Cannot continue")
res = run(leg)
check(res and res[0]["did"] == "skipped" and "Login failed" in res[0]["reason"] and not leg.real(),
      f"a failing dry run is skipped with legendary's own words ({res})")
OFFLINE_TB = ("Traceback (most recent call last):\n"
              "requests.exceptions.ConnectionError: HTTPSConnectionPool(host='account-public-service-prod03"
              ".ol.epicgames.com', port=443): Max retries exceeded")
res = run(Legendary({SP: verdict("remote_newer")}, rc=1, stderr=OFFLINE_TB))
check(res and res[0]["reason"] == es.OFFLINE, f"offline: '{es.OFFLINE}' ({res})")
res = run(Legendary({SP: verdict("remote_newer")}, raise_on="--dry-run"))
check(res and res[0]["did"] == "skipped" and "timed out" in res[0]["reason"],
      f"a hung legendary is cut off; the launch goes on ({res})")

print("== remote_newer: back up, then download")
local({"slot1.dsg": "mine", "sub/slot2.dsg": "mine too"})
leg = Legendary({SP: verdict("remote_newer")})
res = run(leg)
check(res == [{"name": "saves", "action": "download", "did": "downloaded"}], f"downloaded ({res})")
check(leg.real() == [[es.LEGENDARY, "-y", "sync-saves", GID, "--save-path", SP, "--skip-upload"]],
      f"legendary -y sync-saves <app> --save-path <folder> --skip-upload ({leg.real()})")
kept = backups()
check(len(kept) == 1 and (kept[0] / "slot1.dsg").read_text() == "mine"
      and (kept[0] / "sub" / "slot2.dsg").read_text() == "mine too",
      "the local saves were backed up first, sub-folders too")
check(TOKEN not in json.dumps(json.loads((home / "gogdl" / ss.TIMESTAMPS).read_text())
                              if (home / "gogdl" / ss.TIMESTAMPS).exists() else {}),
      "no timestamp is stored for Epic: legendary keeps its own in installed.json")
check(status() and status()["phase"] == "launch" and status()["outcomes"] == res,
      "the run is recorded for the game page, under the game's token")
for f in SAVES.rglob("*"):
    if f.is_file():
        f.unlink()
leg = Legendary({SP: verdict("remote_newer", local_newest=None)})
n = len(backups())
res = run(leg)
check(res and res[0]["did"] == "downloaded" and len(backups()) == n,
      "an empty local folder downloads with nothing to back up")
local({"slot1.dsg": "mine"})
real_backup = ss.Session.backup
ss.Session.backup = lambda self, name, path, include=None, exclude=None: False
try:
    leg = Legendary({SP: verdict("remote_newer")})
    res = run(leg)
finally:
    ss.Session.backup = real_backup
check(res and res[0]["did"] == "failed" and not leg.real() and (SAVES / "slot1.dsg").read_text() == "mine",
      f"a failed backup stops the download: the local save is untouched ({res})")
leg = Legendary({SP: verdict("remote_newer")}, real_rc=1, stderr=OFFLINE_TB)
res = run(leg)
check(res and res[0]["did"] == "failed" and res[0]["reason"] == es.OFFLINE,
      f"a download that fails offline says so ({res})")

print("== conflict: the user's call")
local({"slot1.dsg": "mine"})
asked = []
def answer(a):
    def choose(appid, index, name, v):
        asked.append((appid, index, name, v))
        return a
    return choose
leg = Legendary({SP: verdict("conflict")})
res = run(leg, choose=answer(None))
check(res and res[0]["did"] == "kept-local" and not leg.real(), f"no answer: local kept, nothing synced ({res})")
a = asked[-1] if asked else None
check(a and a[:3] == (APPID, 0, "saves") and a[3]["local"]["newest"] == 1795040000.0
      and a[3]["cloud"]["newest"] == 1795050000.0,
      f"the picker gets both dates in the shape ask() reads ({a})")
n = len(backups())
leg = Legendary({SP: verdict("conflict")})
res = run(leg, choose=answer("cloud"))
check(res and res[0]["did"] == "downloaded" and len(backups()) == n + 1
      and leg.real() and leg.real()[0][-1] == "--force-download",
      f"'cloud': back up, then --force-download ({res}, {leg.real()})")
leg = Legendary({SP: verdict("conflict")})
res = run(leg, choose=answer("local"))
check(res and res[0]["did"] == "uploaded" and leg.real() and leg.real()[0][-1] == "--force-upload",
      f"'local': --force-upload ({res})")

print("== where the folder is")
epic_row(location="{AppData}/../LocalLow/Snapshot Games Inc/Phoenix Point/EGS/{EpicID}/")
pp = user / "AppData" / "LocalLow" / "Snapshot Games Inc" / "Phoenix Point" / "EGS" / EPIC_ID
leg = Legendary({str(pp): verdict("same_age", path=str(pp))})
res = run(leg)
check(res and res[0]["did"] == "nothing" and leg.calls and leg.calls[0][4] == str(pp),
      f"{{EpicID}} is the account id from legendary's user.json ({leg.calls[:1]})")
(lgd / "user.json").rename(lgd / "user.json.away")
leg = Legendary()
res = run(leg)
check(res and res[0]["did"] == "skipped" and "EpicID" in res[0]["reason"] and not leg.calls,
      f"no account id: a location with {{EpicID}} is skipped, saying why ({res})")
(lgd / "user.json.away").rename(lgd / "user.json")
epic_row(location="%APPDATA%/Game")
leg = Legendary()
res = run(leg)
check(res and res[0]["did"] == "skipped" and not leg.calls, f"a refused location never reaches legendary ({res})")
epic_row(location="{InstallDir}/")
leg = Legendary()
res = run(leg)
check(res and res[0]["did"] == "skipped" and "install" in res[0]["reason"] and not leg.calls,
      f"the whole install folder with no include list is refused: a download would delete the game ({res})")

print("== a folder narrowed by filters (Fallout's Epic install, HW 2026-11-19)")
# The whole install, *.sav and *.dat minus critter.dat and master.dat. Four language folders each
# carry an uppercase MASTER.DAT and CRITTER.DAT (2.2 GB in all); the save is uppercase too.
epic_row(location="{InstallDir}/", include=["*.sav", "*.dat"], exclude=["critter.dat", "master.dat"])
game = {f"Fallout 1 {lang}/{name}": "game data" for lang in ("English", "French", "German", "Spanish")
        for name in ("MASTER.DAT", "CRITTER.DAT")}
game["Fallout 1 English/falloutwHR.exe"] = "the game"
local(game, where=install)
SLOT = "Fallout 1 English/DATA/SAVEGAME/SLOT01"
local({f"{SLOT}/SAVE.DAT": "slot", f"{SLOT}/V13ENT.SAV": "map", f"{SLOT}/AUTOMAP.SAV": "automap"},
      where=install)
IP = str(install)
leg = Legendary({IP: verdict("remote_newer", path=IP)})
res = run(leg)
kept = sorted(p.relative_to(b).as_posix() for b in backups()[-1:] for p in b.rglob("*") if p.is_file())
check(res and res[0]["did"] == "downloaded", f"the include list makes the install folder syncable ({res})")
check(kept == sorted([f"{SLOT}/AUTOMAP.SAV", f"{SLOT}/SAVE.DAT", f"{SLOT}/V13ENT.SAV"]),
      f"the backup holds exactly the saves, uppercase ones too: what legendary (patch 0002) deletes ({kept})")
check(not any(k.endswith(("MASTER.DAT", "CRITTER.DAT", ".exe")) for k in kept),
      "...never the game's data: the exclude list applies, in any case (about 2 GB per backup otherwise)")
n = len(backups())
local(game, where=install)  # the stub's download deleted everything under the folder; the game is back
for f in [*install.rglob("*.SAV"), install / SLOT / "SAVE.DAT"]:
    f.unlink(missing_ok=True)
res = run(Legendary({IP: verdict("remote_newer", path=IP)}))
check(res and res[0]["did"] == "downloaded" and len(backups()) == n,
      "with no save left, only game data the filters exclude: nothing to back up, no empty backup")

print("== after the game exits")
epic_row()
local({"slot1.dsg": "played"})
leg = Legendary({SP: verdict("local_newer")})
res = after(leg)
check(res == [{"name": "saves", "action": "upload", "did": "uploaded"}]
      and leg.real() == [[es.LEGENDARY, "-y", "sync-saves", GID, "--save-path", SP, "--skip-download"]],
      f"local_newer: --skip-download uploads ({res}, {leg.real()})")
check(status() and status()["phase"] == "exit", "the exit run is recorded too")
NOTHING = ("[Core] INFO: Packing savegame for \"Fallout\", input folder: /g\n"
           "[SGH] WARNING: No save files matching the specified filters have been found.\n"
           "[Core] INFO: No files to upload. If you believe this is incorrect run command with \"--disable-filters\"\n")
leg = Legendary({SP: verdict("local_newer")}, stderr=NOTHING)
res = after(leg)
check(res and res[0]["did"] == "skipped" and "nothing uploaded" in res[0]["reason"] and leg.real(),
      f"an upload where legendary packed nothing is NOT 'uploaded' (Fallout, HW 2026-11-19) ({res})")
check(status() and status()["outcomes"][0]["did"] == "skipped",
      "...and the game page's record says so")
local({"slot1.dsg": "mine"})
leg = Legendary({SP: verdict("conflict")}, stderr=NOTHING)
res = run(leg, choose=answer("local"))
check(res and res[0]["did"] == "skipped" and "nothing uploaded" in res[0]["reason"],
      f"the same for 'This device's saves' (--force-upload) ({res})")
for st, did in (("conflict", "next-launch"), ("remote_newer", "nothing"), ("same_age", "nothing")):
    leg = Legendary({SP: verdict(st)})
    res = after(leg)
    check(res and res[0]["did"] == did and not leg.real(), f"{st} after exit: {did} ({res})")
PY
)"
rc=$?
printf '%s\n' "$out"
PASS=$(grep -c '^  ok ' <<<"$out" || true)
FAIL=$(grep -c '^  FAIL' <<<"$out" || true)
[ "$rc" -eq 0 ] || { echo "  FAIL the epic sync checks crashed (exit $rc) — every check after the crash never ran"; FAIL=$((FAIL + 1)); }

echo
echo "epicsync: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
