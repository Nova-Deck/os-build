#!/usr/bin/env bash
# Offline checks for the plugin's half of the cloud-save conflict question
# (.claude/plans/gog-galaxy-comet.plan.md, phase 3 step 6).
#
#   tests/test-store-savepick.sh
#
# WHY THIS FILE EXISTS. When a GOG game's saves changed both here and in the cloud since the last
# sync, game-launch (novadeck_savesync.ask) leaves `<appid>.<index>.<local>.<cloud>.savepick` in
# the request spool and waits. The plugin must take it, name the game and the location from its
# OWN files (root never reads the user's request file), show "Which saves?" with both dates, and
# write `<appid>.<index>.saveanswer` back. A wrong answer here overwrites a save; a question never
# taken costs the launch TAKE_TIMEOUT and syncs nothing.
#
# WHAT IT CANNOT PROVE: that the modal shows on the device and B answers it. That is the phase 3
# HW gate. The launch's half is tests/test-store-savesync.sh.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STORES_PY="$ROOT/apps/decky/novadeck-stores/py_modules"

out="$(python3 - "$STORES_PY" <<'PY'
import asyncio, json, os, pathlib, sys, tempfile, types
sys.path.insert(0, sys.argv[1])

def ok(m): print(f"  ok   {m}")
def bad(m): print(f"  FAIL {m}")
def check(cond, m): (ok if cond else bad)(m)

emitted = []
async def fake_emit(event, payload):
    emitted.append((event, payload))
sys.modules["decky"] = types.SimpleNamespace(logger=types.SimpleNamespace(info=lambda *a: None), emit=fake_emit)
sys.path.insert(0, os.path.join(sys.argv[1], ".."))
import main
from novadeck_stores import galaxy, install_requests, save_picks

tmp = pathlib.Path(tempfile.mkdtemp(prefix="save-pick."))
p = {"NOVADECK_STORE_HOME": str(tmp), "NOVADECK_STORE_UID": str(os.getuid()), "NOVADECK_STORE_USER": "deck"}
main.paths.store_paths = lambda ensure=False: p
def direct_write(pp, path, text):
    pathlib.Path(path).write_text(text); return 0
save_picks.cli.write_as_user = direct_write
spool = tmp / "requests"
spool.mkdir()
APPID = 2588025602  # Another World on the Pocket Max (HW 2026-11-18)
(tmp / galaxy.FILENAME).write_text(json.dumps({str(APPID): {
    "token": "gog:1207658845", "gid": "1207658845", "clientId": "49843177965810898", "comet": True,
    "install": "/g/aw", "cloud": {"supported": True, "enabled": True, "locations": [
        {"name": "saves", "location": "<?DOCUMENTS?>/Another World"}]}}}))
(tmp / "shortcuts.json").write_text(json.dumps({
    "gog:1207658845": {"appid": APPID - (1 << 32), "title": "Another World: 20th Anniversary Edition"}}))

print("== the request grammar")
good = f"{APPID}.0.1795040000.1795050000"
check(install_requests.SAVE_PICK.fullmatch(good) is not None, "appid.index.local.cloud, digits only, is a question")
for name in (f"{APPID}.0.1795040000", f"{APPID}.x.1.2", "gog:1.0.1.2", f"{APPID}.0.1.2.3", f"../{APPID}.0.1.2"):
    check(install_requests.SAVE_PICK.fullmatch(name) is None, f"{name!r} is not")
check(save_picks.parse(good) == (str(APPID), 0, 1795040000, 1795050000), "parse splits it into its numbers")

print("== taking a question")
(spool / f"{good}.savepick").write_text("")
(spool / "77.dospick").write_text("")
(spool / "../evil.0.1.2.savepick".replace("../", "")).write_text("")
plugin = main.Plugin()
asyncio.run(plugin.take_save_picks(p))
picks = [pl for ev, pl in emitted if ev == "save_pick"]
check(picks == [{"appid": APPID, "index": 0, "title": "Another World: 20th Anniversary Edition",
                 "location": "saves", "localTime": 1795040000, "cloudTime": 1795050000, "store": "gog"}],
      f"emitted with the title from the registry, the location's NAME from galaxy.json, both dates, "
      f"and the store, whose cloud the dialog names ({picks})")
check(not (spool / f"{good}.savepick").exists(), "taking it unlinks it: the launch's signal that it was seen")
check((spool / "77.dospick").exists(), "a DOSBox question is left for the DOS picker")
check(not (spool / "evil.0.1.2.savepick").exists() and len(picks) == 1,
      "a name outside the grammar is dropped, unread and unasked")
emitted.clear()
(spool / f"{APPID}.5.1.2.savepick").write_text("")
(spool / "999.0.1.2.savepick").write_text("")
asyncio.run(plugin.take_save_picks(p))
check(not [e for e in emitted if e[0] == "save_pick"] and not list(spool.glob("*.saveanswer")),
      "an index the game has no location for, or an appid with no row: not asked, not answered "
      "(the launch times out and keeps local)")

print("== an Epic game's question (epic-cloud.json; epic cloud saves plan step 6)")
from novadeck_stores import epic_cloud
DOOM = 2607617071
(tmp / epic_cloud.FILENAME).write_text(json.dumps({str(DOOM): {
    "token": "epic:5b60142e", "gid": "5b60142e", "install": "/g/doom64", "cloud": {
        "supported": True, "enabled": True, "location": "{UserSavedGames}/Nightdive Studios/DOOM 64/saves/",
        "include": None, "exclude": None}}}))
(tmp / "shortcuts.json").write_text(json.dumps({
    "gog:1207658845": {"appid": APPID - (1 << 32), "title": "Another World: 20th Anniversary Edition"},
    "epic:5b60142e": {"appid": DOOM - (1 << 32), "title": "DOOM 64"}}))
emitted.clear()
(spool / f"{DOOM}.0.1795040000.1795050000.savepick").write_text("")
(spool / f"{DOOM}.1.1.2.savepick").write_text("")
asyncio.run(plugin.take_save_picks(p))
picks = [pl for ev, pl in emitted if ev == "save_pick"]
check(picks == [{"appid": DOOM, "index": 0, "title": "DOOM 64", "location": "saves",
                 "localTime": 1795040000, "cloudTime": 1795050000, "store": "epic"}],
      f"an Epic game's one folder is location 0, named 'saves', and the store is epic ({picks})")

print("== answering it")
for choice, text in (("cloud", "cloud"), ("local", "local"), (None, "")):
    r = asyncio.run(plugin.save_pick_answer(APPID, 0, choice))
    check(r == {"ok": True} and (spool / f"{APPID}.0.saveanswer").read_text() == text,
          f"{choice!r} reaches the launch as {text!r} ({r})")
r = asyncio.run(plugin.save_pick_answer(APPID, 0, "both"))
check("error" in r, f"anything but cloud / local / None is refused ({r})")
r = asyncio.run(plugin.save_pick_answer(APPID, -1, "cloud"))
check("error" in r, f"a negative index is refused ({r})")
check(save_picks.answer(p, "1/../x", 0, "cloud") is False, "an appid that is not digits never names a file")
r = asyncio.run(plugin.save_pick_answer(APPID - (1 << 32), 0, "local"))
check(r == {"ok": True} and (spool / f"{APPID}.0.saveanswer").read_text() == "local",
      "a signed appid from the frontend answers under the unsigned one the launch waits on")

print("== wiring")
src = (pathlib.Path(sys.argv[1]).parent / "main.py").read_text()
loop = src[src.index("async def _request_loop"):]
check("take_save_picks(p)" in loop[:3000], "the request loop takes save questions on every beat")
check(loop.index("take_save_picks(p)") < loop.index("take_install_requests(p)"),
      "...BEFORE install requests, which can wait on the shortcut lock past the launch's 10 s")
fe = pathlib.Path(sys.argv[1]).parent / "src"
index, backend_ts, dialog = ((fe / n).read_text() for n in ("index.tsx", "backend.ts", "SavePickDialog.tsx"))
check('addEventListener("save_pick", onSavePick)' in index and 'removeEventListener("save_pick", onSavePick)' in index,
      "index.tsx listens for save_pick, and stops on dismount")
check('"save_pick_answer"' in backend_ts and "async def save_pick_answer(" in src,
      "backend.ts calls save_pick_answer, which main.py defines")
check("onCancel={() => send(null)}" in dialog, "B answers null: keep local, sync nothing")
for want in ('send("cloud")', 'send("local")', "send(null)}>"):
    check(want in dialog, f"the dialog offers {want}")
check("answered.current" in dialog, "one answer per question: closing after a pick sends no second answer")
check("localTime" in dialog and "cloudTime" in dialog, "both dates are shown")
check("GOG cloud" not in dialog and "STORE_LABELS[store]" in dialog,
      "the dialog names the game's own store's cloud, not always GOG's")
PY
)"
rc=$?
printf '%s\n' "$out"
PASS=$(grep -c '^  ok ' <<<"$out" || true)
FAIL=$(grep -c '^  FAIL' <<<"$out" || true)
[ "$rc" -eq 0 ] || { echo "  FAIL the save-pick checks crashed (exit $rc) — every check after the crash never ran"; FAIL=$((FAIL + 1)); }

echo
echo "savepick: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
