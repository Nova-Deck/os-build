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
# It also checks the copy of the dummy GalaxyCommunication service files into the store home
# (phase 2), which the first-run step that registers the service runs from.
#
# WHAT IT CANNOT PROVE: that Comet answers the game, or that Proton runs the staged .bat. Those
# are the phase 1 and phase 2 hardware gates.
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
                         "clientId": "49843177965810898", "comet": True, "install": str(unity)},
      f"a Galaxy game's row: token, gid, clientId, comet, install ({built.get(key)})")
check(built.get("222") == {"token": "gog:1", "gid": "1", "clientId": None, "comet": False,
                           "install": str(plain)},
      f"a game without the SDK is recorded with comet False ({built.get('222')})")

churned = {**registry, "gog:1207660413": {**registry["gog:1207660413"], "appid": 777}}
check("777" in galaxy.build(churned, records, uid) and key not in galaxy.build(churned, records, uid),
      "the row follows the registry's appid when the shortcut is re-created")

# ---------------------------------------------------------------------------------------------
print("== GOG's cloud-save config (remote-config), per clientId")
from novadeck_stores import cloud_config as cc
AW_CONFIG = {"content": {"Windows": {"cloudStorage": {"enabled": True, "locations": [
    {"name": "saves", "location": "<?DOCUMENTS?>/Another World"}]}}}}  # the real answer, HW 2026-11-18
check(cc.parse(AW_CONFIG, "4984") == {"supported": True, "locations": [
          {"name": "saves", "location": "<?DOCUMENTS?>/Another World"}]},
      "Another World's real config: supported, one location")
check(cc.parse({"content": {"Windows": {"cloudStorage": {"enabled": True, "locations": []}}}}, "4984")
      == {"supported": True, "locations": [{"name": "__default",
          "location": "%LocalAppData%/GOG.com/Galaxy/Applications/4984/Storage/Shared/Files"}]},
      "supported with no location: Heroic's __default under the client's Galaxy storage")
check(cc.parse({"content": {"Windows": {"cloudStorage": {"enabled": False, "locations": []}}}}, "4984")
      == {"supported": False, "locations": []}, "GOG says no cloud saves: unsupported")
check(cc.parse({"content": {"MacOS": {}}}, "4984") == {"supported": False, "locations": []},
      "no Windows section: unsupported")
check(cc.parse({"content": {"Windows": {"cloudStorage": {"enabled": True, "locations": [
          {"name": 5, "location": "x"}, {"name": "ok", "location": "<?INSTALL?>/s"}]}}}}, "4984")
      == {"supported": True, "locations": [{"name": "ok", "location": "<?INSTALL?>/s"}]},
      "a malformed location is dropped, the rest kept")
check(cc.parse("<html>", "4984") is None and cc.parse({"nope": 1}, "4984") is None,
      "an answer that is not GOG's shape is no answer (retried later), not 'unsupported'")

home = tmp / "store-home"
home.mkdir()
writes = []
def direct_write(pp, path, text):
    writes.append(path)
    pathlib.Path(path).write_text(text)
    return 0
galaxy.cli.write_as_user = direct_write
cc.cli.write_as_user = direct_write
pc = {"NOVADECK_STORE_HOME": str(home), "NOVADECK_STORE_UID": str(uid), "NOVADECK_STORE_USER": "deck"}
fetched = []
answers = {"4984": AW_CONFIG}
def fake_fetch(url):
    fetched.append(url)
    cid = url.split("/clients/")[1].split("?")[0]
    if cid not in answers:
        raise OSError("offline")
    return answers[cid]
now = [1795100000.0]
cfg = cc.configs(pc, ["4984"], fetch=fake_fetch, clock=lambda: now[0])
check(fetched == ["https://remote-config.gog.com/components/galaxy_client/clients/4984?component_version=2.0.45"],
      f"fetched from Heroic's endpoint ({fetched})")
check(cfg == {"4984": cc.parse(AW_CONFIG, "4984")}, "and returned parsed")
check(json.loads((home / cc.CACHE).read_text())["4984"]["fetched"] == now[0], "and cached, with its fetch time")
fetched.clear()
check(cc.configs(pc, ["4984"], fetch=fake_fetch, clock=lambda: now[0] + 3600) == cfg and not fetched,
      "a fresh cache entry is used without asking GOG again")
cfg = cc.configs(pc, ["777"], fetch=fake_fetch, clock=lambda: now[0])
check(cfg == {} and len(fetched) == 1, "a failed fetch (offline): no config, nothing cached")
check(cc.configs(pc, ["777"], fetch=fake_fetch, clock=lambda: now[0] + 60) == {} and len(fetched) == 1,
      "and it is not retried within RETRY_AFTER, so an offline library sync is not slowed per game")
cc.configs(pc, ["777"], fetch=fake_fetch, clock=lambda: now[0] + cc.RETRY_AFTER + 1)
check(len(fetched) == 2, "after RETRY_AFTER it is tried again")
fetched.clear()
answers.clear()
stale = now[0] + cc.MAX_AGE + 1
check(cc.configs(pc, ["4984"], fetch=fake_fetch, clock=lambda: stale) == {"4984": cc.parse(AW_CONFIG, "4984")}
      and len(fetched) == 1, "a stale entry is refetched, and kept when the refetch fails")
check(cc.configs(pc, ["../x", ""], fetch=fake_fetch, clock=lambda: stale) == {} and len(fetched) == 1,
      "a clientId that is not all digits never reaches a URL")

check(cc.toggles(pc) == {}, "no toggle file: every game on (the user's default, 2026-11-17)")
(home / cc.TOGGLES).write_text(json.dumps({"gog:1207660413": False, "gog:x": "no"}))
check(cc.toggles(pc) == {"gog:1207660413": False}, "a token switched off is off; a non-boolean is ignored")
(home / cc.TOGGLES).unlink()

rows = {key: dict(built[key]), "222": dict(built["222"])}
rows[key]["clientId"] = "4984"
with_cloud = galaxy.attach_cloud(rows, {"4984": cc.parse(AW_CONFIG, "4984")}, {})
check(with_cloud[key]["cloud"] == {"supported": True, "enabled": True, "locations": [
          {"name": "saves", "location": "<?DOCUMENTS?>/Another World"}]},
      f"a game GOG syncs: cloud supported and enabled, with its locations ({with_cloud[key].get('cloud')})")
check(with_cloud["222"]["cloud"] is None, "no clientId or no config yet: cloud None (step 4 skips it)")
off = galaxy.attach_cloud(rows, {"4984": cc.parse(AW_CONFIG, "4984")}, {"gog:1207660413": False})
check(off[key]["cloud"]["supported"] is True and off[key]["cloud"]["enabled"] is False,
      "switched off by the user: still supported, not enabled")
check("cloud" not in rows[key], "attach_cloud returns new rows; the built ones are untouched")

print("== sync")
inst = home / "installs.json"
inst.write_text(json.dumps(records))
p = {**pc, "NOVADECK_STORE_INSTALLS": str(inst)}
(unity / "goggame-1207660413.info").write_text(json.dumps({"clientId": "4984", "gameId": "1207660413"}))
answers["4984"] = AW_CONFIG
(home / cc.CACHE).unlink()
cc._failed.clear()  # the checks above left a failure stamped in the future of the real clock
galaxy.cloud_config.fetch_json = fake_fetch
built = galaxy.attach_cloud(galaxy.build(registry, records, uid),
                            {"4984": cc.parse(AW_CONFIG, "4984")}, {})
check(galaxy.sync(p, registry) is True, "sync reports the file current")
check(json.loads((home / galaxy.FILENAME).read_text()) == built,
      "sync writes the built table WITH each game's cloud config to galaxy.json")
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

# ---------------------------------------------------------------------------------------------
print("== the dummy service: staged into the store home (plan design §7)")
shipped = tmp / "shipped"
shipped.mkdir()
(shipped / "GalaxyCommunication.exe").write_bytes(b"MZ stub v1")
(shipped / "galaxy-service.bat").write_bytes(b"@echo off\r\n")
galaxy.SERVICE_FILES = {"GalaxyCommunication.exe": str(shipped / "GalaxyCommunication.exe"),
                        "galaxy-service.bat": str(shipped / "galaxy-service.bat")}
runs = []
run_rc = [0]
def fake_run(pp, argv, max_sec):
    runs.append(argv)
    if run_rc[0] == 0 and argv[:4] == ["install", "-D", "-m", "0644"]:
        pathlib.Path(argv[5]).parent.mkdir(parents=True, exist_ok=True)
        pathlib.Path(argv[5]).write_bytes(pathlib.Path(argv[4]).read_bytes())
    return run_rc[0]
galaxy.cli._run = fake_run
staged = home / "galaxy-service"
check(galaxy.stage_service(p) is True, "staging reports the copies current")
check((staged / "GalaxyCommunication.exe").read_bytes() == b"MZ stub v1"
      and (staged / "galaxy-service.bat").read_bytes() == b"@echo off\r\n",
      "both files land in <store home>/galaxy-service, byte for byte")
check(all(a[:4] == ["install", "-D", "-m", "0644"] for a in runs) and len(runs) == 2,
      f"each copy is one `install -D -m 0644`, run as the store user ({runs})")
runs.clear()
check(galaxy.stage_service(p) is True and not runs, "copies that match are not copied again")
(shipped / "GalaxyCommunication.exe").write_bytes(b"MZ stub v2")
check(galaxy.stage_service(p) is True and len(runs) == 1
      and (staged / "GalaxyCommunication.exe").read_bytes() == b"MZ stub v2",
      f"a shipped file that changed (an OTA) is copied again, and only that one ({runs})")
(shipped / "GalaxyCommunication.exe").write_bytes(b"MZ stub v3")
run_rc[0] = 1
check(galaxy.stage_service(p) is False, "a copy that fails is reported, so no step names it")
run_rc[0] = 0
(shipped / "GalaxyCommunication.exe").unlink()
check(galaxy.stage_service(p) is False, "a shipped file that is missing is reported")
step = galaxy.service_step(p)
check(step == {"argv": [str(staged / "galaxy-service.bat")], "cwd": str(staged)},
      f"the step runs the STAGED .bat from its own dir, which %~dp0 finds the stub in ({step})")
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
