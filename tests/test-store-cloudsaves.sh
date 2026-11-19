#!/usr/bin/env bash
# Offline checks for the game page's "Cloud saves" row (.claude/plans/gog-galaxy-comet.plan.md,
# phase 3 step 8).
#
#   tests/test-store-cloudsaves.sh
#
# WHY THIS FILE EXISTS. An installed GOG game's page shows whether its saves sync with GOG's cloud,
# a switch to turn that off and on again, when they last synced, and what went wrong the last time
# one did not. The switch is the user's (cloud-saves.json, absent = on); the launch side reads it
# through galaxy.json's `cloud.enabled`, so a switch that does not reach galaxy.json at once would
# sync a game the user just turned off. The page must also say WHY a game has no switch (GOG has
# no cloud saves for it, its config is not fetched yet, the install names no Galaxy client) and why
# a sync did nothing: the launch side records each run's outcome (novadeck_savesync, STATUS), and a
# reason computed there must reach the screen, not just a log.
#
# WHAT IT CANNOT PROVE: the row on the device, or that the launch then honours the switch. That is
# the phase 3 HW gate.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STORES_PY="$ROOT/apps/decky/novadeck-stores/py_modules"
LIB="$ROOT/rootfs/overlay/usr/lib/novadeck"

out="$(python3 - "$STORES_PY" "$LIB" <<'PY'
import asyncio, json, os, pathlib, sys, tempfile, types
sys.path.insert(0, sys.argv[1])

def ok(m): print(f"  ok   {m}")
def bad(m): print(f"  FAIL {m}")
def check(cond, m): (ok if cond else bad)(m)

sys.modules["decky"] = types.SimpleNamespace(logger=types.SimpleNamespace(info=lambda *a: None))
sys.path.insert(0, os.path.join(sys.argv[1], ".."))
import main
from novadeck_stores import cloud_config, cloud_saves, galaxy

tmp = pathlib.Path(tempfile.mkdtemp(prefix="cloud-saves."))
(tmp / "gogdl").mkdir()
p = {"NOVADECK_STORE_HOME": str(tmp), "NOVADECK_STORE_UID": str(os.getuid()),
     "NOVADECK_STORE_USER": "deck", "GOGDL_CONFIG_PATH": str(tmp / "gogdl")}
main.paths.store_paths = lambda ensure=False: p
writes = []
def direct_write(pp, path, text):
    writes.append(path)
    pathlib.Path(path).write_text(text)
    return 0
cloud_saves.cli.write_as_user = direct_write

AW, NOCID, UNKNOWN, NONE = "2588025602", "11", "12", "13"
TOKEN = "gog:1207658845"
CID = "49843177965810898"
LOCS = [{"name": "saves", "location": "<?DOCUMENTS?>/Another World"}]
def rows(enabled=True):
    return {
        AW: {"token": TOKEN, "gid": "1207658845", "clientId": CID, "comet": True, "install": "/g/aw",
             "cloud": {"supported": True, "enabled": enabled, "locations": LOCS}},
        NOCID: {"token": "gog:11", "gid": "11", "clientId": None, "comet": False, "install": "/g/11",
                "cloud": None},
        UNKNOWN: {"token": "gog:12", "gid": "12", "clientId": "12", "comet": False, "install": "/g/12",
                  "cloud": None},
        NONE: {"token": "gog:13", "gid": "13", "clientId": "13", "comet": False, "install": "/g/13",
               "cloud": {"supported": False, "enabled": False, "locations": []}}}
def write_galaxy(table):
    (tmp / galaxy.FILENAME).write_text(json.dumps(table))
write_galaxy(rows())

print("== one file each, shared with the launch side")
sys.path.insert(0, sys.argv[2])
import novadeck_savesync as ss
check(cloud_saves.TIMESTAMPS == ss.TIMESTAMPS and cloud_saves.STATUS == ss.STATUS,
      f"the page reads the files game-launch writes ({cloud_saves.TIMESTAMPS}, {cloud_saves.STATUS})")
check(cloud_config.TOGGLES == cloud_saves.TOGGLES, "and the switch is the file galaxy.sync reads")

print("== which games get a row, and why the others have no switch")
check(cloud_saves.page(p, "999") == {"state": "none"}, "an appid with no galaxy.json row: no row at all")
check(cloud_saves.page(p, NOCID) == {"state": "unavailable", "why": "no-client"},
      "an install that names no Galaxy client id: unavailable, and why (cloud saves key on it)")
check(cloud_saves.page(p, UNKNOWN) == {"state": "unavailable", "why": "unknown"},
      "GOG's config not fetched yet (offline): unavailable, and that it is not KNOWN yet, not 'none'")
check(cloud_saves.page(p, NONE) == {"state": "unavailable", "why": "unsupported"},
      "GOG has no cloud saves for the game: unavailable, and why")

print("== on, off, and when it last synced")
check(cloud_saves.page(p, AW) == {"state": "on", "lastSync": None, "notes": []},
      f"on, never synced: no date ({cloud_saves.page(p, AW)})")
(tmp / "gogdl" / ss.TIMESTAMPS).write_text(json.dumps({
    f"{TOKEN}:saves": "1795075719.333661", f"{TOKEN}:other": "1795076015.457527",
    "gog:999:saves": "1800000000.0", f"{TOKEN}:bad": "not a number"}))
check(cloud_saves.page(p, AW)["lastSync"] == 1795076015.457527,
      "the last sync is the newest stamp of THIS game's locations (another game's, or garbage, ignored)")
write_galaxy(rows(enabled=False))
check(cloud_saves.page(p, AW)["state"] == "off", "a row with cloud.enabled false reads off")
write_galaxy(rows())

print("== what the last sync did, in words")
def status(record):
    (tmp / "gogdl" / ss.STATUS).write_text(json.dumps({TOKEN: record}))
    return cloud_saves.page(p, AW)["notes"]
check(status({"at": 1, "phase": "launch", "outcomes": [{"name": "saves", "action": "none", "did": "nothing"}]}) == [],
      "a clean run: no notes")
notes = status({"at": 1, "phase": "exit", "outcomes": [
    {"name": "saves", "action": "upload", "did": "failed", "reason": "save-sync --skip-download exited 2: boom"}]})
check(len(notes) == 1 and "saves" in notes[0] and "exited 2: boom" in notes[0] and "exit" in notes[0],
      f"a failed upload: the location, the reason, and that it was after the game exited ({notes})")
notes = status({"at": 1, "phase": "launch", "outcomes": [
    {"name": "mac", "did": "skipped", "reason": "<?APPLICATION_SUPPORT?> is a macOS location"}]})
check(len(notes) == 1 and "mac" in notes[0] and "macOS" in notes[0] and "launch" in notes[0],
      f"a refused location: named, with the resolver's reason, at launch ({notes})")
for did in ("kept-local", "next-launch"):
    notes = status({"at": 1, "phase": "exit", "outcomes": [{"name": "saves", "action": "conflict", "did": did}]})
    check(len(notes) == 1 and "saves" in notes[0] and "next launch" in notes[0],
          f"{did}: changed on both sides, so the next launch asks ({notes})")
notes = status({"at": 1, "phase": "launch", "outcomes": [],
                "reason": "an upload from the last exit is still running; saves not synced"})
check(notes == ["Not synced at the last launch: an upload from the last exit is still running; saves not synced"],
      f"a run that synced nothing at all says why ({notes})")
for junk in ([], "x", {"outcomes": "x"}, {"outcomes": [5, {"did": "failed"}]}, {"reason": 7}):
    (tmp / "gogdl" / ss.STATUS).write_text(json.dumps({TOKEN: junk}))
    try:
        n = cloud_saves.page(p, AW)["notes"]
        good = isinstance(n, list) and all(isinstance(s, str) for s in n)
    except Exception as exc:  # noqa: BLE001
        good, n = False, exc
    check(good, f"a malformed record ({junk!r}) never breaks the page ({n})")
notes = status({"at": 1, "phase": "exit", "outcomes": [{"name": "saves", "did": "failed", "reason": "r" * 900}]})
check(len(notes[0]) < 400, "a long reason is cut, not a wall of text on the page")
(tmp / "gogdl" / ss.STATUS).unlink()

print("== the switch")
writes.clear()
res = cloud_saves.set_enabled(p, AW, False)
toggles = json.loads((tmp / cloud_config.TOGGLES).read_text())
check(toggles == {TOKEN: False}, f"off is stored under the game's TOKEN, which outlives an appid change ({toggles})")
check(galaxy.read(p)[AW]["cloud"]["enabled"] is False,
      "galaxy.json says off AT ONCE: the next launch reads it, not the next library sync")
check(res["state"] == "off", f"the answer is the row's new state ({res})")
again = galaxy.attach_cloud({AW: {k: v for k, v in rows()[AW].items() if k != "cloud"}},
                            {CID: {"supported": True, "locations": LOCS}}, cloud_config.toggles(p))
check(again[AW]["cloud"] == galaxy.read(p)[AW]["cloud"],
      "a later library sync (galaxy.sync) computes the SAME row from the stored switch")
check(cloud_saves.set_enabled(p, AW, True)["state"] == "on" and galaxy.read(p)[AW]["cloud"]["enabled"] is True
      and json.loads((tmp / cloud_config.TOGGLES).read_text()) == {TOKEN: True},
      "and back on")
(tmp / cloud_config.TOGGLES).write_text(json.dumps({"gog:13": False}))
cloud_saves.set_enabled(p, AW, False)
check(json.loads((tmp / cloud_config.TOGGLES).read_text()) == {"gog:13": False, TOKEN: False},
      "other games' switches are kept")
writes.clear()
for appid, why in ((NONE, "no cloud saves"), (UNKNOWN, "not known"), ("999", "no row"), (NOCID, "no client id")):
    res = cloud_saves.set_enabled(p, appid, False)
    check("error" in res and not writes, f"a game with {why}: refused, nothing written ({res})")
for value in ("false", 0, None):
    res = cloud_saves.set_enabled(p, AW, value)
    check("error" in res and not writes, f"a switch value that is not a bool ({value!r}): refused")
def failing_write(pp, path, text):
    return 1
cloud_saves.cli.write_as_user = failing_write
res = cloud_saves.set_enabled(p, AW, True)
cloud_saves.cli.write_as_user = direct_write
check("error" in res and galaxy.read(p)[AW]["cloud"]["enabled"] is False,
      f"a switch that cannot be stored says so, and galaxy.json keeps the old state ({res})")

print("== the plugin's calls")
plugin = main.Plugin()
check(asyncio.run(plugin.cloud_saves(int(AW))) == cloud_saves.page(p, AW),
      "cloud_saves(appid) is the page's row")
check(asyncio.run(plugin.cloud_saves(int(AW) - (1 << 32))) == cloud_saves.page(p, AW),
      "a signed appid (Steam hands out both) reads the same row")
check(asyncio.run(plugin.set_cloud_saves(int(AW), True))["state"] == "on", "set_cloud_saves(appid, on)")
check("error" in asyncio.run(plugin.set_cloud_saves(int(AW), "yes")), "set_cloud_saves refuses a non-bool")
print("  -- cloudsaves checks finished")
PY
)"
printf '%s\n' "$out"
PASS=$(grep -c '^  ok ' <<<"$out" || true)
FAIL=$(grep -c '^  FAIL' <<<"$out" || true)
grep -q 'cloudsaves checks finished' <<<"$out" || { echo "  FAIL the cloud-saves checks crashed before the end"; FAIL=$((FAIL + 1)); }

echo
echo "cloudsaves: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
