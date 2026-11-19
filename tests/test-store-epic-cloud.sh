#!/usr/bin/env bash
# Offline checks for the Epic cloud-save sidecar the store plugin writes for the launch path
# (.claude/plans/epic-cloud-saves.plan.md, step 3; design §4).
#
#   tests/test-store-epic-cloud.sh
#
# WHY THIS FILE EXISTS. An Epic game with cloud saves names its save folder in legendary's cached
# metadata (customAttributes.CloudSaveFolder, with CloudIncludeList / CloudExcludeList). A launch
# knows only its appid, so the plugin writes epic-cloud.json: unsigned appid → {token, gid, install,
# cloud}, keyed like galaxy.json, with the user's per-game switch (shared with GOG, per token) in
# `cloud.enabled`. The launch side resolves and syncs it (steps 4 and 5).
#
# WHAT IT CANNOT PROVE: that a game saves where its metadata says. That is the phase 3 HW gate.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STORES_PY="$ROOT/apps/decky/novadeck-stores/py_modules"

out="$(python3 - "$STORES_PY" <<'PY'
import json, os, pathlib, sys, tempfile
sys.path.insert(0, sys.argv[1])

def ok(m): print(f"  ok   {m}")
def bad(m): print(f"  FAIL {m}")
def check(cond, m): (ok if cond else bad)(m)

from novadeck_stores import cloud_config, epic_cloud, shortcuts

uid = os.getuid()
tmp = pathlib.Path(tempfile.mkdtemp(prefix="epic-cloud."))
home = tmp / "store-home"
lgd = home / "legendary"
(lgd / "metadata").mkdir(parents=True)
writes = []
def direct_write(pp, path, text):
    writes.append(path)
    pathlib.Path(path).write_text(text)
    return 0
epic_cloud.cli.write_as_user = direct_write
p = {"NOVADECK_STORE_HOME": str(home), "NOVADECK_STORE_UID": str(uid), "NOVADECK_STORE_USER": "deck",
     "LEGENDARY_CONFIG_PATH": str(lgd)}

def metadata(gid, attrs):
    (lgd / "metadata" / f"{gid}.json").write_text(json.dumps(
        {"app_name": gid, "app_title": gid, "metadata": {"customAttributes": {
            k: {"type": "STRING", "value": v} for k, v in attrs.items()}}}))

# ---------------------------------------------------------------------------------------------
print("== the save folder, from legendary's cached metadata (real values, HW 2026-11-19)")
DOOM = "5b60142e120c4f2d88027595c21d4a04"
metadata(DOOM, {"CloudSaveFolder": "{UserSavedGames}/Nightdive Studios/DOOM 64/saves/"})
check(epic_cloud.cloud_folder(p, DOOM) == {
          "supported": True, "location": "{UserSavedGames}/Nightdive Studios/DOOM 64/saves/",
          "include": None, "exclude": None},
      f"DOOM 64: supported, the location as Epic writes it, no filters ({epic_cloud.cloud_folder(p, DOOM)})")
FALLOUT = "f8ef168f3522419caad27d82878e0329"
metadata(FALLOUT, {"CloudSaveFolder": "{InstallDir}/", "CloudIncludeList": "*.sav, *.dat",
                   "CloudExcludeList": "critter.dat, master.dat"})
f = epic_cloud.cloud_folder(p, FALLOUT)
check(f and f["include"] == ["*.sav", "*.dat"] and f["exclude"] == ["critter.dat", "master.dat"],
      f"Fallout: filter lists split on commas, the spaces after them stripped ({f})")
metadata("Iris", {"CloudSaveFolder": "{appdata}/../locallow/Snapshot Games Inc/Phoenix Point/EGS/{EpicID}/",
                  "CloudExcludeList": "LocalData/,"})
f = epic_cloud.cloud_folder(p, "Iris")
check(f and f["exclude"] == ["LocalData/"] and f["include"] is None,
      f"an empty item in a list is dropped ({f})")
metadata("NoCloud", {"ThirdPartyManagedApp": "Origin"})
check(epic_cloud.cloud_folder(p, "NoCloud") == {"supported": False, "location": None, "include": None,
                                                "exclude": None},
      "no CloudSaveFolder: unsupported")
metadata("MacOnly", {"CloudSaveFolder_MAC": "{AppData}/Game"})
check(epic_cloud.cloud_folder(p, "MacOnly")["supported"] is False,
      "only a macOS folder: unsupported (we run the Windows build)")
metadata("Blank", {"CloudSaveFolder": "  "})
check(epic_cloud.cloud_folder(p, "Blank")["supported"] is False, "a blank folder: unsupported")
(lgd / "metadata" / "Odd.json").write_text(json.dumps(
    {"metadata": {"customAttributes": {"CloudSaveFolder": {"value": 7}}}}))
check(epic_cloud.cloud_folder(p, "Odd")["supported"] is False, "a folder that is not a string: unsupported")
check(epic_cloud.cloud_folder(p, "Missing") is None, "no cached metadata: None (unknown, not unsupported)")
(lgd / "metadata" / "Bad.json").write_text("not json")
check(epic_cloud.cloud_folder(p, "Bad") is None, "unparseable metadata: None")
(lgd / "metadata" / "Linked.json").symlink_to(lgd / "metadata" / f"{DOOM}.json")
check(epic_cloud.cloud_folder(p, "Linked") is None,
      "a symlinked metadata file is not followed: root reads a tree the user owns")

# ---------------------------------------------------------------------------------------------
print("== build")
registry = {
    f"epic:{DOOM}": {"appid": -1687350225, "title": "DOOM 64", "platform": "windows"},
    f"epic:{FALLOUT}": {"appid": 222, "platform": "windows"},
    "epic:NoCloud": {"appid": 333, "platform": "windows"},
    "epic:Missing": {"appid": 444, "platform": "windows"},
    "epic:Shelf": {"appid": 555, "state": "shelf"},
    "epic:NotInstalled": {"appid": 666, "platform": "windows"},
    "epic:MacOnly": {"appid": 777, "platform": "mac"},
    "gog:1": {"appid": 888, "platform": "windows"},
}
games = tmp / "Games" / "Epic"
records = {t: {"path": str(games / t.partition(":")[2]), "platform": "windows"}
           for t in registry if t not in ("epic:NotInstalled",)}
built = epic_cloud.build(p, registry, records, {})
key = str(-1687350225 & 0xFFFFFFFF)
check(sorted(built) == sorted([key, "222", "333", "444"]),
      f"every installed Epic Windows entry gets a row, keyed by UNSIGNED appid ({sorted(built)})")
check(built.get(key) == {"token": f"epic:{DOOM}", "gid": DOOM, "install": str(games / DOOM), "cloud": {
          "supported": True, "enabled": True, "location": "{UserSavedGames}/Nightdive Studios/DOOM 64/saves/",
          "include": None, "exclude": None}},
      f"DOOM 64's row: token, gid, install, and cloud ON by default ({built.get(key)})")
check(built["333"]["cloud"] == {"supported": False, "enabled": False, "location": None,
                                "include": None, "exclude": None},
      f"a game without cloud saves: unsupported, so never enabled ({built['333']['cloud']})")
check(built["444"]["cloud"] is None, "no metadata cached yet: cloud None, which the launch skips")
off = epic_cloud.build(p, registry, records, {f"epic:{DOOM}": False})
check(off[key]["cloud"]["supported"] is True and off[key]["cloud"]["enabled"] is False,
      "the user's switch off: supported, not enabled")
churned = {**registry, f"epic:{DOOM}": {**registry[f"epic:{DOOM}"], "appid": 999}}
moved = epic_cloud.build(p, churned, records, {})
check("999" in moved and key not in moved, "the row follows the registry's appid when the shortcut is re-created")

# ---------------------------------------------------------------------------------------------
print("== sync")
inst = home / "installs.json"
inst.write_text(json.dumps(records))
p = {**p, "NOVADECK_STORE_INSTALLS": str(inst)}
(home / cloud_config.TOGGLES).write_text(json.dumps({"epic:NoCloud": False, f"epic:{FALLOUT}": False}))
want = epic_cloud.build(p, registry, records, {f"epic:{FALLOUT}": False})
check(epic_cloud.sync(p, registry) is True, "sync reports the file current")
check(json.loads((home / epic_cloud.FILENAME).read_text()) == want,
      "sync writes the built table, with the stored switches (shared with GOG, per token)")
n = len(writes)
epic_cloud.sync(p, registry)
check(len(writes) == n, "an unchanged table is not rewritten")
check(epic_cloud.read(p) == want, "read returns the table")
(home / epic_cloud.FILENAME).unlink()
check(epic_cloud.read(p) == {}, "no file → an empty table")
empty = {"gog:1": registry["gog:1"]}
check(epic_cloud.sync(p, empty) is True and not (home / epic_cloud.FILENAME).exists(),
      "no Epic game: nothing is written")

# ---------------------------------------------------------------------------------------------
print("== the registry writer regenerates it")
synced = []
real_sync = epic_cloud.sync
epic_cloud.sync = lambda pp, rows: synced.append(rows)
shortcuts.cli.write_as_user = direct_write
try:
    shortcuts.write_registry(p, registry)
finally:
    epic_cloud.sync = real_sync
check(synced == [registry], "write_registry calls epic_cloud.sync with the rows it wrote")
PY
)"
rc=$?
printf '%s\n' "$out"
PASS=$(grep -c '^  ok ' <<<"$out" || true)
FAIL=$(grep -c '^  FAIL' <<<"$out" || true)
[ "$rc" -eq 0 ] || { echo "  FAIL the epic-cloud checks crashed (exit $rc) — every check after the crash never ran"; FAIL=$((FAIL + 1)); }

echo
echo "epic-cloud: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
