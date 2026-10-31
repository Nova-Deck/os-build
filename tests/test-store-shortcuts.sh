#!/usr/bin/env bash
# Offline checks for alien-games milestone 4 (library entry writer), AMENDED by milestone 6
# (.claude/plans/alien-games-launch.plan.md: the installed entry's Exe is the game binary) and
# milestone 7 (.claude/plans/alien-games-panel.plan.md: ownership is registry membership, since
# not-installed stub tiles and installed games are both ours).
#
#   tests/test-store-shortcuts.sh
#
# WHY THIS FILE EXISTS. The expensive failures are destructive ones against Steam's state:
# deleting an entry that is not ours. Checkable offline: the exact entry fields (game Exe,
# game-launch %command% options), the registry-membership ownership rule, the registry, and the
# appid-join report. Fixture bytes stand in for shortcuts.vdf.
#
# WHAT IT CANNOT PROVE: AddShortcut/SpecifyCompatTool behaviour on the real client, or that an
# entry survives a restart. Those are the hardware gate.
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

echo "== entry template, ownership, registry, verification"
pysuite "shortcuts-module" <<'PY'
import json, os, pathlib, sys, tempfile
sys.path.insert(0, sys.argv[1])

def ok(m): print(f"  ok   {m}")
def bad(m): print(f"  FAIL {m}")

from novadeck_stores import launch, shortcuts

tmp = pathlib.Path(tempfile.mkdtemp(prefix="store-shortcuts."))
epic_exe = str(tmp / "Games" / "Epic" / "Breathedge" / "Breathedge.exe")
resolved = {"exe": epic_exe, "startdir": str(tmp / "Games" / "Epic" / "Breathedge"), "platform": "windows"}

# -- the entry template: Exe is the GAME, options are game-launch %command%, no token in options --
e = shortcuts.entry_fields("epic", "Breathedge", "Breathedge", resolved)
(ok if e["Exe"] == f'"{epic_exe}"' else bad)(f"Exe is the quoted GAME binary, not a stub ({e['Exe']})")
(ok if e["LaunchOptions"] == "/usr/lib/novadeck/game-launch %command%" else bad)(
    f"LaunchOptions is game-launch %command% — tuning by the Steam-game door ({e['LaunchOptions']})")
e_pfx = shortcuts.entry_fields("epic", "Catnip", "Borderlands 3",
                               {**resolved, "env": "STORE=egs UMU_ID=umu-397540"})
(ok if e_pfx["LaunchOptions"] == "STORE=egs UMU_ID=umu-397540 /usr/lib/novadeck/game-launch %command%" else bad)(
    f"protonfixes ids prefix the options, ahead of game-launch so Proton inherits them ({e_pfx['LaunchOptions']})")
(ok if "/usr/lib/novadeck/game-launch" in e_pfx["LaunchOptions"] else bad)(
    "and the options still contain the wrapper, so novadeck-control's wrapLaunchOptions leaves them alone")
(ok if "Breathedge" in e["StartDir"] else bad)("StartDir is the quoted install dir")
(ok if e["AppName"] == "Breathedge" else bad)("AppName is the store title")
for store, gid in (("steam", "x"), ("epic", ""), ("epic", "a/b"), ("epic", "..")):
    try:
        shortcuts.entry_fields(store, gid, "t", resolved)
        bad(f"entry_fields({store!r}, {gid!r}) must refuse an unsafe id")
        break
    except ValueError:
        pass
else:
    ok("entry_fields refuses an unsafe store/id before it can become a registry key or path")
try:
    shortcuts.entry_fields("epic", "ok", "t", {"exe": "", "platform": "windows"})
    bad("entry_fields must refuse a resolved target with no exe")
except ValueError:
    ok("entry_fields refuses a target that resolved no executable")

# -- ownership (milestone 7): the entry's appid is in our registry, nothing else --
vols = [{"path": str(tmp), "label": "Internal", "free": 1}]
roots = launch.managed_roots({"NOVADECK_STORE_USER": "x"}, vols=vols)
claimed = shortcuts.registry_appids({"epic:Breathedge": {"appid": 2981617462},
                                     "gog:shelf": {"appid": -2000000000},  # recorded in signed form
                                     "junk": "not a row", "noappid": {"title": "x"}})
(ok if shortcuts.is_ours({"appid": 2981617462, "Exe": '"/usr/lib/novadeck/store-launch"'}, claimed) else bad)(
    "a registered appid is ours whatever its Exe — a not-installed stub tile included")
(ok if shortcuts.is_ours({"appid": 2294967296}, claimed) else bad)(
    "a signed registry appid and the unsigned file form name the same entry")
(ok if not shortcuts.is_ours({"appid": 999, "Exe": f'"{epic_exe}"'}, claimed) else bad)(
    "an entry under OUR game root but not in the registry is NOT ours — the path is no longer ownership")
(ok if not shortcuts.is_ours({"appid": 777, "Exe": '"/usr/bin/retroarch"', "LaunchOptions": "epic:Breathedge",
                              "tags": {"0": "novadeck"}}, claimed) else bad)(
    "a FOREIGN entry carrying our token and tag is NOT ours")
(ok if not shortcuts.is_ours({"Exe": f'"{epic_exe}"'}, claimed) and not shortcuts.is_ours({"appid": True}, {1}) else bad)(
    "an entry with no (integer) appid is never ours")

# -- registry round-trips through write_as_user --
reg = tmp / "shortcuts.json"
p = {"NOVADECK_STORE_HOME": str(tmp), "NOVADECK_STORE_UID": str(os.getuid()), "NOVADECK_STORE_USER": "deck"}
(ok if shortcuts.registry_path(p) == str(reg) else bad)("the registry lives in the store home")
def fake_write(pp, path, text):
    pathlib.Path(path).write_text(text); return 0
shortcuts.cli.write_as_user = fake_write
shortcuts.write_registry(p, {"epic:Breathedge": {"appid": 2981617462, "title": "Breathedge",
                                                  "exe": epic_exe, "platform": "windows"}})
(ok if shortcuts.read_registry(p)["epic:Breathedge"]["appid"] == 2981617462 else bad)(
    "the registry round-trips with appid/exe/platform")

# -- compat payload: carries the appid + tool, unsigned conversion is the bridge's job --
cp = shortcuts.compat_payload(7, 2981617462, "proton-cachyos-11.0-arm64")
(ok if cp == {"op": "compat", "req": 7, "appid": 2981617462, "tool": "proton-cachyos-11.0-arm64"} else bad)(
    f"compat_payload names the appid and tool ({cp})")

# -- verification reader joins the file to the registry BY APPID --
def bvdf(obj):
    out = bytearray()
    for k, v in obj.items():
        if isinstance(v, dict):
            out += b"\x00" + k.encode() + b"\x00" + bvdf(v)
        elif isinstance(v, int):
            out += b"\x02" + k.encode() + b"\x00" + v.to_bytes(4, "little", signed=v < 0)
        else:
            out += b"\x01" + k.encode() + b"\x00" + str(v).encode() + b"\x00"
    return bytes(out + b"\x08")

gog_exe = str(tmp / "Games" / "GOG" / "W" / "w.exe")
fixture = bvdf({"shortcuts": {
    "0": {"appid": 2981617462, "AppName": "Breathedge", "Exe": f'"{epic_exe}"',
          "LaunchOptions": "/usr/lib/novadeck/game-launch %command%"},
    "1": {"appid": 555, "AppName": "Owned but unregistered", "Exe": f'"{gog_exe}"', "LaunchOptions": ""},
    "2": {"appid": 999, "AppName": "Foreign", "Exe": '"/usr/bin/retroarch"', "LaunchOptions": "epic:Breathedge"},
    "3": {"appid": 1234567, "AppName": "Shelf tile", "Exe": '"/usr/lib/novadeck/store-launch"',
          "LaunchOptions": "gog:shelf"},
}})
registry = {"epic:Breathedge": {"appid": 2981617462}, "gog:shelf": {"appid": 1234567},
            "gog:gone": {"appid": 42424242}}
entries = shortcuts.our_entries(fixture, registry)
(ok if sorted(x["appid"] for x in entries) == [1234567, 2981617462] else bad)(
    f"our_entries finds exactly the registered two — the installed game AND the stub tile ({[x['appid'] for x in entries]})")
rep = shortcuts.orphan_report(fixture, registry, roots)
(ok if sorted(x["token"] for x in rep["healthy"]) == ["epic:Breathedge", "gog:shelf"] else bad)(
    f"every entry whose appid is in the registry is healthy, whatever its Exe ({rep['healthy']})")
(ok if [x["appid"] for x in rep["orphan_unregistered"]] == [555] else bad)(
    f"under a managed root but not in the registry = orphan_unregistered; the foreign one is not ({rep['orphan_unregistered']})")
(ok if [x["token"] for x in rep["registry_without_entry"]] == ["gog:gone"] else bad)(
    "a registry row whose appid has no entry is reported — the foreign entry's token is NOT matched")
try:
    shortcuts.our_entries(fixture[:-5], registry)
    bad("truncated vdf bytes must raise, never read as empty")
except ValueError:
    ok("truncated vdf bytes raise — unreadable is never 'no entries'")
PY

echo "== the backend contract"
pysuite "backend" <<'PY'
import asyncio, inspect, json, os, pathlib, sys, tempfile, types
sys.path.insert(0, sys.argv[1])

def ok(m): print(f"  ok   {m}")
def bad(m): print(f"  FAIL {m}")

emitted = []
async def fake_emit(event, payload):
    emitted.append((event, payload))
    if event == "shortcut_op":
        appid = 2981617462 if payload["op"] == "add" else None
        asyncio.get_running_loop().create_task(plugin.shortcut_result(payload["req"], appid, None))

sys.modules["decky"] = types.SimpleNamespace(
    logger=types.SimpleNamespace(info=lambda *a: None), emit=fake_emit)
sys.path.insert(0, os.path.join(sys.argv[1], ".."))
import main
from novadeck_stores import shortcuts

methods = ["register_entry", "deregister_entry", "entry_status", "shortcut_result", "reassert_compat"]
missing = [m for m in methods if not inspect.iscoroutinefunction(getattr(main.Plugin, m, None))]
(ok if not missing else bad)(f"the backend exposes the entry writer + boot re-assert (missing: {missing})")

plugin = main.Plugin()
tmp = pathlib.Path(tempfile.mkdtemp(prefix="store-shortcuts."))
p = {"NOVADECK_STORE_HOME": str(tmp), "NOVADECK_STORE_UID": str(os.getuid()),
     "NOVADECK_STORE_USER": "deck", "NOVADECK_STORE_INSTALLS": str(tmp / "installs.json")}
main.paths.store_paths = lambda ensure=False: p
def direct_write(pp, path, text):
    pathlib.Path(path).write_text(text); return 0
shortcuts.cli.write_as_user = direct_write
(tmp / "installs.json").write_text(json.dumps({
    "epic:Alba": {"store": "epic", "id": "Alba", "title": "ACS", "path": "/games/Alba", "state": "installing"},
    "gog:native": {"store": "gog", "id": "native", "title": "SMB", "path": "/games/SMB", "platform": "linux", "state": "installing"}}))

# Windows: resolve to a .exe → add + compat(our Proton); registry carries exe+platform.
main.launch.resolve_target = lambda store, gid, pp, rec: {
    "exe": f"/games/{gid}/game.exe", "startdir": f"/games/{gid}", "platform": "windows"}
res = asyncio.run(plugin.register_entry("epic", "Alba", "ACS"))
(ok if res.get("registered") and res.get("platform") == "windows" else bad)(f"a Windows register succeeds ({res})")
ops = [pl["op"] for ev, pl in emitted]
(ok if ops == ["add", "compat"] else bad)(f"Windows register emits add THEN compat ({ops})")
compat = emitted[-1][1]
(ok if compat["tool"] == "proton-cachyos-11.0-arm64" and compat["appid"] == 2981617462 else bad)(
    f"the compat op sets our Proton on the appid ({compat})")
add = emitted[0][1]
(ok if add["exe"] == "/games/Alba/game.exe" and add["options"] == "/usr/lib/novadeck/game-launch %command%" else bad)(
    f"the add op carries the game exe and game-launch %command% ({add})")
row = json.loads((tmp / "shortcuts.json").read_text())["epic:Alba"]
(ok if row["exe"] == "/games/Alba/game.exe" and row["platform"] == "windows" else bad)(
    f"the registry row records exe + platform ({row})")

# Native: resolve to start.sh, platform linux → add ONLY, no compat op.
emitted.clear()
main.launch.resolve_target = lambda store, gid, pp, rec: {
    "exe": f"{rec['path']}/start.sh", "startdir": rec["path"], "platform": "linux"}
res = asyncio.run(plugin.register_entry("gog", "native"))
ops = [pl["op"] for ev, pl in emitted]
(ok if res.get("registered") and ops == ["add"] else bad)(
    f"a native register emits add only — no compat tool ({ops})")

# Not installed: resolve_target None → refused, nothing emitted.
emitted.clear()
main.launch.resolve_target = lambda store, gid, pp, rec: None
res = asyncio.run(plugin.register_entry("epic", "Alba", "ACS"))
(ok if "error" in res and not emitted else bad)(f"an unresolvable (not installed) game is refused ({res})")

# Double register refused before the bridge (re-point resolve, keep the Alba row).
main.launch.resolve_target = lambda store, gid, pp, rec: {
    "exe": f"/games/{gid}/game.exe", "startdir": f"/games/{gid}", "platform": "windows"}
emitted.clear()
res = asyncio.run(plugin.register_entry("epic", "Alba", "ACS"))
(ok if res.get("error") == "already registered" and not emitted else bad)(
    f"a second register for the same id is refused before the bridge ({res})")

# Deregister sends the registry appid, drops only that row.
res = asyncio.run(plugin.deregister_entry("gog", "native"))
(ok if res.get("deregistered") else bad)(f"deregister succeeds ({res})")
rows = json.loads((tmp / "shortcuts.json").read_text())
(ok if "gog:native" not in rows and "epic:Alba" in rows else bad)("only the deregistered row leaves the registry")

# reassert_compat fires a compat op for the Windows row, none for native (already removed anyway).
emitted.clear()
asyncio.run(plugin.reassert_compat(p))
asyncio.run(asyncio.sleep(0))  # let the fire-and-forget tasks run
compat_ops = [pl for ev, pl in emitted if pl["op"] == "compat"]
(ok if all(pl["tool"] == "proton-cachyos-11.0-arm64" for pl in compat_ops) and len(compat_ops) == 1 else bad)(
    f"boot re-assert sets the compat tool on each Windows row ({len(compat_ops)} ops)")
PY

grep -q 'test-store-shortcuts.sh' "$ROOT/Makefile" \
  && ok "this suite is wired into make test (a suite nothing runs is documentation)" \
  || bad "tests/test-store-shortcuts.sh is not in the Makefile test target"

echo
echo "test-store-shortcuts.sh: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
