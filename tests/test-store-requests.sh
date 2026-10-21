#!/usr/bin/env bash
# Offline checks for alien-games milestone 7 task 2 (.claude/plans/alien-games-panel.plan.md):
# a not-installed tile's Exe is the install-only stub, and pressing Play hands the backend an
# install request through a spool in the user's store home.
#
#   tests/test-store-requests.sh
#
# WHY THIS FILE EXISTS. Two sides meet at a directory the user owns: the stub (running as the user
# from Steam) creates <token>.install, the root backend takes it. The expensive failures are root
# acting on something the user planted — a symlinked spool, a forged name, a token that names no
# tile of ours — and a press that silently does nothing (the stub must say when the plugin is not
# there). Both sides are driven here against a temp tree; the token grammar is cross-pinned.
#
# WHAT IT CANNOT PROVE: that Steam runs the stub with argv[1] = the token on the arm64 client, or
# that the toast reaches the screen. Those are the milestone-7 hardware walkthrough.
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

echo "== the install-only stub"
[ -x "$STUB" ] \
  && ok "store-launch ships executable" \
  || bad "store-launch missing or not executable at usr/lib/novadeck/store-launch"

pysuite "stub" <<'PY'
import os, pathlib, re, subprocess, sys, tempfile, threading, time
sys.path.insert(0, sys.argv[1])
STUB = sys.argv[2]

def ok(m): print(f"  ok   {m}")
def bad(m): print(f"  FAIL {m}")

from novadeck_stores import install_requests, shortcuts

tmp = pathlib.Path(tempfile.mkdtemp(prefix="store-requests."))
home = tmp / "stores"
home.mkdir()
# A fixture store-env that refuses to run with Steam's loader variables still set.
fixture_env = tmp / "store-env"
fixture_env.write_text(
    "#!/usr/bin/env bash\n"
    "[ -n \"${LD_PRELOAD:-}\" ] && exit 97\n"
    "[ -n \"${LD_LIBRARY_PATH:-}\" ] && exit 98\n"
    f"printf 'NOVADECK_STORE_HOME=%q\\n' '{home}'\n")
fixture_env.chmod(0o755)
p = {"NOVADECK_STORE_HOME": str(home), "NOVADECK_STORE_UID": str(os.getuid())}

def run_stub(*args, timeout="1"):
    env = dict(os.environ, NOVADECK_STORE_ENV=str(fixture_env), NOVADECK_STORE_TAKE_TIMEOUT=timeout,
               LD_PRELOAD="/nonexistent.so", LD_LIBRARY_PATH="/steam/libs")
    return subprocess.run([sys.executable, STUB, *args], capture_output=True, text=True, env=env)

spool = home / "requests"
log = home / "store-launch.log"

# -- the stub's grammar IS shortcuts.TOKEN, read from the shipped file --
src = pathlib.Path(STUB).read_text()
m = re.search(r'TOKEN = re\.compile\(r"([^"]+)"\)', src)
(ok if m and m.group(1) == shortcuts.TOKEN.pattern else bad)(
    "the stub's token grammar is exactly shortcuts.TOKEN — the two ends cannot drift apart")
(ok if not re.search(r"\b(proton|umu|game-launch|SteamLinuxRuntime|exec[lv])", src.split('"""', 2)[2]) else bad)(
    "the stub's code names no launch machinery — it installs and exits, never launches")

# -- the shelf template points at THIS stub with the bare token --
f = shortcuts.shelf_fields("gog", "1207658924", "The Witcher")
(ok if f["Exe"] == '"/usr/lib/novadeck/store-launch"' and f["LaunchOptions"] == "gog:1207658924" else bad)(
    f"a not-installed tile runs the stub with the bare token as argv[1] ({f})")
(ok if STUB.endswith(shortcuts.STUB) else bad)("shortcuts.STUB is where the overlay ships the stub")
try:
    shortcuts.shelf_fields("epic", "../x", "t")
    bad("shelf_fields must refuse an unsafe id")
except ValueError:
    ok("shelf_fields refuses an id the stub would refuse")

# -- bad argv: refused, nothing written --
r = run_stub("epic:../../etc")
(ok if r.returncode == 2 and not spool.exists() and not log.exists() else bad)(
    f"a token outside the grammar exits 2 and touches no file (rc {r.returncode})")

# -- nobody takes it: withdrawn, logged, exit 69 --
r = run_stub("gog:1207658924", timeout="0.5")
left = list(spool.iterdir()) if spool.exists() else []
(ok if r.returncode == 69 else bad)(f"no backend answering exits 69 (rc {r.returncode}, {r.stderr.strip()!r})")
(ok if left == [] else bad)(f"the untaken request is withdrawn, not left to fire later ({left})")
(ok if log.exists() and "did not answer" in log.read_text() else bad)(
    "the log says the plugin did not answer — a press never turns into silence")
(ok if (spool.stat().st_mode & 0o777) == 0o700 else bad)(f"the spool is 0700 ({oct(spool.stat().st_mode & 0o777)})")

# -- a backend takes it: exit 0, the backend saw exactly the token --
seen = []
def backend():
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline and not seen:
        seen.extend(install_requests.take(p))
        time.sleep(0.05)
t = threading.Thread(target=backend); t.start()
r = run_stub("epic:Albacore", "--user-param", timeout="5")
t.join()
(ok if r.returncode == 0 and seen == ["epic:Albacore"] else bad)(
    f"a taken request exits 0 and the backend got the token ({r.returncode}, {seen})")
(ok if "install requested" in log.read_text().splitlines()[-1] else bad)("the taken request is logged")
PY

echo "== the backend's side of the spool"
pysuite "take" <<'PY'
import os, pathlib, sys, tempfile
sys.path.insert(0, sys.argv[1])

def ok(m): print(f"  ok   {m}")
def bad(m): print(f"  FAIL {m}")

from novadeck_stores import install_requests

tmp = pathlib.Path(tempfile.mkdtemp(prefix="store-requests."))
p = {"NOVADECK_STORE_HOME": str(tmp), "NOVADECK_STORE_UID": str(os.getuid())}
(ok if install_requests.take(p) == [] else bad)("no spool is no requests, not an error")

spool = tmp / "requests"
spool.mkdir()
(spool / "gog:1.install").touch()
os.utime(spool / "gog:1.install", ns=(1, 1))
(spool / "epic:A.install").touch()
(spool / "epic:..install").touch()            # fails the grammar
(spool / "steam:440.install").touch()         # not our store
(spool / "gog:2.other").touch()               # not a request
(spool / "gog:3.install").mkdir()             # not a regular file
target = tmp / "victim"; target.write_text("keep")
(spool / "gog:4.install").symlink_to(target)  # a link
got = install_requests.take(p)
(ok if got == ["gog:1", "epic:A"] else bad)(f"only well-formed regular-file requests, oldest first ({got})")
rest = sorted(x.name for x in spool.iterdir())
(ok if rest == ["gog:2.other", "gog:3.install"] else bad)(
    f"every .install name is consumed, valid or not, except what cannot be unlinked as a file ({rest})")
(ok if target.read_text() == "keep" else bad)("a symlinked request is unlinked, never followed")

# A spool that is itself a link is refused outright — nothing behind it is touched.
other = tmp / "elsewhere"; other.mkdir()
(other / "epic:B.install").touch()
for x in spool.iterdir():
    x.rmdir() if x.is_dir() else x.unlink()
spool.rmdir()
spool.symlink_to(other)
(ok if install_requests.take(p) == [] and (other / "epic:B.install").exists() else bad)(
    "a symlinked spool is refused and what it points at is untouched")
PY

echo "== the backend acts only on our not-installed tiles"
pysuite "backend" <<'PY'
import asyncio, json, os, pathlib, sys, tempfile, types
sys.path.insert(0, sys.argv[1])

def ok(m): print(f"  ok   {m}")
def bad(m): print(f"  FAIL {m}")

emitted = []
async def fake_emit(event, payload):
    emitted.append((event, payload))
sys.modules["decky"] = types.SimpleNamespace(
    logger=types.SimpleNamespace(info=lambda *a: None), emit=fake_emit)
sys.path.insert(0, os.path.join(sys.argv[1], ".."))
import main

tmp = pathlib.Path(tempfile.mkdtemp(prefix="store-requests."))
p = {"NOVADECK_STORE_HOME": str(tmp), "NOVADECK_STORE_UID": str(os.getuid()), "NOVADECK_STORE_USER": "deck"}
(tmp / "shortcuts.json").write_text(json.dumps({
    "gog:shelf": {"appid": 1, "title": "Shelf Game", "state": "shelf"},
    "epic:installed": {"appid": 2, "title": "Installed", "exe": "/g/x.exe", "platform": "windows"}}))
main.install_requests.take = lambda pp: ["gog:shelf", "epic:installed", "gog:unknown"]
main.locations.user_volumes = lambda user: [{"path": "/home/deck", "label": "Internal", "free": 1},
                                            {"path": "/run/media/deck/SD", "label": "SD", "free": 9}]
calls = []
async def fake_install(self, store, gid, title, drive):
    calls.append((store, gid, title, drive))
    return {"started": True, "path": "/x"}
main.Plugin.install = fake_install

asyncio.run(main.Plugin().take_install_requests(p))
(ok if calls == [("gog", "shelf", "Shelf Game", "/home/deck")] else bad)(
    f"only the shelf tile installs, to the default drive (Internal), with its registry title ({calls})")
ev = [pl for e, pl in emitted if e == "install_event"]
(ok if len(ev) == 1 and ev[0]["ok"] and ev[0]["title"] == "Shelf Game" and "Internal" in ev[0]["message"] else bad)(
    f"one install_event says where it is installing ({ev})")

emitted.clear()
async def refused(self, store, gid, title, drive):
    return {"error": "another game is installing"}
main.Plugin.install = refused
main.install_requests.take = lambda pp: ["gog:shelf"]
asyncio.run(main.Plugin().take_install_requests(p))
ev = [pl for e, pl in emitted if e == "install_event"]
(ok if len(ev) == 1 and not ev[0]["ok"] and ev[0]["message"] == "another game is installing" else bad)(
    f"a refused install is still reported, with the reason ({ev})")

from novadeck_stores import locations
vols = [{"path": "/a", "label": "Internal"}, {"path": "/b", "label": "SD"}]
(ok if locations.default_volume(vols, "/b")["path"] == "/b" else bad)("a mounted preferred drive is used")
(ok if locations.default_volume(vols, "/gone")["path"] == "/a" else bad)("an absent preferred drive falls back to Internal")
(ok if locations.default_volume([]) is None else bad)("no drives at all is None, not a crash")
PY

grep -q 'test-store-requests.sh' "$ROOT/Makefile" \
  && ok "this suite is wired into make test (a suite nothing runs is documentation)" \
  || bad "tests/test-store-requests.sh is not in the Makefile test target"

echo
echo "test-store-requests.sh: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
