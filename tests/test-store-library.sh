#!/usr/bin/env bash
# Offline checks for alien-games milestone 7 task 3 (.claude/plans/alien-games-panel.plan.md):
# library sync — every installable owned title becomes a not-installed tile, grouped in the
# [NovaDeck] collections.
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

reg = {"epic:A": {"appid": 1, "state": "shelf"}, "epic:B": {"appid": 2, "exe": "/g/b.exe"},
       "gog:C": {"appid": 3, "state": "shelf"}, "epic:junk": "x"}
ops = ls.collection_ops("epic", reg)
(ok if ops[0] == {"name": "[NovaDeck] Epic", "add": [1, 2], "remove": []} else bad)(
    f"the store collection holds every registered appid of the store ({ops[0]})")
(ok if ops[1] == {"name": "[NovaDeck] Not Installed", "add": [1], "remove": [2]} else bad)(
    f"Not Installed holds the store's shelf tiles and drops its installed entries ({ops[1]})")
(ok if 3 not in ops[0]["add"] + ops[1]["add"] + ops[1]["remove"] else bad)(
    "the other store's rows are left alone")
(ok if ls.collection_ops("gog", reg)[0]["name"] == "[NovaDeck] GOG" else bad)("GOG's collection is [NovaDeck] GOG")
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
async def fake_art(self, store, gid, appid):
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
cols = [pl for e, pl in emitted if e == "shortcut_op" and pl["op"] == "collection"]
(ok if [c["name"] for c in cols] == ["[NovaDeck] Epic", "[NovaDeck] Not Installed"] and len(cols[0]["add"]) == 2 else bad)(
    f"the collections are asserted after the adds ({[(c['name'], c['add']) for c in cols]})")
(ok if sorted(g for g, _ in art) == ["A", "B"] else bad)(f"new tiles get artwork in the background ({art})")

emitted.clear(); art.clear()
res = asyncio.run(run("epic"))
adds = [pl for e, pl in emitted if e == "shortcut_op" and pl["op"] == "add"]
(ok if res["added"] == 0 and not adds and not art else bad)(f"a re-sync adds nothing and fetches no art ({res})")
(ok if any(pl["op"] == "collection" for e, pl in emitted) else bad)("a re-sync still re-asserts the collections")

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

echo "== the bridge"
BRIDGE="$ROOT/apps/decky/novadeck-stores/src/lib/shortcutBridge.ts"
grep -q 'op: "collection"' "$BRIDGE" \
  && ok "the bridge executes collection ops" \
  || bad "shortcutBridge.ts has no collection op"
grep -q 'if (add.length === 0) return' "$BRIDGE" \
  && ok "the bridge never creates an empty collection just to remove from it" \
  || bad "the bridge may create an empty [NovaDeck] collection"

grep -q 'test-store-library.sh' "$ROOT/Makefile" \
  && ok "this suite is wired into make test (a suite nothing runs is documentation)" \
  || bad "tests/test-store-library.sh is not in the Makefile test target"

echo
echo "test-store-library.sh: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
