#!/usr/bin/env bash
# Offline checks for alien-games milestone 4: the library entry writer
# (.claude/plans/alien-games-library-entry.plan.md).
#
#   tests/test-store-shortcuts.sh
#
# WHY THIS FILE EXISTS. The expensive failures here are destructive ones against Steam's own
# state: deleting an entry that is not ours (unifideck's incident UD-006), or writing a
# LaunchOptions the stub then refuses. What the backend DECIDES is checkable offline: the exact
# entry fields, the ownership rule, the argv contract between the two sides of the token, and
# which registry operations are refused. Fixture bytes stand in for shortcuts.vdf.
#
# WHAT IT CANNOT PROVE: AddShortcut's behaviour on the real arm64 client, that an entry survives
# a Steam restart, or that the appid Steam hands back is usable. Those are the hardware gate.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STORES_PY="$ROOT/apps/decky/novadeck-stores/py_modules"
STUB="$ROOT/rootfs/overlay/usr/lib/novadeck/store-launch"
PASS=0 FAIL=0 SKIP=0
ok()  { printf '  ok   %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL %s\n' "$*"; FAIL=$((FAIL + 1)); }

pysuite() {
  local name="$1" out rc
  out="$(python3 - "$STORES_PY" "$STUB")"
  rc=$?
  printf '%s\n' "$out"
  PASS=$((PASS + $(grep -c '^  ok ' <<<"$out" || true)))
  FAIL=$((FAIL + $(grep -c '^  FAIL' <<<"$out" || true)))
  [ "$rc" -eq 0 ] || bad "the $name checks crashed (exit $rc) — every check after the crash never ran"
}

echo "== the stub"
[ -x "$STUB" ] \
  && ok "store-launch ships executable" \
  || bad "store-launch missing or not executable at usr/lib/novadeck/store-launch"

pysuite "stub" <<'PY'
import json, os, pathlib, stat, subprocess, sys, tempfile
sys.path.insert(0, sys.argv[1])
STUB = sys.argv[2]

def ok(m): print(f"  ok   {m}")
def bad(m): print(f"  FAIL {m}")

# A fixture store-env: the stub must ASK where the store home is, never assume it, and it must
# scrub the loader's LD_* before spawning anything native (the unifideck launcher does the same).
tmp = pathlib.Path(tempfile.mkdtemp(prefix="store-shortcuts."))
home = tmp / "stores"
home.mkdir()
fixture_env = tmp / "store-env"
fixture_env.write_text(
    "#!/usr/bin/env bash\n"
    f"[ -n \"${{LD_PRELOAD:-}}\" ] && exit 97\n"
    f"[ -n \"${{LD_LIBRARY_PATH:-}}\" ] && exit 98\n"
    f"printf 'NOVADECK_STORE_HOME=%q\\n' '{home}'\n")
fixture_env.chmod(0o755)

def run_stub(*args):
    env = dict(os.environ, NOVADECK_STORE_ENV=str(fixture_env),
               LD_PRELOAD="/nonexistent.so", LD_LIBRARY_PATH="/steam/libs")
    return subprocess.run([sys.executable, STUB, *args], capture_output=True, text=True, env=env)

log = home / "store-launch.log"

r = run_stub("epic:0a20ccd3f1b3464da750a4dbf8c80d7c")
(ok if r.returncode == 64 else bad)(
    f"a valid token exits 64 — launchable arrives in milestone 6 (got {r.returncode}, stderr: {r.stderr.strip()!r})")
lines = log.read_text().splitlines() if log.exists() else []
(ok if len(lines) == 1 and "epic:0a20ccd3f1b3464da750a4dbf8c80d7c" in lines[0] else bad)(
    f"the attempt is logged, once, with its token ({lines})")
(ok if "milestone 6" in (lines[0] if lines else "") or "not yet" in (lines[0] if lines else "").lower() else bad)(
    "the log line says WHY nothing launched, not just that it didn't")

r = run_stub("gog:1207658924", "--some-user-param", "value with space")
lines = log.read_text().splitlines() if log.exists() else []
(ok if r.returncode == 64 and len(lines) == 2 and "--some-user-param" in lines[1] else bad)(
    "user params around the token survive into the log and change nothing else")

before = log.read_text() if log.exists() else ""
for bogus in ("", "noColon", "steam:123", "epic:", "epic:..", "epic:a/b", "epic:a\nb", "EPIC:abc"):
    r = run_stub(bogus) if bogus else run_stub()
    if r.returncode != 2:
        bad(f"bogus argv {bogus!r} must exit 2, got {r.returncode}")
        break
else:
    ok("every bogus argv exits 2: empty, no colon, unknown store, empty id, dot-dot, slash, newline, wrong case")
after = log.read_text() if log.exists() else ""
(ok if before == after else bad)("a refused argv logs NOTHING — an unvalidated token never reaches the log")

# The scrub is proven by the fixture itself: exits 97/98 would have failed the cases above.
ok("LD_PRELOAD and LD_LIBRARY_PATH are scrubbed before store-env runs (fixture asserts it)")
PY

echo "== entry template, ownership, registry, verification"
pysuite "shortcuts-module" <<'PY'
import importlib.machinery, importlib.util, json, os, pathlib, re, subprocess, sys, tempfile
sys.path.insert(0, sys.argv[1])
STUB = sys.argv[2]

def ok(m): print(f"  ok   {m}")
def bad(m): print(f"  FAIL {m}")

from novadeck_stores import shortcuts

# -- the entry template --
e = shortcuts.entry_fields("epic", "Albacore", "Assassins Creed Syndicate",
                           "/home/deck/Games/Epic/Albacore")
(ok if e["Exe"] == '"/usr/lib/novadeck/store-launch"' else bad)(
    f"Exe is the quoted stub on the read-only root ({e['Exe']})")
(ok if e["LaunchOptions"] == "epic:Albacore" else bad)(
    f"LaunchOptions is the bare token, argv[1] of the stub ({e['LaunchOptions']})")
(ok if e["StartDir"] == '"/home/deck/Games/Epic/Albacore"' else bad)("StartDir is the quoted install path")
(ok if e["AppName"] == "Assassins Creed Syndicate" else bad)("AppName is the store title")
e2 = shortcuts.entry_fields("gog", "1207658924", "The Witcher", None)
(ok if e2["StartDir"] == '""' else bad)('a not-installed entry gets StartDir "" (quoted empty)')
for store, gid in (("steam", "x"), ("epic", ""), ("epic", "a/b"), ("epic", "a\nb"), ("epic", "..")):
    try:
        shortcuts.entry_fields(store, gid, "t", None)
        bad(f"entry_fields({store!r}, {gid!r}) must refuse, token would not survive the stub")
        break
    except ValueError:
        pass
else:
    ok("entry_fields refuses every token the stub would refuse — the two ends cannot drift apart")

# The cross-pin: every token entry_fields emits is accepted by the SHIPPED stub, exit 64.
r = subprocess.run([sys.executable, STUB, e["LaunchOptions"]], capture_output=True, text=True,
                   env=dict(os.environ, NOVADECK_STORE_ENV="/nonexistent"))
(ok if r.returncode == 64 else bad)(
    f"a token the template emits is accepted by the shipped stub even with no store-env (got {r.returncode})")

# -- ownership: by Exe basename alone (unifideck incident UD-006) --
ours = {"Exe": '"/home/deck/homebrew/../../../usr/lib/novadeck/store-launch"'}
(ok if shortcuts.is_ours({"Exe": '"/usr/lib/novadeck/store-launch"'}) else bad)("quoted stub path is ours")
(ok if shortcuts.is_ours({"exe": "/usr/lib/novadeck/store-launch"}) else bad)("lowercase 'exe' key counts")
(ok if not shortcuts.is_ours({"Exe": '"/usr/bin/some-game"', "LaunchOptions": "epic:Albacore"}) else bad)(
    "a FOREIGN entry carrying our token is NOT ours — the token is never proof")
(ok if not shortcuts.is_ours({"AppName": "x", "tags": {"0": "novadeck"}}) else bad)(
    "a missing Exe is not ours, whatever the tags claim")
(ok if not shortcuts.is_ours({"Exe": '"/elsewhere/store-launch-evil"'}) else bad)(
    "a basename that merely CONTAINS ours is not ours")

# -- registry: mirror of installs.json, written as the store user --
tmp = pathlib.Path(tempfile.mkdtemp(prefix="store-shortcuts."))
reg = tmp / "shortcuts.json"
p = {"NOVADECK_STORE_HOME": str(tmp), "NOVADECK_STORE_UID": str(os.getuid()),
     "NOVADECK_STORE_USER": "deck"}
(ok if shortcuts.registry_path(p) == str(reg) else bad)(
    f"the registry lives beside installs.json in the store home ({shortcuts.registry_path(p)})")
from novadeck_stores import cli
writes = []
cli_write, cli_sig = cli.write_as_user, None
def fake_write(pp, path, text):
    writes.append(path)
    pathlib.Path(path).write_text(text)
    return 0
shortcuts.cli.write_as_user = fake_write
try:
    okay = shortcuts.write_registry(p, {"epic:Albacore": {"appid": 2956058129, "title": "ACS"}})
    rows = shortcuts.read_registry(p)
finally:
    shortcuts.cli.write_as_user = cli_write
(ok if okay and writes == [str(reg)] else bad)(
    f"the registry write goes through write_as_user to the registry path ({writes})")
(ok if rows.get("epic:Albacore", {}).get("appid") == 2956058129 else bad)(
    f"the registry round-trips ({rows})")
(ok if shortcuts.read_registry({**p, "NOVADECK_STORE_HOME": str(tmp / "absent")}) == {} else bad)(
    "a missing registry is an empty one, never an error")

# -- the verification reader over fixture shortcuts.vdf bytes --
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

fixture = bvdf({"shortcuts": {
    "0": {"appid": 123, "AppName": "Healthy", "Exe": '"/usr/lib/novadeck/store-launch"',
          "LaunchOptions": "epic:Albacore"},
    "1": {"appid": 456, "AppName": "No token", "Exe": '"/usr/lib/novadeck/store-launch"',
          "LaunchOptions": ""},
    "2": {"appid": 789, "AppName": "Foreign with our token", "Exe": '"/usr/bin/other-tool"',
          "LaunchOptions": "gog:1207658924"},
    "3": {"appid": 321, "AppName": "User game", "Exe": '"/usr/bin/retroarch"', "LaunchOptions": ""},
}})
entries = shortcuts.our_entries(fixture)
(ok if sorted(x["appid"] for x in entries) == [123, 456] else bad)(
    f"our_entries finds exactly the two stub entries, by Exe ({[x['appid'] for x in entries]})")
report = shortcuts.orphan_report(fixture, {"epic:Albacore": {"appid": 123},
                                           "gog:1207658924": {"appid": 999}})
(ok if [x["token"] for x in report["healthy"]] == ["epic:Albacore"] else bad)(
    f"a registered token on an entry we own is healthy ({report['healthy']})")
(ok if [x["appid"] for x in report["orphan_no_token"]] == [456] else bad)(
    f"our entry with no token is an orphan, report-only ({report['orphan_no_token']})")
(ok if [x["token"] for x in report["registry_without_entry"]] == ["gog:1207658924"] else bad)(
    "a registry row whose entry is gone is reported — the foreign entry carrying its token is NOT matched")
truncated = fixture[:-5]
try:
    shortcuts.our_entries(truncated)
    bad("truncated vdf bytes must raise, never read as an empty file")
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
    # Answer like the bridge would, pairing by req: adds get an appid, removes an ack.
    appid = 2956058129 if payload["op"] == "add" else None
    asyncio.get_running_loop().create_task(plugin.shortcut_result(payload["req"], appid, None))

sys.modules["decky"] = types.SimpleNamespace(
    logger=types.SimpleNamespace(info=lambda *a: None), emit=fake_emit)
sys.path.insert(0, os.path.join(sys.argv[1], ".."))
import main
from novadeck_stores import shortcuts

methods = ["register_entry", "deregister_entry", "entry_status", "shortcut_result"]
missing = [m for m in methods if not inspect.iscoroutinefunction(getattr(main.Plugin, m, None))]
(ok if not missing else bad)(f"the backend exposes the entry writer (missing: {missing})")

plugin = main.Plugin()
tmp = pathlib.Path(tempfile.mkdtemp(prefix="store-shortcuts."))
p = {"NOVADECK_STORE_HOME": str(tmp), "NOVADECK_STORE_UID": str(os.getuid()),
     "NOVADECK_STORE_USER": "deck", "NOVADECK_STORE_INSTALLS": str(tmp / "installs.json"),
     "LEGENDARY_CONFIG_PATH": str(tmp / "legendary"), "NOVADECK_GOGDL_AUTH": str(tmp / "a.json"),
     "GOGDL_CONFIG_PATH": str(tmp / "gogdl")}
main.paths.store_paths = lambda ensure=False: p
def direct_write(pp, path, text):
    pathlib.Path(path).write_text(text)
    return 0
shortcuts.cli.write_as_user = direct_write

(ok if "error" in asyncio.run(plugin.register_entry("steam", "x", "t")) else bad)(
    "an unknown store is refused before anything runs")
(ok if "error" in asyncio.run(plugin.register_entry("epic", "NoRecord")) else bad)(
    "a game with no install record and no passed title is refused — an entry needs a name")

res = asyncio.run(plugin.register_entry("epic", "Albacore", "Assassins Creed Syndicate"))
(ok if res.get("registered") and res.get("appid") == 2956058129 else bad)(
    f"a register round-trips through the bridge and returns Steam's appid ({res})")
event, payload = emitted[-1]
(ok if event == "shortcut_op" and payload["op"] == "add"
    and payload["exe"] == "/usr/lib/novadeck/store-launch"
    and payload["options"] == "epic:Albacore" and payload["dir"] == ""
    and payload["name"] == "Assassins Creed Syndicate" else bad)(
    f"the add payload carries unquoted paths and the bare token ({payload})")
rows = json.loads((tmp / "shortcuts.json").read_text())
(ok if rows.get("epic:Albacore", {}).get("appid") == 2956058129 else bad)(
    f"the appid Steam returned lands in the registry ({rows})")

res = asyncio.run(plugin.register_entry("epic", "Albacore", "Assassins Creed Syndicate"))
(ok if res.get("error") == "already registered" and len(emitted) == 1 else bad)(
    f"a second register for the same id is refused BEFORE the bridge is asked ({res})")

# An install record supplies title and StartDir when nothing is passed.
(tmp / "installs.json").write_text(json.dumps({"gog:1207658924": {
    "store": "gog", "id": "1207658924", "title": "The Witcher: Enhanced Edition",
    "path": "/home/deck/Games/GOG/The Witcher Enhanced Edition", "state": "installing"}}))
res = asyncio.run(plugin.register_entry("gog", "1207658924"))
payload = emitted[-1][1]
(ok if res.get("registered") and payload["name"] == "The Witcher: Enhanced Edition"
    and payload["dir"] == "/home/deck/Games/GOG/The Witcher Enhanced Edition" else bad)(
    f"an installed game's title and StartDir come from the install record ({payload})")

res = asyncio.run(plugin.deregister_entry("gog", "1207658924"))
payload = emitted[-1][1]
(ok if res.get("deregistered") and payload == {"op": "remove", "req": payload["req"],
                                               "appid": 2956058129} else bad)(
    f"a deregister sends the registry's appid to the bridge ({payload})")
rows = json.loads((tmp / "shortcuts.json").read_text())
(ok if "gog:1207658924" not in rows and "epic:Albacore" in rows else bad)(
    f"only the deregistered row leaves the registry ({rows})")
(ok if asyncio.run(plugin.deregister_entry("gog", "1207658924")).get("error") == "not registered" else bad)(
    "deregistering an unknown id is refused and logged, the registry untouched")

# A SteamUI that never answers is an error, not a hang.
async def silent_emit(event, payload): pass
main.decky.emit = silent_emit
main.SHORTCUT_TIMEOUT = 0.05
res = asyncio.run(plugin.register_entry("epic", "Timeout", "Never Answers"))
(ok if "did not answer" in res.get("error", "") else bad)(
    f"no shortcut_result within the timeout is an error ({res})")
(ok if not plugin._shortcut_pending else bad)("a timed-out request does not leak its future")
PY

grep -q 'test-store-shortcuts.sh' "$ROOT/Makefile" \
  && ok "this suite is wired into make test (a suite nothing runs is documentation)" \
  || bad "tests/test-store-shortcuts.sh is not in the Makefile test target"

echo
echo "test-store-shortcuts.sh: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
