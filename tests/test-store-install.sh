#!/usr/bin/env bash
# Offline checks for alien-games milestone 3: listing owned titles, choosing where a game goes,
# installing, resuming and uninstalling (.claude/plans/alien-games-install.plan.md).
#
#   tests/test-store-install.sh
#
# WHY THIS FILE EXISTS. Every download is tens of GB against a real account, and the interesting
# failures — a resume that silently restarts, an uninstall that deletes the wrong directory — are
# the expensive ones to find on hardware. What the backend DECIDES is checkable here: which argv
# runs, as whom, under which unit properties; how the files the CLIs leave behind map to a state;
# and which paths the uninstall refuses. Fixture trees stand in for the device.
#
# WHAT IT CANNOT PROVE: that either CLI downloads, what a network cut does to it, or that GOG's
# product API still has the shape the parser expects. Those are the hardware gate.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STORES_PY="$ROOT/apps/decky/novadeck-stores/py_modules"
GOG_OWNED="$ROOT/rootfs/overlay/usr/lib/novadeck/store-gog-owned"
PASS=0 FAIL=0 SKIP=0
ok()  { printf '  ok   %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL %s\n' "$*"; FAIL=$((FAIL + 1)); }

# Runs a python block that prints ok/FAIL lines, and folds them into the totals.
pysuite() {
  local name="$1" out rc
  out="$(python3 - "$STORES_PY" "$GOG_OWNED" "$ROOT")"
  rc=$?
  printf '%s\n' "$out"
  PASS=$((PASS + $(grep -c '^  ok ' <<<"$out" || true)))
  FAIL=$((FAIL + $(grep -c '^  FAIL' <<<"$out" || true)))
  [ "$rc" -eq 0 ] || bad "the $name checks crashed (exit $rc) — every check after the crash never ran"
}

echo "== owned titles"
[ -x "$GOG_OWNED" ] \
  && ok "store-gog-owned ships executable" \
  || bad "store-gog-owned missing or not executable at usr/lib/novadeck/store-gog-owned"

pysuite "owned-titles" <<'PY'
import importlib.machinery, importlib.util, json, subprocess, sys
sys.path.insert(0, sys.argv[1])

def ok(m): print(f"  ok   {m}")
def bad(m): print(f"  FAIL {m}")

# -- the GOG helper: a script, loaded as a module. It must not need gogdl to import. --
loader = importlib.machinery.SourceFileLoader("store_gog_owned", sys.argv[2])
spec = importlib.util.spec_from_loader(loader.name, loader)
helper = importlib.util.module_from_spec(spec)
loader.exec_module(helper)

calls = []
def fake_get(url):
    calls.append(url)
    if url.endswith("/user/data/games"):
        return {"owned": list(range(1, 121))}
    ids = [int(i) for i in url.split("ids=")[1].split(",")]
    out = []
    for i in ids:
        if i == 2:
            out.append({"id": i, "title": "A DLC", "game_type": "dlc",
                        "content_system_compatibility": {"windows": True}})
        elif i == 3:
            out.append({"id": i, "title": "Mac only", "game_type": "game",
                        "content_system_compatibility": {"windows": False, "osx": True}})
        else:
            out.append({"id": i, "title": f"Game {i:03d}", "game_type": "game",
                        "content_system_compatibility": {"windows": True}})
    return out

titles = helper.owned_titles(fake_get)
product_calls = [c for c in calls if "ids=" in c]
(ok if all(len(c.split("ids=")[1].split(",")) <= 50 for c in product_calls) and len(product_calls) == 3 else bad)(
    f"product details are fetched in batches of at most 50 ({len(product_calls)} calls for 120 ids)")
ids = {t["id"] for t in titles}
(ok if "2" not in ids and len(titles) == 119 else bad)("DLC is not listed as a title of its own")
mac = [t for t in titles if t["id"] == "3"]
(ok if mac and mac[0]["installable"] is False else bad)(
    "a title with no Windows build is listed, but not installable (Windows builds only, this milestone)")
(ok if all(set(t) == {"id", "title", "installable"} for t in titles) else bad)(
    "each title is id / title / installable and nothing else")
(ok if [t["title"] for t in titles] == sorted(t["title"] for t in titles) else bad)(
    "titles come back sorted by name")

# -- Epic: legendary list --json --
from novadeck_stores import cli, library
lgd = json.dumps([
    {"app_name": "Fir", "app_title": "Fir Game", "metadata": {"customAttributes": {}}},
    {"app_name": "Ubi", "app_title": "Ubi Game",
     "metadata": {"customAttributes": {"ThirdPartyManagedApp": {"value": "Ubisoft Connect"}}}},
    {"app_name": "Alba", "app_title": "Alba Game",
     "metadata": {"customAttributes": {"ThirdPartyManagedProvider": {"value": "UbisoftConnect"},
                                       "partnerLinkType": {"value": "ubisoft"}}}},
    {"app_name": "Bare", "app_title": "No metadata", "metadata": None},
    # Death Stranding's extras bundle, as legendary lists it on the Pocket FIT (2026-10-22): no
    # mainGameItem, so legendary does not hide it as DLC; only the category says what it is.
    {"app_name": "5bf67f31", "app_title": "Death Stranding Content",
     "metadata": {"customAttributes": {},
                  "categories": [{"path": "public"}, {"path": "digitalextras"}, {"path": "games"},
                                 {"path": "applications"}]}},
])
t = library.epic_titles(lgd)
by = {x["id"]: x for x in t}
(ok if by["Fir"] == {"id": "Fir", "title": "Fir Game", "installable": True} else bad)(
    f"an ordinary Epic title is installable ({by.get('Fir')})")
(ok if by["Ubi"]["installable"] is False and by["Ubi"].get("requires") == "Ubisoft Connect" else bad)(
    "a third-party-managed Epic title is listed as needing its launcher, not installable "
    "(milestone 1's Ubisoft finding)")
(ok if by["Alba"]["installable"] is True and by["Alba"].get("requires") == "ubisoft" else bad)(
    "a partner-linked Epic title installs but says what it needs to run "
    f"(AC Syndicate's shape, measured on HW 2026-10-20: {by.get('Alba')})")
(ok if by["Bare"]["installable"] is True else bad)("an Epic title with no metadata does not crash the list")
(ok if by["5bf67f31"]["installable"] is False and "requires" not in by["5bf67f31"] else bad)(
    f"Epic's digital-extras bundle (soundtrack, artbook) is owned but gets no tile — it is not a game ({by.get('5bf67f31')})")
(ok if library.epic_titles("not json") is None and library.epic_titles('{"a": 1}') is None else bad)(
    "unparseable legendary output is no answer, not an empty library")

# -- which argv lists each store, as whom, and that stdout is read --
p = {"NOVADECK_STORE_USER": "deck", "LEGENDARY_CONFIG_PATH": "/h/legendary",
     "NOVADECK_GOGDL_AUTH": "/h/gogdl/auth.json", "GOGDL_CONFIG_PATH": "/h/gogdl"}
(ok if library.list_argv("epic", p) == ["legendary", "list", "--json"] else bad)("Epic lists with legendary list --json")
(ok if library.list_argv("gog", p) == ["/usr/lib/novadeck/store-gog-owned", "/h/gogdl/auth.json"] else bad)(
    "GOG lists through the helper, handed the declared auth path")

seen = {}
real_run = subprocess.run
def fake_run(argv, **kw):
    seen.update(argv=argv, **kw)
    return subprocess.CompletedProcess(argv, 0, stdout=lgd)
subprocess.run = fake_run
try:
    res = library.owned("epic", p)
finally:
    subprocess.run = real_run
sd = seen["argv"]
opts = sd[:sd.index("--")]
(ok if sd[0] == "systemd-run" and "--property=User=deck" in opts and "--pipe" in opts else bad)(
    "the list runs as deck through host systemd, output piped back")
(ok if seen.get("stdout") is subprocess.PIPE else bad)(
    "the list's stdout is read — it carries titles, never a token")
(ok if res == {"titles": library.epic_titles(lgd)} else bad)(f"owned() returns the parsed titles ({res})")

def failing_run(argv, **kw):
    return subprocess.CompletedProcess(argv, 1, stdout="")
subprocess.run = failing_run
try:
    res = library.owned("gog", p)
finally:
    subprocess.run = real_run
(ok if "error" in res and "titles" not in res else bad)(
    "a failed list is an error, not an empty library the panel would show as 'you own nothing'")
(ok if "error" in library.owned("steam", p) else bad)("an unknown store is refused")
PY

echo "== where a game can go"
pysuite "locations" <<'PY'
import os, sys, tempfile
sys.path.insert(0, sys.argv[1])
from novadeck_stores import locations

def ok(m): print(f"  ok   {m}")
def bad(m): print(f"  FAIL {m}")

tmp = tempfile.mkdtemp()
home = os.path.join(tmp, "home", "deck")
media = os.path.join(tmp, "run", "media", "deck")
os.makedirs(home)
os.makedirs(os.path.join(media, "CARD"))       # a mounted card
os.makedirs(os.path.join(media, "STALE"))      # udisks left the dir, the card is gone
os.symlink(os.path.join(media, "CARD"), os.path.join(media, "novadeck-link"))
mounted = {os.path.join(media, "CARD")}

vols = locations.volumes(home, media, is_mount=lambda p: p in mounted)
paths = [v["path"] for v in vols]
(ok if paths == [home, os.path.join(media, "CARD")] else bad)(
    f"the volumes are the home and each MOUNTED card, home first ({paths})")
(ok if all(isinstance(v["free"], int) and v["free"] > 0 for v in vols) else bad)(
    "each volume carries its free bytes")
(ok if [v["label"] for v in vols] == ["Internal", "CARD"] else bad)(
    f"a card is labelled by its filesystem label, the home as internal ({[v['label'] for v in vols]})")
(ok if locations.volumes(home, os.path.join(tmp, "nope"), is_mount=lambda p: True)[0]["path"] == home else bad)(
    "no /run/media at all is just the home, not an error")

(ok if locations.game_root(home, "epic") == os.path.join(home, "Games", "Epic")
    and locations.game_root(home, "gog") == os.path.join(home, "Games", "GOG") else bad)(
    "games go to <volume>/Games/<store>, outside Steam's own tree")
try:
    locations.game_root(home, "steam")
    bad("an unknown store has no game root")
except ValueError:
    ok("an unknown store has no game root")
PY

echo "== install, detached"
pysuite "install" <<'PY'
import json, os, subprocess, sys, tempfile
sys.path.insert(0, sys.argv[1])
from novadeck_stores import installs

def ok(m): print(f"  ok   {m}")
def bad(m): print(f"  FAIL {m}")

tmp = tempfile.mkdtemp()
home = os.path.join(tmp, "home")
os.makedirs(home)
p = {"NOVADECK_STORE_USER": "deck", "NOVADECK_STORE_UID": str(os.getuid()),
     "NOVADECK_STORE_HOME": os.path.join(tmp, "stores"),
     "LEGENDARY_CONFIG_PATH": os.path.join(tmp, "stores", "legendary"),
     "NOVADECK_GOGDL_AUTH": os.path.join(tmp, "stores", "gogdl", "auth.json"),
     "GOGDL_CONFIG_PATH": os.path.join(tmp, "stores", "gogdl"),
     "NOVADECK_STORE_INSTALLS": os.path.join(tmp, "stores", "installs.json")}
for d in ("legendary", "gogdl"):
    os.makedirs(os.path.join(tmp, "stores", d))
root = "/v/Games/Epic"

# -- argv --
(ok if installs.install_argv("epic", "Fir", root, p) ==
    ["legendary", "install", "Fir", "--base-path", root, "--game-folder", "Fir", "-y", "--skip-dlcs"] else bad)(
    "Epic installs with legendary, into <root>/<app name> (a folder we choose, not metadata's), "
    "-y so no prompt waits on a terminal nobody has")
(ok if installs.install_argv("gog", "123", "/v/Games/GOG", p) ==
    ["gogdl", "--auth-config-path", p["NOVADECK_GOGDL_AUTH"], "download", "123",
     "--platform", "windows", "--path", "/v/Games/GOG", "--skip-dlcs"] else bad)(
    "GOG downloads the Windows build with gogdl, auth path before the subcommand")
(ok if installs.info_argv("epic", "Fir", p) == ["legendary", "info", "Fir", "--json"]
    and installs.info_argv("gog", "123", p) ==
    ["gogdl", "--auth-config-path", p["NOVADECK_GOGDL_AUTH"], "info", "123", "--platform", "windows"] else bad)(
    "the size comes from each CLI's own info command")

# -- info parsing --
e = installs.parse_info("epic", "Fir", json.dumps({"game": {}, "manifest": {"disk_size": 5000}}))
(ok if e == {"disk_size": 5000, "folder": "Fir"} else bad)(f"Epic's size is manifest.disk_size ({e})")
g = installs.parse_info("gog", "123", json.dumps({"size": {"*": {"disk_size": 100, "download_size": 1},
                                                          "en-US": {"disk_size": 30}, "de-DE": {"disk_size": 50}},
                                                 "folder_name": "Some Game"}))
(ok if g == {"disk_size": 150, "folder": "Some Game"} else bad)(
    f"GOG's size is the common depots plus the largest language, and its folder comes from the build ({g})")
(ok if installs.parse_info("gog", "1", "nope") is None and installs.parse_info("epic", "F", "{}") is None else bad)(
    "info that does not parse is no answer")

for name in ("", ".", "..", "a/b", "/abs", "x\0y", "a\nb", "a\tb"):
    if installs.safe_component(name):
        bad(f"{name!r} is accepted as a game folder — a store's metadata would choose our rm -rf target")
        break
else:
    ok("a game folder is exactly one ordinary path component ('', '.', '..', '/', NUL and control "
       "characters refused — a newline would also forge a line in systemctl show)")
(ok if installs.safe_component("Some Game") else bad)("an ordinary folder name with a space is accepted")

# -- the unit --
argv = installs.unit_argv("epic", "Fir", ["legendary", "install", "Fir"], "/s/install.log", p)
sep = argv.index("--")
opts, cmd = argv[:sep], argv[sep + 1:]
(ok if "--unit=novadeck-store-install" in opts and "--collect" in opts else bad)(
    "one fixed unit name — one install at a time, and status finds it without a handle")
(ok if "--wait" not in opts and "--pipe" not in opts else bad)(
    "the download is detached: it outlives the plugin and the QAM")
(ok if "--property=KillSignal=SIGINT" in opts else bad)(
    "a stop is SIGINT — legendary's clean stop is CTRL-C, and it is the stop both CLIs resume from")
(ok if "--property=UMask=0022" in opts else bad)("game files get 0644/0755, not the token umask")
(ok if "--property=User=deck" in opts and not any(o.startswith("--property=RuntimeMaxSec") for o in opts) else bad)(
    "runs as deck, with no deadline (a download takes as long as it takes)")
(ok if cmd[:3] == ["sh", "-c", 'exec "$@" >"$0" 2>&1'] and cmd[3] == "/s/install.log"
    and cmd[4:] == ["legendary", "install", "Fir"] else bad)(
    "the log is opened by the shell AS deck, not by PID 1 as root in a directory deck owns")
(ok if any(o == "--description=novadeck-stores install epic:Fir" for o in opts) else bad)(
    "the unit names the game it is installing, which is how status knows")

# -- the flow, with systemd-run / systemctl / the CLIs faked --
calls = []
state = {"active": "inactive", "info": json.dumps({"manifest": {"disk_size": 5000}})}
real_run = subprocess.run
def fake_run(argv, **kw):
    calls.append(argv)
    if argv[0] == "systemctl":
        return subprocess.CompletedProcess(argv, 0, stdout=f"ActiveState={state['active']}\nDescription=x\n")
    cmd = argv[argv.index("--") + 1:] if "--" in argv else argv
    if cmd[0] in ("legendary", "gogdl") and "info" in cmd:
        return subprocess.CompletedProcess(argv, 0, stdout=state["info"])
    if cmd[:2] == ["sh", "-c"] and "cat" in cmd[2]:           # the record write, as deck
        with open(cmd[3], "w") as f:
            f.write(kw["input"])
        return subprocess.CompletedProcess(argv, 0)
    return subprocess.CompletedProcess(argv, 0, stdout="")

def run(fn, *a):
    calls.clear()
    subprocess.run = fake_run
    try:
        return fn(*a)
    finally:
        subprocess.run = real_run

vol = {"path": home, "label": "Internal", "free": 10_000}
vols = [vol]
res = run(installs.install, "epic", "Fir", "Fir Game", home, p, vols)
records = json.load(open(p["NOVADECK_STORE_INSTALLS"]))
rec = records.get("epic:Fir", {})
(ok if res.get("started") and rec.get("state") == "installing"
    and rec.get("path") == os.path.join(home, "Games", "Epic", "Fir") else bad)(
    f"an install records 'installing' with the exact path, then starts ({res}, {rec})")
starts = [c for c in calls if "--unit=novadeck-store-install" in c]
writes = [i for i, c in enumerate(calls) if "cat" in " ".join(c)]
(ok if len(starts) == 1 and writes and writes[0] < calls.index(starts[0]) else bad)(
    "the record is written BEFORE the unit starts — a crash between the two leaves a resumable record, "
    "never an orphan download")

state["active"] = "active"
res = run(installs.install, "epic", "Fir", "Fir Game", home, p, vols)
(ok if "error" in res and not [c for c in calls if "--unit=novadeck-store-install" in c] else bad)(
    "a second install while one runs is refused, and starts nothing")
state["active"] = "inactive"

state["info"] = json.dumps({"manifest": {"disk_size": 50_000}})
res = run(installs.install, "epic", "Big", "Big Game", home, p, vols)
(ok if "error" in res and "space" in res["error"] and not [c for c in calls if "--unit=novadeck-store-install" in c] else bad)(
    f"not enough free space is refused before anything downloads ({res})")
res = run(installs.install, "epic", "Fir", "Fir Game", home, p, vols)
(ok if res.get("started") else bad)(
    "resuming an install already recorded skips the free-space check — what is on disk counts against it")

state["info"] = json.dumps({"size": {"*": {"disk_size": 1}}, "folder_name": ".."})
calls_before = len(calls)
res = run(installs.install, "gog", "666", "Evil", home, p, vols)
(ok if "error" in res and not [c for c in calls if "--unit=novadeck-store-install" in c] else bad)(
    "a GOG build whose folder name is not one safe component is refused before it can be recorded")

res = run(installs.install, "epic", "Fir", "Fir Game", "/etc", p, vols)
(ok if "error" in res else bad)("a volume that is not the home or a mounted card is refused")
PY

echo "== status, stop, resume"
pysuite "status" <<'PY'
import json, os, subprocess, sys, tempfile
sys.path.insert(0, sys.argv[1])
from novadeck_stores import installs

def ok(m): print(f"  ok   {m}")
def bad(m): print(f"  FAIL {m}")

# -- progress, from the lines each CLI really logs --
lgd_log = ("[cli] INFO: Starting download...\n"
           "[DLManager] INFO: = Progress: 12.34% (123/456), Running for 00:00:10, ETA: 00:01:00\n"
           "[DLManager] INFO:  - Downloaded: 10.00 MiB, Written: 10.00 MiB\n"
           "[DLManager] INFO: = Progress: 56.78% (300/456), Running for 00:00:20, ETA: 00:00:30\n")
gog_log = ("[PROGRESS] INFO: = Progress: 3.50 100/2000, Running for: 00:00:01, ETA: 00:00:30\n"
           "[PROGRESS] INFO: = Downloaded: 1.00 MiB, Written: 1.00 MiB\n")
(ok if installs.progress(lgd_log) == 56.78 else bad)(f"legendary's LAST progress line wins ({installs.progress(lgd_log)})")
(ok if installs.progress(gog_log) == 3.5 else bad)(f"gogdl's progress line parses too ({installs.progress(gog_log)})")
(ok if installs.progress("nothing yet\n") is None else bad)("no progress line yet is no percentage, not 0%")

# -- the state table --
tmp = tempfile.mkdtemp()
S = os.path.join(tmp, "stores")
p = {"NOVADECK_STORE_USER": "deck", "NOVADECK_STORE_UID": str(os.getuid()), "NOVADECK_STORE_HOME": S,
     "LEGENDARY_CONFIG_PATH": os.path.join(S, "legendary"), "GOGDL_CONFIG_PATH": os.path.join(S, "gogdl"),
     "NOVADECK_GOGDL_AUTH": os.path.join(S, "gogdl", "auth.json"),
     "NOVADECK_STORE_INSTALLS": os.path.join(S, "installs.json")}
os.makedirs(os.path.join(S, "legendary"))
os.makedirs(os.path.join(S, "gogdl", "heroic_gogdl", "manifests"))
def rec(store, gid, state):
    return {"store": store, "id": gid, "title": gid, "path": f"/v/Games/{gid}", "state": state}
records = {"epic:Run": rec("epic", "Run", "installing"), "epic:Done": rec("epic", "Done", "installing"),
           "gog:7": rec("gog", "7", "installing"), "gog:8": rec("gog", "8", "installing"),
           "epic:Old": rec("epic", "Old", "installed")}
json.dump(records, open(p["NOVADECK_STORE_INSTALLS"], "w"))
json.dump({"Done": {}, "Old": {}}, open(os.path.join(S, "legendary", "installed.json"), "w"))
open(os.path.join(S, "gogdl", "heroic_gogdl", "manifests", "8"), "w").write("{}")
open(installs.log_path(p), "w").write(lgd_log)

unit = {"ActiveState": "active", "Description": "novadeck-stores install epic:Run"}
written = []
real_run = subprocess.run
def fake_run(argv, **kw):
    if argv[0] == "systemctl" and argv[1] == "show":
        return subprocess.CompletedProcess(argv, 0, stdout="".join(f"{k}={v}\n" for k, v in unit.items()))
    cmd = argv[argv.index("--") + 1:] if "--" in argv else argv
    if cmd[:2] == ["sh", "-c"] and "cat" in cmd[2]:
        written.append(json.loads(kw["input"]))
        return subprocess.CompletedProcess(argv, 0)
    return subprocess.CompletedProcess(argv, 0)
subprocess.run = fake_run
try:
    st = {f"{i['store']}:{i['id']}": i for i in installs.install_status(p)["installs"]}
finally:
    subprocess.run = real_run

(ok if st["epic:Run"]["state"] == "downloading" and st["epic:Run"].get("percent") == 56.78 else bad)(
    f"the game the unit is installing reads downloading, with its percentage ({st['epic:Run']})")
(ok if st["epic:Done"]["state"] == "installed" else bad)(
    "an Epic record legendary's installed.json now holds reads installed")
(ok if st["gog:8"]["state"] == "installed" and st["gog:7"]["state"] == "interrupted" else bad)(
    "a GOG record reads installed only once gogdl's manifest exists (written after completion), "
    "and interrupted without it")
(ok if st["epic:Old"]["state"] == "installed" else bad)("a finished install stays installed")
(ok if not written else bad)(
    "status writes nothing: it is derived from the CLIs' artifacts every time, so it needs no lock "
    "and never waits behind an uninstall")
(ok if all("percent" not in i for k, i in st.items() if k != "epic:Run") else bad)(
    "only the running install carries a percentage — the log belongs to whatever ran last")

unit["ActiveState"] = "inactive"
subprocess.run = fake_run
try:
    st = {f"{i['store']}:{i['id']}": i for i in installs.install_status(p)["installs"]}
finally:
    subprocess.run = real_run
(ok if st["epic:Run"]["state"] == "interrupted" else bad)(
    "an install whose unit is gone (stopped, failed, or a reboot) reads interrupted — resume is the same call")

# -- stop --
seen = []
def stop_run(argv, **kw):
    seen.append(argv)
    return subprocess.CompletedProcess(argv, 0)
subprocess.run = stop_run
try:
    installs.stop()
finally:
    subprocess.run = real_run
(ok if seen and seen[0][:3] == ["systemctl", "stop", "novadeck-store-install.service"] else bad)(
    "stop stops the unit by name (its KillSignal makes that a SIGINT)")

# -- a log the user swapped for a link is not read by root --
os.remove(installs.log_path(p))
os.symlink("/etc/hostname", installs.log_path(p))
(ok if installs.read_log_tail(p) == "" else bad)("the install log is read only if it is the user's own regular file")
PY

echo "== uninstall and its path guard"
pysuite "uninstall" <<'PY'
import json, os, subprocess, sys, tempfile
sys.path.insert(0, sys.argv[1])
from novadeck_stores import installs, locations

def ok(m): print(f"  ok   {m}")
def bad(m): print(f"  FAIL {m}")

tmp = tempfile.mkdtemp()
home = os.path.join(tmp, "home")
S = os.path.join(tmp, "stores")
p = {"NOVADECK_STORE_USER": "deck", "NOVADECK_STORE_UID": str(os.getuid()), "NOVADECK_STORE_HOME": S,
     "LEGENDARY_CONFIG_PATH": os.path.join(S, "legendary"), "GOGDL_CONFIG_PATH": os.path.join(S, "gogdl"),
     "NOVADECK_GOGDL_AUTH": os.path.join(S, "gogdl", "auth.json"),
     "NOVADECK_STORE_INSTALLS": os.path.join(S, "installs.json")}
os.makedirs(os.path.join(S, "legendary", "tmp"))
os.makedirs(os.path.join(S, "gogdl", "heroic_gogdl", "manifests"))
epic_root = locations.game_root(home, "epic")
gog_root = locations.game_root(home, "gog")
vols = [{"path": home, "label": "Internal", "free": 1}]

# -- the guard alone --
os.makedirs(os.path.join(gog_root, "Game"))
os.makedirs(os.path.join(epic_root, "Fir"))
os.makedirs(os.path.join(home, "elsewhere"))
os.symlink(os.path.join(home, "elsewhere"), os.path.join(gog_root, "Link"))
cases = {
    "the game root itself": gog_root,
    "the Games dir": os.path.dirname(gog_root),
    "the home": home,
    "'.' under the root": os.path.join(gog_root, "."),
    "'..' under the root": os.path.join(gog_root, ".."),
    "an empty folder name": gog_root + "/",
    "two levels down": os.path.join(gog_root, "Game", "sub"),
    "a symlink": os.path.join(gog_root, "Link"),
    "another store's root": os.path.join(epic_root, "Fir"),
    "a volume that is not mounted": "/run/media/deck/GONE/Games/GOG/Game",
}
# A store root swapped for a link: the path string is right, but it lands in another store's tree.
swapped = os.path.join(tmp, "home2")
os.makedirs(os.path.join(swapped, "Games"))
os.makedirs(os.path.join(tmp, "victim", "Game"))
os.symlink(os.path.join(tmp, "victim"), os.path.join(swapped, "Games", "GOG"))
vols = vols + [{"path": swapped, "label": "x", "free": 1}]
cases["a path through a symlinked store root"] = os.path.join(swapped, "Games", "GOG", "Game")
refused = [name for name, path in cases.items() if installs.deletable(path, "gog", vols) is None]
(ok if len(refused) == len(cases) else bad)(
    f"the uninstall guard refuses every unsafe path ({len(refused)}/{len(cases)}; "
    f"let through: {sorted(set(cases) - set(refused))})")
(ok if installs.deletable(os.path.join(gog_root, "Game"), "gog", vols) == os.path.join(gog_root, "Game") else bad)(
    "and accepts exactly <volume>/Games/<store>/<one folder>")

# -- the flow --
records = {
    "gog:1": {"store": "gog", "id": "1", "title": "G", "path": os.path.join(gog_root, "Game"), "state": "installed"},
    "epic:Fir": {"store": "epic", "id": "Fir", "title": "F", "path": os.path.join(epic_root, "Fir"), "state": "installed"},
    "epic:Half": {"store": "epic", "id": "Half", "title": "H", "path": os.path.join(epic_root, "Half"), "state": "installing"},
    "gog:bad": {"store": "gog", "id": "bad", "title": "B", "path": home, "state": "installed"},
    "gog:away": {"store": "gog", "id": "away", "title": "A", "path": "/run/media/deck/GONE/Games/GOG/X", "state": "installed"},
}
json.dump(records, open(p["NOVADECK_STORE_INSTALLS"], "w"))
json.dump({"Fir": {}}, open(os.path.join(S, "legendary", "installed.json"), "w"))
open(os.path.join(S, "gogdl", "heroic_gogdl", "manifests", "1"), "w").write("{}")
os.makedirs(os.path.join(epic_root, "Half"))
open(os.path.join(S, "legendary", "tmp", "Half.resume"), "w").write("x")
# legendary's manifests: one per game it prepared, named <app>_<platform>_<version>. Fir_DLC is
# another app whose name starts with Fir_; Oak is a game left installed.
lgd_manifests = os.path.join(S, "legendary", "manifests")
os.makedirs(lgd_manifests)
os.makedirs(os.path.join(S, "legendary", "metadata"))
for app in ("Fir", "Fir_DLC", "Half", "Oak"):
    open(os.path.join(S, "legendary", "metadata", f"{app}.json"), "w").write("{}")
for name in ("Fir_Windows_1.30.manifest", "Fir_1.0.manifest", "Fir_DLC_Windows_2.manifest",
             "Half_Windows_7.manifest", "Oak_Windows_3.manifest"):
    open(os.path.join(lgd_manifests, name), "w").write("x")

ran = []
unit = {"ActiveState": "inactive"}
real_run = subprocess.run
def fake_run(argv, **kw):
    if argv[0] == "systemctl":
        return subprocess.CompletedProcess(argv, 0, stdout="".join(f"{k}={v}\n" for k, v in unit.items()))
    cmd = argv[argv.index("--") + 1:] if "--" in argv else argv
    opts = argv[:argv.index("--")] if "--" in argv else []
    ran.append((cmd, opts))
    if cmd[:2] == ["sh", "-c"] and "cat" in cmd[2]:
        open(cmd[3], "w").write(kw["input"])
    elif cmd[:2] == ["rm", "-rf"]:
        real_run(cmd, check=True)
    elif cmd[:2] == ["rm", "-f"]:
        real_run(cmd, check=True)
    elif cmd[:2] == ["legendary", "uninstall"] and "--keep-files" not in cmd:
        real_run(["rm", "-rf", "--", os.path.join(epic_root, cmd[2])], check=True)
    return subprocess.CompletedProcess(argv, 0)

def run(fn, *a):
    ran.clear()
    subprocess.run = fake_run
    try:
        return fn(*a)
    finally:
        subprocess.run = real_run

res = run(installs.uninstall, "gog", "1", p, vols)
recs = json.load(open(p["NOVADECK_STORE_INSTALLS"]))
(ok if res.get("uninstalled") and not os.path.exists(os.path.join(gog_root, "Game")) else bad)(
    f"a GOG uninstall removes the game directory ({res})")
(ok if not os.path.exists(os.path.join(S, "gogdl", "heroic_gogdl", "manifests", "1")) and "gog:1" not in recs else bad)(
    "and gogdl's manifest and our record with it")
(ok if all("--property=User=deck" in o for c, o in ran if c[0] in ("rm", "legendary")) and ran else bad)(
    "every deletion runs as deck, never as root")
(ok if any(c[:2] == ["rm", "-rf"] and "--one-file-system" in c for c, o in ran) else bad)(
    "rm stays on the game's own filesystem")

res = run(installs.uninstall, "epic", "Fir", p, vols)
lgd = [c for c, o in ran if c[:3] == ["legendary", "uninstall", "Fir"]]
(ok if res.get("uninstalled") and lgd and "--keep-files" in lgd[0] and "--skip-uninstaller" in lgd[0] and "-y" in lgd[0]
    and any(c[:2] == ["rm", "-rf"] and c[-1] == os.path.join(epic_root, "Fir") for c, o in ran) else bad)(
    "a finished Epic game: legendary only drops its record (--keep-files) — it would delete the path in ITS "
    "installed.json, which the guard never saw — and the guarded rm removes the files")
left = sorted(os.listdir(lgd_manifests))
(ok if left == ["Fir_DLC_Windows_2.manifest", "Half_Windows_7.manifest", "Oak_Windows_3.manifest"] else bad)(
    f"and legendary's manifests of that game, every version and platform, but not Fir_DLC's ({left})")

res = run(installs.uninstall, "epic", "Half", p, vols)
(ok if res.get("uninstalled") and not os.path.exists(os.path.join(epic_root, "Half"))
    and not os.path.exists(os.path.join(S, "legendary", "tmp", "Half.resume")) else bad)(
    "an interrupted Epic install, which legendary never recorded, is removed with its resume file")
(ok if sorted(os.listdir(lgd_manifests)) == ["Fir_DLC_Windows_2.manifest", "Oak_Windows_3.manifest"] else bad)(
    "and the manifest legendary saved before its download began")

res = run(installs.uninstall, "gog", "bad", p, vols)
recs = json.load(open(p["NOVADECK_STORE_INSTALLS"]))
(ok if "error" in res and os.path.isdir(home) and "gog:bad" in recs
    and not any(c[:2] == ["rm", "-rf"] for c, o in ran) else bad)(
    "a record pointing somewhere unsafe is refused: nothing deleted, record kept")
res = run(installs.uninstall, "gog", "away", p, vols)
(ok if "error" in res and "gog:away" in json.load(open(p["NOVADECK_STORE_INSTALLS"])) else bad)(
    "a game on a card that is not inserted is not forgotten: refused, record kept")

unit.update(ActiveState="active", Description="novadeck-stores install gog:away")
res = run(installs.uninstall, "gog", "away", p, vols)
(ok if "error" in res and "install" in res["error"] else bad)("the game being downloaded cannot be uninstalled until stopped")
(ok if "error" in run(installs.uninstall, "gog", "nope", p, vols) else bad)("an unknown game is refused")
PY

echo "== the Proton prefix an uninstall leaves behind (issue #136)"
pysuite "prefix" <<'PY'
import os, subprocess, sys, tempfile
sys.path.insert(0, sys.argv[1])
from novadeck_stores import prefixes

def ok(m): print(f"  ok   {m}")
def bad(m): print(f"  FAIL {m}")

tmp = tempfile.mkdtemp()
steam = os.path.join(tmp, "Steam")
compat = os.path.join(steam, "steamapps", "compatdata")
good = os.path.join(compat, "3561440862")
os.makedirs(os.path.join(good, "pfx"))
open(os.path.join(good, "pfx", "system.reg"), "w").write("x" * 4096)
os.makedirs(os.path.join(tmp, "elsewhere"))
os.symlink(os.path.join(tmp, "elsewhere"), os.path.join(compat, "4000000000"))
# A Steam root swapped for a link: the string is right, the delete would land elsewhere.
linked = os.path.join(tmp, "Steam2")
os.makedirs(os.path.join(tmp, "victim", "steamapps", "compatdata", "7"))
os.symlink(os.path.join(tmp, "victim"), linked)
p = {"NOVADECK_STORE_USER": "deck", "NOVADECK_STORE_UID": str(os.getuid()),
     "LEGENDARY_CONFIG_PATH": os.path.join(tmp, "legendary"), "GOGDL_CONFIG_PATH": os.path.join(tmp, "gogdl")}

# -- the guard: exactly <steam>/steamapps/compatdata/<appid>, a real directory, no link anywhere --
(ok if prefixes.deletable(good, steam) == good else bad)("the guard accepts exactly <steam>/steamapps/compatdata/<appid>")
cases = {
    "compatdata itself": compat,
    "steamapps": os.path.dirname(compat),
    "the Steam root": steam,
    "a symlinked prefix": os.path.join(compat, "4000000000"),
    "a missing prefix": os.path.join(compat, "1"),
    "pfx inside the prefix": os.path.join(good, "pfx"),
    "a non-numeric name": os.path.join(compat, "x"),
    "a trailing slash": good + "/",
    "a path through a symlinked Steam root": os.path.join(linked, "steamapps", "compatdata", "7"),
}
refused = [n for n, path in cases.items() if prefixes.deletable(path, steam) is None]
(ok if len(refused) == len(cases) else bad)(
    f"and refuses every unsafe path ({len(refused)}/{len(cases)}; let through: {sorted(set(cases) - set(refused))})")
(ok if prefixes.compat_dir(steam, 3561440862) == good and prefixes.compat_dir(steam, "3561440862") is None
    and prefixes.compat_dir(steam, -1) is None and prefixes.compat_dir(steam, True) is None else bad)(
    "the path is built from a positive int appid only — a string or a bool is not an appid")

# -- status and drop run as the user; the fixture runs du/rm for real, minus systemd-run --
ran = []
real_run = subprocess.run
def fake_run(argv, **kw):
    cmd = argv[argv.index("--") + 1:] if "--" in argv else argv
    opts = argv[:argv.index("--")] if "--" in argv else []
    ran.append((cmd, opts))
    if cmd[0] in ("du", "rm"):
        return real_run(cmd, **{k: v for k, v in kw.items() if k in ("stdin", "stdout", "stderr", "text")})
    return subprocess.CompletedProcess(argv, 0)
def run(fn, *a):
    ran.clear()
    subprocess.run = fake_run
    try:
        return fn(*a)
    finally:
        subprocess.run = real_run

st = run(prefixes.status, p, 3561440862, steam)
(ok if st.get("exists") is True and st.get("bytes", 0) >= 4096 else bad)(f"an existing prefix reports its size ({st})")
(ok if ran and ran[0][0][0] == "du" and all("--property=User=deck" in o for c, o in ran) else bad)(
    f"the size is read by du, as deck ({ran})")
st = run(prefixes.status, p, 1, steam)
(ok if st == {"exists": False, "bytes": 0} and not ran else bad)(f"a missing prefix is reported without running anything ({st})")
st = run(prefixes.status, p, 4000000000, steam)
(ok if st == {"exists": False, "bytes": 0} and not ran else bad)(f"a link where the prefix should be counts as no prefix ({st})")

res = run(prefixes.drop, p, 4000000000, steam)
(ok if "error" in res and os.path.lexists(os.path.join(compat, "4000000000")) and os.path.isdir(os.path.join(tmp, "elsewhere"))
    and not ran else bad)(f"a symlinked prefix is refused: nothing runs, the target survives ({res})")
res = run(prefixes.drop, p, 1, steam)
(ok if "error" in res and not ran else bad)(f"a prefix that is not there is an error, not a silent success ({res})")
res = run(prefixes.drop, p, 3561440862, steam)
(ok if res == {"dropped": True} and not os.path.lexists(good) else bad)(f"drop removes the prefix ({res})")
(ok if any(c[:2] == ["rm", "-rf"] and "--one-file-system" in c and c[-1] == good for c, o in ran)
    and all("--property=User=deck" in o for c, o in ran) else bad)(
    f"the rm runs as deck, stays on one filesystem, and names exactly that path ({ran})")

# -- the shader cache: the same appid and guard, under shadercache, and taken on every uninstall --
shaders = os.path.join(steam, "steamapps", "shadercache")
cache = os.path.join(shaders, "4089089214")
os.makedirs(os.path.join(cache, "fozpipelinesv6"))
os.symlink(os.path.join(tmp, "elsewhere"), os.path.join(shaders, "4000000000"))
os.makedirs(os.path.join(compat, "4089089214"))
(ok if prefixes.deletable(os.path.join(compat, "4089089214"), steam, "shadercache") is None
    and prefixes.deletable(cache, steam) is None else bad)(
    "a guard for one kind never passes a folder of the other")
res = run(prefixes.drop_shader_cache, p, 4000000000, steam)
(ok if "error" in res and os.path.isdir(os.path.join(tmp, "elsewhere")) and not ran else bad)(
    f"a symlinked shader cache is refused: nothing runs, the target survives ({res})")
res = run(prefixes.drop_shader_cache, p, 1, steam)
(ok if res == {"dropped": False} and not ran else bad)(f"a game that never ran has no cache, and that is no error ({res})")
res = run(prefixes.drop_shader_cache, p, 4089089214, steam)
(ok if res == {"dropped": True} and not os.path.lexists(cache) and os.path.isdir(os.path.join(compat, "4089089214"))
    and any(c[:2] == ["rm", "-rf"] and c[-1] == cache for c, o in ran) and all("--property=User=deck" in o for c, o in ran)
    else bad)(f"drop_shader_cache removes exactly the cache, as deck, and leaves the prefix ({res})")
PY

echo "== the backend contract"
pysuite "backend" <<'PY'
import asyncio, os, sys, types
sys.path.insert(0, sys.argv[1])
sys.modules["decky"] = types.SimpleNamespace(logger=types.SimpleNamespace(info=lambda *a: None))
sys.path.insert(0, os.path.join(sys.argv[1], ".."))
import main

def ok(m): print(f"  ok   {m}")
def bad(m): print(f"  FAIL {m}")

methods = ["owned", "drives", "install", "install_status", "stop_install", "uninstall", "prefix_status"]
missing = [m for m in methods if not asyncio.iscoroutinefunction(getattr(main.Plugin, m, None))]
(ok if not missing else bad)(f"the backend exposes what milestone 7's panel will call (missing: {missing})")
plugin = main.Plugin()
res = [asyncio.run(plugin.owned("steam")), asyncio.run(plugin.install("steam", "x", "t", "/")),
       asyncio.run(plugin.uninstall("steam", "x"))]
(ok if all("error" in r for r in res) else bad)("an unknown store is refused before anything runs")
PY

grep -q 'test-store-install.sh' "$ROOT/Makefile" \
  && ok "this suite is wired into make test (a suite nothing runs is documentation)" \
  || bad "tests/test-store-install.sh is not in the Makefile test target"

printf '\n%s: %d passed, %d failed, %d skipped\n' "$(basename "$0")" "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
