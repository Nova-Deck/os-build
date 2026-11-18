#!/usr/bin/env bash
# Offline checks for the Galaxy sidecar the store plugin writes for the launch path
# (.claude/plans/gog-galaxy-comet.plan.md, phase 1 step 4).
#
#   tests/test-store-galaxy.sh
#
# WHY THIS FILE EXISTS. A GOG game built on the Galaxy SDK signs in through the Galaxy client
# service on 127.0.0.1:9977, and Another World 20th Anniversary dies at its first achievement
# unlock when nothing answers. game-launch starts Comet for those games, and a launch knows only
# its appid, so the plugin writes galaxy.json: unsigned appid → {token, gid, clientId, comet}.
# `comet` says whether the install ships the SDK DLL; `clientId` is the Galaxy client id from the
# game's goggame-<gid>.info (cloud saves key on it in phase 3).
#
# WHAT IT CANNOT PROVE: that Comet answers the game. That is the phase 1 hardware gate.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STORES_PY="$ROOT/apps/decky/novadeck-stores/py_modules"

out="$(python3 - "$STORES_PY" <<'PY'
import json, os, pathlib, sys, tempfile
sys.path.insert(0, sys.argv[1])

def ok(m): print(f"  ok   {m}")
def bad(m): print(f"  FAIL {m}")
def check(cond, m): (ok if cond else bad)(m)

from novadeck_stores import galaxy, shortcuts

uid = os.getuid()
tmp = pathlib.Path(tempfile.mkdtemp(prefix="galaxy."))

# ---------------------------------------------------------------------------------------------
print("== Galaxy SDK detection")
unity = tmp / "unity"
(unity / "Game_Data" / "Plugins" / "x86_64").mkdir(parents=True)
(unity / "Game_Data" / "Plugins" / "x86_64" / "Galaxy64.dll").write_bytes(b"MZ")
check(galaxy.has_galaxy_sdk(str(unity)) is True, "Galaxy64.dll three directories down is found (Unity's Plugins dir)")

upper = tmp / "upper"
upper.mkdir()
(upper / "GALAXY.DLL").write_bytes(b"MZ")
check(galaxy.has_galaxy_sdk(str(upper)) is True, "the name matches in any case (GALAXY.DLL)")

plain = tmp / "plain"
(plain / "bin").mkdir(parents=True)
(plain / "bin" / "game.exe").write_bytes(b"MZ")
(plain / "bin" / "GalaxyPeer.dll").write_bytes(b"MZ")
check(galaxy.has_galaxy_sdk(str(plain)) is False, "no SDK DLL → False (GalaxyPeer.dll alone is not the SDK)")

linked = tmp / "linked"
linked.mkdir()
(linked / "elsewhere").symlink_to(unity)
check(galaxy.has_galaxy_sdk(str(linked)) is False,
      "a symlinked directory is not followed: root walks a tree the user owns")
check(galaxy.has_galaxy_sdk(str(tmp / "missing")) is False, "a missing install is False, not a raise")

# ---------------------------------------------------------------------------------------------
print("== clientId from goggame-<gid>.info")
# Another World 20th Anniversary's clientId, read off the Pocket Max on 2026-11-17.
(unity / "goggame-1207660413.info").write_text(json.dumps(
    {"clientId": "49843177965810898", "gameId": "1207660413", "name": "Another World"}))
check(galaxy.client_id(str(unity), "1207660413", uid) == "49843177965810898", "the info file's clientId is read")
check(galaxy.client_id(str(plain), "1", uid) is None, "no info file → None")
(upper / "goggame-7.info").write_text(json.dumps({"clientId": 49843177965810898}))
check(galaxy.client_id(str(upper), "7", uid) is None, "a clientId that is not a string → None")
(upper / "goggame-8.info").write_text("not json")
check(galaxy.client_id(str(upper), "8", uid) is None, "an unparseable info file → None")

# ---------------------------------------------------------------------------------------------
print("== build")
registry = {
    "gog:1207660413": {"appid": -123456, "title": "Another World", "exe": str(unity / "anowor.exe"),
                       "platform": "windows"},
    "gog:1": {"appid": 222, "exe": str(plain / "bin" / "game.exe"), "platform": "windows"},
    "gog:2": {"appid": 333, "state": "shelf"},
    "gog:3": {"appid": 555, "exe": str(upper / "x.exe"), "platform": "windows"},   # no install record
    "epic:x": {"appid": 444, "exe": "/x.exe", "platform": "windows"},
}
records = {"gog:1207660413": {"path": str(unity), "platform": "windows"},
           "gog:1": {"path": str(plain), "platform": "windows"},
           "gog:2": {"path": str(upper), "platform": "windows"},
           "epic:x": {"path": str(upper), "platform": "windows"}}
built = galaxy.build(registry, records, uid)
key = str(-123456 & 0xFFFFFFFF)
check(sorted(built) == sorted([key, "222"]),
      f"every installed GOG Windows entry gets a row, keyed by UNSIGNED appid ({sorted(built)})")
check(built.get(key) == {"token": "gog:1207660413", "gid": "1207660413",
                         "clientId": "49843177965810898", "comet": True},
      f"a Galaxy game's row: token, gid, clientId, comet ({built.get(key)})")
check(built.get("222") == {"token": "gog:1", "gid": "1", "clientId": None, "comet": False},
      f"a game without the SDK is recorded with comet False ({built.get('222')})")

churned = {**registry, "gog:1207660413": {**registry["gog:1207660413"], "appid": 777}}
check("777" in galaxy.build(churned, records, uid) and key not in galaxy.build(churned, records, uid),
      "the row follows the registry's appid when the shortcut is re-created")

# ---------------------------------------------------------------------------------------------
print("== sync")
home = tmp / "store-home"
home.mkdir()
inst = home / "installs.json"
inst.write_text(json.dumps(records))
p = {"NOVADECK_STORE_HOME": str(home), "NOVADECK_STORE_UID": str(uid), "NOVADECK_STORE_USER": "deck",
     "NOVADECK_STORE_INSTALLS": str(inst)}
writes = []
def direct_write(pp, path, text):
    writes.append(path)
    pathlib.Path(path).write_text(text)
    return 0
galaxy.cli.write_as_user = direct_write
check(galaxy.sync(p, registry) is True, "sync reports the file current")
check(json.loads((home / galaxy.FILENAME).read_text()) == built, "sync writes the built table to galaxy.json")
n = len(writes)
galaxy.sync(p, registry)
check(len(writes) == n, "an unchanged table is not rewritten")
check(galaxy.read(p) == built, "read returns the table")
(home / galaxy.FILENAME).unlink()
check(galaxy.read(p) == {}, "no file → an empty table")

# ---------------------------------------------------------------------------------------------
print("== the registry writer regenerates it")
synced = []
real_sync = galaxy.sync
galaxy.sync = lambda pp, rows: synced.append(rows)
shortcuts.cli.write_as_user = direct_write
try:
    shortcuts.write_registry(p, registry)
finally:
    galaxy.sync = real_sync
check(synced == [registry], "write_registry calls galaxy.sync with the rows it wrote")
def boom(pp, rows):
    raise RuntimeError("broken")
galaxy.sync = boom
try:
    check(shortcuts.write_registry(p, registry) is True, "a failing galaxy.sync never fails the registry write")
finally:
    galaxy.sync = real_sync
PY
)"
rc=$?
printf '%s\n' "$out"
PASS=$(grep -c '^  ok ' <<<"$out" || true)
FAIL=$(grep -c '^  FAIL' <<<"$out" || true)
[ "$rc" -eq 0 ] || { echo "  FAIL the galaxy checks crashed (exit $rc) — every check after the crash never ran"; FAIL=$((FAIL + 1)); }

echo
echo "galaxy: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
