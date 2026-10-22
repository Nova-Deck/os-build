#!/usr/bin/env bash
# Offline checks for alien-games milestone 7 tasks 3-4 (.claude/plans/alien-games-panel.plan.md):
# library sync — every installable owned title becomes a not-installed tile, grouped in the
# [NovaDeck] collections — and the transition that turns a finished install into the model-B
# entry (and an uninstall back into a shelf tile).
#
#   tests/test-store-library.sh
#
# WHY THIS FILE EXISTS. A sync runs against a whole library and is re-run on every connect and
# every "sync" press, so the failures that matter are the repeated ones: a title added twice, a
# tile whose appid was never recorded (ours forever, untouchable), collections that only ever grow
# wrong. The decisions (library_sync.py) and the backend's sequencing are checked here with a fake
# bridge that answers like SteamUI.
#
# WHAT IT CANNOT PROVE: that collectionStore's AddApps/Save persist on the arm64 client, or how
# the library looks. Those are the milestone-7 hardware walkthrough.
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

echo "== sync decisions"
pysuite "decisions" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])

def ok(m): print(f"  ok   {m}")
def bad(m): print(f"  FAIL {m}")

from novadeck_stores import library_sync as ls

titles = [{"id": "Alba", "title": "ACS", "installable": True},
          {"id": "Origin1", "title": "EA game", "installable": False, "requires": "Origin"},
          {"id": "Ubi", "title": "Ubi game", "installable": True, "requires": "uplay"},
          {"id": "../x", "title": "bad id", "installable": True},
          {"id": "Done", "title": "Already", "installable": True},
          {"id": "NoTitle", "installable": True}]
registry = {"epic:Done": {"appid": 5, "title": "Already", "state": "shelf"}}
got = ls.to_shelve("epic", titles, registry)
(ok if [t["id"] for t in got] == ["Alba", "Ubi", "NoTitle"] else bad)(
    f"installable, well-formed, unregistered titles only — partner-linked included ({[t['id'] for t in got]})")
(ok if got[-1]["title"] == "NoTitle" else bad)("a title with no name falls back to its id, never an empty tile")
(ok if ls.to_shelve("epic", titles, {f"epic:{t['id']}": {} for t in got} | registry) == [] else bad)(
    "a second sync adds nothing — re-sync is idempotent")

(ok if not hasattr(ls, "collection_ops") else bad)("nothing builds collections — the library tabs list the games")
PY

echo "== the backend sync"
pysuite "backend" <<'PY'
import asyncio, json, os, pathlib, sys, tempfile, types
sys.path.insert(0, sys.argv[1])

def ok(m): print(f"  ok   {m}")
def bad(m): print(f"  FAIL {m}")

emitted = []
next_appid = iter(range(3000000000, 3000001000))
fail_names = set()
async def fake_emit(event, payload):
    emitted.append((event, payload))
    if event != "shortcut_op":
        return
    loop = asyncio.get_running_loop()
    if payload["op"] == "add":
        err = "Steam said no" if payload["name"] in fail_names else None
        loop.create_task(plugin.shortcut_result(payload["req"], None if err else next(next_appid), err))
    else:
        loop.create_task(plugin.shortcut_result(payload["req"], None, None))
sys.modules["decky"] = types.SimpleNamespace(
    logger=types.SimpleNamespace(info=lambda *a: None), emit=fake_emit)
sys.path.insert(0, os.path.join(sys.argv[1], ".."))
import main
from novadeck_stores import shortcuts

plugin = main.Plugin()
tmp = pathlib.Path(tempfile.mkdtemp(prefix="store-library."))
p = {"NOVADECK_STORE_HOME": str(tmp), "NOVADECK_STORE_UID": str(os.getuid()), "NOVADECK_STORE_USER": "deck"}
main.paths.store_paths = lambda ensure=False: p
writes = []
def direct_write(pp, path, text):
    writes.append(path); pathlib.Path(path).write_text(text); return 0
shortcuts.cli.write_as_user = direct_write
art = []
async def fake_art(self, store, gid, appid, reuse_from=None):
    art.append((gid, appid)); return {"applied": []}
main.Plugin.apply_artwork = fake_art
main.ARTWORK_PACE = 0

owned = {"titles": [{"id": "A", "title": "Alpha", "installable": True},
                    {"id": "B", "title": "Beta", "installable": True},
                    {"id": "X", "title": "EA", "installable": False}]}
main.library.owned = lambda store, pp: owned

async def run(store):
    res = await plugin.sync_library(store)
    await asyncio.sleep(0.05)  # the background artwork pass
    return res

res = asyncio.run(run("epic"))
reg = json.loads((tmp / "shortcuts.json").read_text())
(ok if res == {"added": 2, "tiles": 2} else bad)(f"two installable titles become two tiles ({res})")
(ok if all(r["state"] == "shelf" for r in reg.values()) and set(reg) == {"epic:A", "epic:B"} else bad)(
    f"each tile is a shelf row with the appid Steam returned ({reg})")
adds = [pl for e, pl in emitted if e == "shortcut_op" and pl["op"] == "add"]
(ok if all(a["exe"] == "/usr/lib/novadeck/store-launch" and a["options"] == f"epic:{a['name'][0]}" for a in adds) else bad)(
    f"tiles run the stub with their token ({[(a['exe'], a['options']) for a in adds]})")
(ok if len(writes) == 2 else bad)(f"the registry is written after EVERY add, not once at the end ({len(writes)} writes)")
(ok if [pl["op"] for e, pl in emitted if e == "shortcut_op"] == ["add", "add"] else bad)(
    f"a sync only adds tiles — no collection is written ({[pl['op'] for e, pl in emitted if e == 'shortcut_op']})")
(ok if sorted(g for g, _ in art) == ["A", "B"] else bad)(f"new tiles get artwork in the background ({art})")

emitted.clear(); art.clear()
res = asyncio.run(run("epic"))
adds = [pl for e, pl in emitted if e == "shortcut_op" and pl["op"] == "add"]
(ok if res["added"] == 0 and not adds and not art else bad)(f"a re-sync adds nothing and fetches no art ({res})")

emitted.clear()
owned["titles"].append({"id": "C", "title": "Gamma", "installable": True})
fail_names.add("Gamma")
res = asyncio.run(run("epic"))
reg = json.loads((tmp / "shortcuts.json").read_text())
(ok if res["added"] == 0 and "epic:C" not in reg else bad)(f"a refused add records nothing and the sync carries on ({res})")

main.library.owned = lambda store, pp: {"error": "cannot list the library (exit 1)"}
res = asyncio.run(run("epic"))
(ok if res == {"error": "cannot list the library (exit 1)"} else bad)(f"a library that cannot be listed is an error, never 'no games' ({res})")
(ok if asyncio.run(plugin.sync_library("steam")).get("error") else bad)("an unknown store is refused")
PY

echo "== the install transition"
pysuite "transition" <<'PY'
import asyncio, json, os, pathlib, sys, tempfile, types
sys.path.insert(0, sys.argv[1])

def ok(m): print(f"  ok   {m}")
def bad(m): print(f"  FAIL {m}")

emitted = []
next_appid = iter(range(4000000000, 4000001000))
refuse = set()   # ops the fake SteamUI refuses
async def fake_emit(event, payload):
    emitted.append((event, payload))
    if event != "shortcut_op":
        return
    err = "Steam said no" if payload["op"] in refuse else None
    appid = next(next_appid) if payload["op"] == "add" and not err else None
    asyncio.get_running_loop().create_task(plugin.shortcut_result(payload["req"], appid, err))
sys.modules["decky"] = types.SimpleNamespace(
    logger=types.SimpleNamespace(info=lambda *a: None), emit=fake_emit)
sys.path.insert(0, os.path.join(sys.argv[1], ".."))
import main
from novadeck_stores import shortcuts

plugin = main.Plugin()
tmp = pathlib.Path(tempfile.mkdtemp(prefix="store-library."))
p = {"NOVADECK_STORE_HOME": str(tmp), "NOVADECK_STORE_UID": str(os.getuid()), "NOVADECK_STORE_USER": "deck"}
main.paths.store_paths = lambda ensure=False: p
shortcuts.cli.write_as_user = lambda pp, path, text: (pathlib.Path(path).write_text(text), 0)[1]
art_calls = []
async def no_art(self, store, gid, appid, reuse_from=None):
    art_calls.append((gid, appid, reuse_from)); return {"applied": []}
main.Plugin.apply_artwork = no_art
reg_path = tmp / "shortcuts.json"
def reg(): return json.loads(reg_path.read_text())
def ops(): return [pl["op"] for e, pl in emitted if e == "shortcut_op"]
def events(): return [pl for e, pl in emitted if e == "install_event"]

records = {}
status_calls = []
main.installs.read_records = lambda pp: records
def fake_status(pp):
    status_calls.append(1)
    return {"installs": [{"store": k.split(":")[0], "id": k.split(":")[1], "state": v} for k, v in state.items()]}
state = {}
main.installs.install_status = fake_status
main.launch.resolve_target = lambda store, gid, pp, rec: {
    "exe": f"/g/{gid}/game.exe", "startdir": f"/g/{gid}", "platform": "windows"}

# Idle: a shelf tile with no install record costs no systemctl call.
reg_path.write_text(json.dumps({"epic:A": {"appid": 100, "title": "Alpha", "state": "shelf"}}))
asyncio.run(plugin.finish_installs(p))
(ok if not status_calls and not emitted else bad)("an idle poll (no tile installing) spawns nothing")

# Still downloading: nothing happens.
records["epic:A"] = {"store": "epic", "id": "A", "path": "/g/A"}
state["epic:A"] = "downloading"
asyncio.run(plugin.finish_installs(p))
(ok if not ops() else bad)(f"a tile still downloading is left alone ({ops()})")

# Done: the shelf tile is EDITED into the model-B entry, Proton set, then the collections. Same
# appid throughout — play time, art and an open page survive (HW 2026-10-22).
state["epic:A"] = "installed"
asyncio.run(plugin.finish_installs(p))
seq = ops()
(ok if seq == ["edit", "compat"] else bad)(
    f"edit the tile in place and set Proton — nothing added, removed or collected ({seq})")
edit = next(pl for e, pl in emitted if e == "shortcut_op" and pl["op"] == "edit")
(ok if edit["appid"] == 100 and edit["exe"] == '"/g/A/game.exe"'
    and edit["options"] == "/usr/lib/novadeck/game-launch %command%" else bad)(
    f"the edit turns appid 100 into the milestone-6 model-B entry, Exe quoted as AddShortcut stores it ({edit})")
compat = next(pl for e, pl in emitted if e == "shortcut_op" and pl["op"] == "compat")
(ok if compat["appid"] == 100 and compat["tool"] == "proton-cachyos-11.0-arm64" else bad)(
    f"Proton is set on the same appid ({compat})")
asyncio.run(asyncio.sleep(0))
(ok if not art_calls else bad)(f"no art pass: the appid kept its art ({art_calls})")
row = reg()["epic:A"]
(ok if row == {"title": "Alpha", "exe": "/g/A/game.exe", "platform": "windows", "appid": 100} else bad)(
    f"the row is now an installed entry with the SAME appid ({row})")
(ok if [e["message"] for e in events()] == ["Ready to play"] else bad)(f"the user is told it is ready ({events()})")

# Not shelf any more: a further poll does nothing.
emitted.clear()
asyncio.run(plugin.finish_installs(p))
(ok if not emitted else bad)("an installed entry is never transitioned twice")

# Appids retired by the remove + re-add swaps of earlier builds: still ours, kept across an edit,
# and removed by the next sync.
emitted.clear()
reg_path.write_text(json.dumps({"epic:B": {"appid": 210, "title": "Beta", "state": "shelf", "retired": [200]}}))
records["epic:B"] = {"store": "epic", "id": "B", "path": "/g/B"}; state["epic:B"] = "installed"
asyncio.run(plugin.finish_installs(p))
row = reg()["epic:B"]
(ok if row.get("retired") == [200] and row["appid"] == 210 else bad)(f"an edit keeps a legacy retired appid ({row})")
(ok if 200 in shortcuts.registry_appids(reg()) else bad)("a retired appid is still ours by registry membership")
emitted.clear()
main.library.owned = lambda store, pp: {"titles": []}
asyncio.run(plugin.sync_library("epic"))
removes = [pl["appid"] for e, pl in emitted if e == "shortcut_op" and pl["op"] == "remove"]
(ok if removes == [200] and "retired" not in reg()["epic:B"] else bad)(
    f"the next sync retries the retired removal and clears it once Steam confirms ({removes}, {reg()['epic:B']})")

# An edit Steam refuses: the shelf tile stays a shelf tile, the user is told ONCE across retries.
emitted.clear()
reg_path.write_text(json.dumps({"epic:C": {"appid": 300, "title": "Gamma", "state": "shelf"}}))
records["epic:C"] = {"store": "epic", "id": "C", "path": "/g/C"}; state["epic:C"] = "installed"
refuse.add("edit")
asyncio.run(plugin.finish_installs(p)); asyncio.run(plugin.finish_installs(p))
(ok if reg()["epic:C"]["appid"] == 300 and shortcuts.is_shelf(reg()["epic:C"]) else bad)(
    "a refused edit leaves the shelf row as it was")
(ok if len(events()) == 1 and not events()[0]["ok"] else bad)(f"the failure is told once, not every poll ({events()})")
(ok if not {"add", "remove", "compat"} & set(ops()) else bad)(f"nothing else is touched when the edit failed ({ops()})")
refuse.clear()

# Installed but the store names no executable: told once, no entry churn.
emitted.clear()
reg_path.write_text(json.dumps({"epic:D": {"appid": 400, "title": "Delta", "state": "shelf"}}))
records["epic:D"] = {"store": "epic", "id": "D", "path": "/g/D"}; state["epic:D"] = "installed"
main.launch.resolve_target = lambda *a: None
asyncio.run(plugin.finish_installs(p)); asyncio.run(plugin.finish_installs(p))
(ok if not ops() and len(events()) == 1 and "no executable" in events()[0]["message"] else bad)(
    f"an unresolvable install is told once and touches no entry ({ops()}, {events()})")

# Uninstall returns an installed entry to the shelf.
emitted.clear()
reg_path.write_text(json.dumps({"gog:E": {"appid": 500, "title": "Echo", "exe": "/g/E/e.exe", "platform": "windows"}}))
async def fake_action(self, action, store, fn, *args): return {"uninstalled": True}
main.Plugin._install_action = fake_action
res = asyncio.run(plugin.uninstall("gog", "E"))
row = reg()["gog:E"]
edit = next(pl for e, pl in emitted if e == "shortcut_op" and pl["op"] == "edit")
(ok if res == {"uninstalled": True} and shortcuts.is_shelf(row) and row["appid"] == 500
    and edit["appid"] == 500 and edit["exe"] == '"/usr/lib/novadeck/store-launch"' and edit["options"] == "gog:E" else bad)(
    f"an uninstalled game's entry is edited back into a stub tile, same appid ({res}, {row}, {edit})")
compat = [pl for e, pl in emitted if e == "shortcut_op" and pl["op"] == "compat"]
(ok if compat and compat[0]["appid"] == 500 and compat[0]["tool"] == "" and not {"add", "remove"} & set(ops()) else bad)(
    f"Proton is CLEARED off the stub tile (tool ''), nothing added or removed ({compat}, {ops()})")

# Proton that will not come off is an error: the stub must never run through it.
emitted.clear()
reg_path.write_text(json.dumps({"gog:E2": {"appid": 550, "title": "Echo2", "exe": "/g/E2/e.exe", "platform": "windows"}}))
refuse.add("compat")
res = asyncio.run(plugin.uninstall("gog", "E2"))
refuse.clear()
(ok if "warning" in res and reg()["gog:E2"].get("state") == "pending_shelf" else bad)(
    f"a compat tool that would not clear leaves the row pending_shelf, retried by the next sync ({res}, {reg()['gog:E2']})")

# Review fixes (2026-10-21).
# A registry that cannot be written after an edit: the row still says shelf, the user is told,
# and the next pass edits again (idempotent) — nothing is added or removed to "undo" it.
emitted.clear()
reg_path.write_text(json.dumps({"epic:F": {"appid": 600, "title": "Fox", "state": "shelf"}}))
records["epic:F"] = {"store": "epic", "id": "F", "path": "/g/F"}; state["epic:F"] = "installed"
main.launch.resolve_target = lambda store, gid, pp, rec: {"exe": f"/g/{gid}/g.exe", "startdir": f"/g/{gid}", "platform": "windows"}
real_write = shortcuts.cli.write_as_user
shortcuts.cli.write_as_user = lambda pp, path, text: 1
asyncio.run(plugin.finish_installs(p))
shortcuts.cli.write_as_user = real_write
(ok if shortcuts.is_shelf(reg()["epic:F"]) and reg()["epic:F"]["appid"] == 600
    and not {"add", "remove"} & set(ops()) and events() and not events()[0]["ok"] else bad)(
    f"an unrecordable edit leaves the shelf row, says so, and touches no other entry ({ops()}, {events()})")
emitted.clear()
asyncio.run(plugin.finish_installs(p))
(ok if reg()["epic:F"]["appid"] == 600 and not shortcuts.is_shelf(reg()["epic:F"]) else bad)(
    f"the next pass edits again and records it ({reg()['epic:F']})")

# The state is re-checked under the lock: an uninstall that landed while finish waited wins.
emitted.clear()
reg_path.write_text(json.dumps({"epic:G": {"appid": 700, "title": "Golf", "state": "shelf"}}))
records.clear(); records["epic:G"] = {"store": "epic", "id": "G", "path": "/g/G"}; state.clear(); state["epic:G"] = "installed"
real_resolve = main.launch.resolve_target
def resolve_then_uninstall(store, gid, pp, rec):
    records.clear()  # the uninstall deletes the record while finish is between snapshot and lock
    return real_resolve(store, gid, pp, rec)
main.launch.resolve_target = resolve_then_uninstall
asyncio.run(plugin.finish_installs(p))
main.launch.resolve_target = real_resolve
(ok if not ops() and shortcuts.is_shelf(reg()["epic:G"]) else bad)(
    f"a game uninstalled while finish waited is not resurrected ({ops()})")

# A failed swap back to the shelf after an uninstall is marked and retried by the next sync.
emitted.clear()
reg_path.write_text(json.dumps({"gog:H": {"appid": 800, "title": "Hotel", "exe": "/g/H/h.exe", "platform": "windows"}}))
refuse.add("edit")
res = asyncio.run(plugin.uninstall("gog", "H"))
refuse.clear()
(ok if "warning" in res and reg()["gog:H"].get("state") == "pending_shelf" else bad)(
    f"a failed edit back leaves the row pending_shelf, not 'installed' ({res}, {reg()['gog:H']})")
main.library.owned = lambda store, pp: {"titles": []}
asyncio.run(plugin.sync_library("gog"))
(ok if shortcuts.is_shelf(reg()["gog:H"]) and reg()["gog:H"]["appid"] == 800 else bad)(
    f"the next sync finishes the edit back to the shelf, same appid ({reg()['gog:H']})")

# A SteamUI that does not answer ends the sync at the first timeout instead of N x 30 s.
emitted.clear()
async def no_answer(self, payload): return {"error": main.NO_ANSWER}
real_rt = main.Plugin._shortcut_roundtrip
main.Plugin._shortcut_roundtrip = no_answer
main.library.owned = lambda store, pp: {"titles": [{"id": f"N{i}", "title": f"N{i}", "installable": True} for i in range(5)]}
calls = []
async def counting(self, payload):
    calls.append(payload["op"]); return {"error": main.NO_ANSWER}
main.Plugin._shortcut_roundtrip = counting
res = asyncio.run(plugin.sync_library("epic"))
main.Plugin._shortcut_roundtrip = real_rt
(ok if res == {"error": main.NO_ANSWER} and calls == ["add"] else bad)(
    f"the sync stops at the first unanswered op ({res}, {calls})")

# Boot re-assert never puts Proton on a shelf tile.
emitted.clear()
asyncio.run(plugin.reassert_compat(p)); asyncio.run(asyncio.sleep(0))
(ok if "compat" not in ops() else bad)("reassert_compat skips shelf tiles — the stub never runs through Proton")
PY

echo "== the slim panel's backend"
pysuite "panel" <<'PY'
import asyncio, json, os, pathlib, sys, tempfile, types
sys.path.insert(0, sys.argv[1])

def ok(m): print(f"  ok   {m}")
def bad(m): print(f"  FAIL {m}")

async def fake_emit(*a): pass
sys.modules["decky"] = types.SimpleNamespace(logger=types.SimpleNamespace(info=lambda *a: None), emit=fake_emit)
sys.path.insert(0, os.path.join(sys.argv[1], ".."))
import main
from novadeck_stores import settings

tmp = pathlib.Path(tempfile.mkdtemp(prefix="store-library."))
p = {"NOVADECK_STORE_HOME": str(tmp), "NOVADECK_STORE_UID": str(os.getuid()), "NOVADECK_STORE_USER": "deck"}
main.paths.store_paths = lambda ensure=False: p
settings.cli.write_as_user = lambda pp, path, text: (pathlib.Path(path).write_text(text), 0)[1]
(tmp / "shortcuts.json").write_text(json.dumps({"epic:A": {"appid": 1, "title": "A", "state": "shelf"},
                                                "gog:B": {"appid": 2, "title": "B", "exe": "/g/b"}}))
main.installs.install_status = lambda pp: {"installs": [
    {"store": "epic", "id": "A", "title": "A", "state": "downloading", "percent": 12.5},
    {"store": "gog", "id": "B", "title": "B", "state": "installed"},
    {"store": "gog", "id": "Z", "title": "Z", "state": "interrupted"}]}
vols = [{"path": "/home/deck", "label": "Internal", "free": 1}, {"path": "/run/media/deck/SD", "label": "SD", "free": 2}]
main.locations.user_volumes = lambda user: vols

s = asyncio.run(main.Plugin().library_state())
(ok if [i["tile"] for i in s["installs"]] == ["shelf", "installed", None] else bad)(
    f"each activity row says what its tile is ({[i['tile'] for i in s['installs']]})")
(ok if s["install_drive"] == "/home/deck" and len(s["drives"]) == 2 else bad)(
    f"with no preference the install drive reads as Internal ({s['install_drive']})")
r = asyncio.run(main.Plugin().set_install_drive("/run/media/deck/GONE"))
(ok if "error" in r and not (tmp / "settings.json").exists() else bad)(f"an unmounted drive is refused, nothing saved ({r})")
r = asyncio.run(main.Plugin().set_install_drive("/run/media/deck/SD"))
s = asyncio.run(main.Plugin().library_state())
(ok if r == {"install_drive": "/run/media/deck/SD"} and s["install_drive"] == "/run/media/deck/SD" else bad)(
    f"a mounted drive is saved and read back ({r}, {s['install_drive']})")
vols.pop()
s = asyncio.run(main.Plugin().library_state())
(ok if s["install_drive"] == "/home/deck" else bad)("a preferred card that is gone reads as Internal, not as a dead choice")
(tmp / "settings.json").write_text("not json")
(ok if settings.install_drive(p) is None else bad)("an unreadable settings file is no preference, never an error")
PY

echo "== the library tabs (revision 2, R2)"
pysuite "tabs" <<'PY'
import asyncio, json, os, pathlib, sys, tempfile, types
sys.path.insert(0, sys.argv[1])

def ok(m): print(f"  ok   {m}")
def bad(m): print(f"  FAIL {m}")

from novadeck_stores import library_sync as ls

reg = {"epic:A": {"appid": 3000000000, "state": "shelf"},
       "epic:B": {"appid": -1294967295, "exe": "/g/b.exe", "retired": [3000000009]},
       "gog:C": {"appid": 3000000002, "state": "pending_shelf"},
       "gog:D": {"title": "no appid yet"},
       "../x": {"appid": 3000000004},
       "epic:junk": "not a row"}
m = ls.tab_members(reg)
(ok if sorted(m["epic"]) == [3000000000, 3000000001] else bad)(
    f"a store's tab lists its entries, installed or not, by unsigned live appid ({m['epic']})")
(ok if 3000000009 not in m["epic"] else bad)("a retired appid is not in a tab — that entry is on its way out")
(ok if m["gog"] == [3000000002] else bad)(f"a row with no appid and a malformed token are left out ({m['gog']})")
(ok if m["installed"] == [3000000001] else bad)(
    f"Steam's Installed tab gains only the installed games — not shelf tiles, not a pending_shelf whose files are gone ({m['installed']})")
(ok if ls.tab_members({}) == {"epic": [], "gog": [], "installed": []} else bad)(
    "an empty registry is empty tabs, never a missing key")

async def fake_emit(*a): pass
sys.modules["decky"] = types.SimpleNamespace(logger=types.SimpleNamespace(info=lambda *a: None), emit=fake_emit)
sys.path.insert(0, os.path.join(sys.argv[1], ".."))
import main
tmp = pathlib.Path(tempfile.mkdtemp(prefix="store-tabs."))
p = {"NOVADECK_STORE_HOME": str(tmp), "NOVADECK_STORE_UID": str(os.getuid()), "NOVADECK_STORE_USER": "deck"}
main.paths.store_paths = lambda ensure=False: p
(tmp / "shortcuts.json").write_text(json.dumps({"epic:A": {"appid": 7, "state": "shelf"}}))
r = asyncio.run(main.Plugin().library_tabs())
(ok if r == {"epic": [7], "gog": [], "installed": []} else bad)(f"library_tabs serves the registry's members ({r})")
def broken(ensure=False): raise OSError("gone")
main.paths.store_paths = broken
r = asyncio.run(main.Plugin().library_tabs())
(ok if "error" in r else bad)(f"an unreadable registry is an error, never two empty tabs ({r})")
PY

SRC="$ROOT/apps/decky/novadeck-stores/src"
TABS="$SRC/LibraryTabs.tsx"
grep -q 'call<\[\], Members | { error: string }>("library_tabs")' "$TABS" \
  && ! grep -q 'type-games' "$TABS" \
  && ok "tab membership is the backend's registry, never a filter over Steam's games collection" \
  || bad "LibraryTabs.tsx does not take its members from library_tabs alone"
grep -A1 'addPatch("/library"' "$TABS" | grep -q 'isTabMasterInstalled()' \
  && ok "with TabMaster installed the tab list is left to it" \
  || bad "LibraryTabs.tsx patches the tab list even when TabMaster owns it"
grep -q 'const removeLibraryTabsPatch = applyLibraryTabsPatch()' "$SRC/index.tsx" \
  && grep -A14 'onDismount()' "$SRC/index.tsx" | grep -q 'removeLibraryTabsPatch()' \
  && ok "the tabs patch is applied at load and removed at dismount" \
  || bad "index.tsx does not apply AND remove the library tabs patch"
grep -q 'executeShortcutOp(op).then(scheduleLibraryTabsRefresh)' "$SRC/index.tsx" \
  && ok "the tabs re-read their members after every library-entry operation" \
  || bad "the tabs are never refreshed after an add, remove or swap"

echo "== the panel"
grep -q '<LibrarySections' "$SRC/Content.tsx" \
  && ok "the panel mounts the library + activity sections" \
  || bad "Content.tsx does not mount LibrarySections"
! grep -qE "call<[^>]*>\(\s*[\"']owned[\"']" "$SRC"/*.ts "$SRC"/*.tsx \
  && ok "the panel never lists owned games — it is not a browser (the library is)" \
  || bad "the panel calls 'owned': milestone 7 keeps game browsing in the Steam library"

echo "== the bridge"
BRIDGE="$ROOT/apps/decky/novadeck-stores/src/lib/shortcutBridge.ts"
! grep -q 'collectionStore' "$BRIDGE" \
  && ok "the bridge never touches Steam's collections" \
  || bad "shortcutBridge.ts still uses collectionStore"

grep -q 'test-store-library.sh' "$ROOT/Makefile" \
  && ok "this suite is wired into make test (a suite nothing runs is documentation)" \
  || bad "tests/test-store-library.sh is not in the Makefile test target"

echo
echo "test-store-library.sh: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
