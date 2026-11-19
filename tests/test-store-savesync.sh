#!/usr/bin/env bash
# Offline checks for the GOG cloud-save sync, before launch and after exit
# (.claude/plans/gog-galaxy-comet.plan.md, phase 3 steps 4 and 7; design §6).
#
#   tests/test-store-savesync.sh
#
# WHY THIS FILE EXISTS. Before a cloud-enabled GOG game starts, game-launch asks gogdl what a sync
# would do (save-sync --dry-run) and acts on the verdict per save location: a cloud-only change is
# downloaded after the local folder is backed up; a local-only change waits for the post-exit
# upload; a conflict is the user's call (step 6), and without an answer nothing is synced. A
# wrong row here overwrites a save the user wanted, or launches the game on a stale one. And
# nothing here may hold the launch hostage: every failure, and an offline device, must end in the
# game starting.
#
# gogdl is stubbed (the `run` parameter), so this runs offline. WHAT IT CANNOT PROVE: that GOG's
# cloud answers the way the stub does. That is the phase 3 HW gate.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/rootfs/overlay/usr/lib/novadeck"

out="$(python3 - "$LIB" <<'PY'
import json, os, pathlib, signal, subprocess, sys, tempfile, threading, time
sys.path.insert(0, sys.argv[1])

def ok(m): print(f"  ok   {m}")
def bad(m): print(f"  FAIL {m}")
def check(cond, m): (ok if cond else bad)(m)

import novadeck_savesync as ss
ss.log = lambda m: logs.append(m)
logs = []

tmp = pathlib.Path(tempfile.mkdtemp(prefix="savesync."))
home = tmp / "stores"
(home / "gogdl").mkdir(parents=True)
paths = {"NOVADECK_STORE_HOME": str(home), "NOVADECK_GOGDL_AUTH": str(home / "gogdl" / "auth.json"),
         "GOGDL_CONFIG_PATH": str(home / "gogdl")}
prefix = tmp / "compatdata" / "77" / "pfx"
docs = prefix / "drive_c" / "users" / "steamuser" / "Documents"
docs.mkdir(parents=True)
install = tmp / "Games" / "GOG" / "Another World"
install.mkdir(parents=True)
TOKEN = "gog:1207658845"

def galaxy(cloud, appid="77"):
    row = {"token": TOKEN, "gid": "1207658845", "clientId": "4984", "comet": True,
           "install": str(install), "cloud": cloud}
    (home / "galaxy.json").write_text(json.dumps({appid: row}))

def aw(enabled=True, locations=None):
    galaxy({"enabled": enabled,
            "locations": locations if locations is not None else
            [{"name": "saves", "location": "<?DOCUMENTS?>/Another World"}]})

save_dir = docs / "Another World"

def local(files):
    save_dir.mkdir(parents=True, exist_ok=True)
    for name, text in files.items():
        (save_dir / name).write_text(text)

def plan(action, **kw):
    return {"action": action, "local": {"files": 1, "newest": 1795040000.0},
            "cloud": {"files": 1, "newest": 1795050000.0}, "updated_local": [], "updated_cloud": [],
            "not_existing_locally": [], "not_existing_remotely": [], **kw}

class Gogdl:
    """Stands in for subprocess.run(gogdl ...). verdicts: location path -> dry-run JSON."""
    def __init__(self, verdicts=None, rc=0, real_rc=0, raise_on=None, stamp="1795060000.5", stderr=""):
        self.calls, self.verdicts, self.rc, self.real_rc = [], verdicts or {}, rc, real_rc
        self.raise_on, self.stamp, self.envs, self.stderr = raise_on, stamp, [], stderr
    def __call__(self, argv, **kw):
        self.calls.append(argv)
        self.envs.append(kw.get("env") or {})
        path = argv[argv.index("save-sync") + 1]
        if self.raise_on and self.raise_on in argv:
            raise subprocess.TimeoutExpired(argv, kw.get("timeout"))
        if "--dry-run" in argv:
            v = self.verdicts.get(path)
            out = v if isinstance(v, str) else json.dumps(v)
            return subprocess.CompletedProcess(argv, self.rc, stdout=out, stderr=self.stderr)
        if self.real_rc == 0 and ("--skip-upload" in argv or "--force-download" in argv):
            pathlib.Path(path).mkdir(parents=True, exist_ok=True)
            (pathlib.Path(path) / "progression.dat").write_text("from the cloud")
        return subprocess.CompletedProcess(argv, self.real_rc, stdout=self.stamp, stderr=self.stderr)
    def real(self):
        return [c for c in self.calls if "--dry-run" not in c]

def run(gogdl, choose=None, clock=None, appid="77"):
    os.environ.pop(ss.STARTED_ENV, None)
    logs.clear()
    kw = {"paths": paths, "prefix": str(prefix), "run": gogdl, "choose": choose}
    if clock is not None:
        kw["clock"] = clock
    return ss.pre_launch(appid, **kw)

def stamps():
    f = home / "gogdl" / ss.TIMESTAMPS
    return json.loads(f.read_text()) if f.exists() else {}

def backups(name="saves"):
    d = home / ss.BACKUPS / TOKEN / name
    return sorted(p.name for p in d.iterdir()) if d.exists() else []

SP = str(save_dir)

print("== when nothing is asked of gogdl")
aw(enabled=False)
g = Gogdl()
check(run(g) == [] and not g.calls, "cloud sync off for the game: gogdl is never called")
galaxy(None)
check(run(g) == [] and not g.calls, "a row with no cloud data: nothing")
aw()
check(run(g, appid="999") == [] and not g.calls, "an appid with no row: nothing")
check(ss.pre_launch(None, paths=paths, prefix=str(prefix), run=g) == [] and not g.calls, "no appid: nothing")
os.environ.pop("STEAM_COMPAT_DATA_PATH", None)
logs.clear()
check(ss.pre_launch("77", paths=paths, run=g) == [] and not g.calls and any("Proton" in m for m in logs),
      f"a launch with no Proton prefix at all (no STEAM_COMPAT_DATA_PATH): nothing, and it says why ({logs})")
os.environ.pop(ss.STARTED_ENV, None)
fresh = tmp / "compatdata" / "88"
os.environ["STEAM_COMPAT_DATA_PATH"] = str(fresh)
g = Gogdl({str(fresh / "pfx" / "drive_c" / "users" / "steamuser" / "Documents" / "Another World"):
           plan("download", local={"files": 0, "newest": None})})
res = ss.pre_launch("77", paths=paths, run=g)
check(res and res[0]["did"] == "downloaded" and len(g.real()) == 1,
      "a FIRST launch (the prefix not created yet) still downloads: files written before Proton "
      f"creates the prefix survive its setup (HW 2026-11-19, plan step 5) ({res})")
os.environ.pop("STEAM_COMPAT_DATA_PATH", None)
(home / "gogdl" / ss.TIMESTAMPS).unlink()  # the checks below start from a game never synced

print("== the dry run")
local({"progression.dat": "local"})
g = Gogdl({SP: plan("none")})
res = run(g)
dry = g.calls[0] if g.calls else []
check(dry[:1] == [ss.GOGDL] and dry[dry.index("save-sync") + 1:dry.index("save-sync") + 3] == [SP, "1207658845"]
      and dry[dry.index("--auth-config-path") + 1] == paths["NOVADECK_GOGDL_AUTH"]
      and ["--os", "windows"] == dry[dry.index("--os"):dry.index("--os") + 2]
      and ["--name", "saves"] == dry[dry.index("--name"):dry.index("--name") + 2]
      and ["--ts", "0"] == dry[dry.index("--ts"):dry.index("--ts") + 2] and dry[-1] == "--dry-run",
      f"it asks gogdl for the resolved folder, the game id, the location's name, and --ts 0 when never synced ({dry})")
check(len(g.calls) == 1 and res == [{"name": "saves", "action": "none", "did": "nothing"}],
      f"none: nothing more ({res})")
env = g.envs[0]
check(env.get("GOGDL_CONFIG_PATH") == paths["GOGDL_CONFIG_PATH"] and "LD_PRELOAD" not in env
      and "LD_LIBRARY_PATH" not in env,
      "gogdl gets its config dir, and not the game's LD_PRELOAD / LD_LIBRARY_PATH")

g = Gogdl({SP: plan("upload", updated_local=["progression.dat"])})
res = run(g)
check(len(g.calls) == 1 and res[0]["did"] == "nothing" and stamps() == {},
      f"only local changed: nothing now, the upload is after exit ({res})")

print("== only the cloud changed: back up, then download")
local({"progression.dat": "local v1"})
g = Gogdl({SP: plan("download", updated_cloud=["progression.dat"])})
res = run(g, clock=lambda: 1795060000.0)
real = g.real()
check(len(real) == 1 and "--skip-upload" in real[0] and real[0][real[0].index("--ts") + 1] == "0",
      f"one real sync with --skip-upload ({real})")
check(res[0]["did"] == "downloaded" and (save_dir / "progression.dat").read_text() == "from the cloud",
      f"the cloud's save is in place ({res})")
b = backups()
check(len(b) == 1 and (home / ss.BACKUPS / TOKEN / "saves" / b[0] / "progression.dat").read_text() == "local v1",
      f"the local folder was backed up FIRST, its old content intact ({b})")
check(stamps() == {f"{TOKEN}:saves": "1795060000.5"},
      f"the timestamp stored is exactly what the sync printed ({stamps()})")
g = Gogdl({SP: plan("none")})
run(g)
check(g.calls[0][g.calls[0].index("--ts") + 1] == "1795060000.5", "and the next dry run uses it")

print("== a conflict")
for f in (home / "gogdl" / ss.TIMESTAMPS,):
    f.unlink()
local({"progression.dat": "local v2"})
conflict = plan("conflict", updated_local=["progression.dat"], updated_cloud=["progression.dat"])
g = Gogdl({SP: conflict})
res = run(g)
check(not g.real() and res[0]["did"] == "kept-local" and stamps() == {}
      and (save_dir / "progression.dat").read_text() == "local v2",
      f"no answer (no picker yet, a timeout, Decky absent): keep local, sync nothing ({res})")
asked = []
def answer(value):
    def choose(appid, index, name, verdict):
        asked.append((appid, index, name, verdict["local"]["newest"], verdict["cloud"]["newest"]))
        return value
    return choose
n = len(backups())
g = Gogdl({SP: conflict})
res = run(g, choose=answer("cloud"), clock=lambda: 1795070000.0)
check(asked and asked[-1] == ("77", 0, "saves", 1795040000.0, 1795050000.0),
      f"the chooser is asked with the appid, the location's index and name, and both sides' dates ({asked})")
check(len(g.real()) == 1 and "--force-download" in g.real()[0] and res[0]["did"] == "downloaded"
      and len(backups()) == n + 1,
      f"answer cloud: back up, then --force-download ({res}, {backups()})")
local({"progression.dat": "local v3"})
n = len(backups())
g = Gogdl({SP: conflict})
res = run(g, choose=answer("local"))
check(len(g.real()) == 1 and "--force-upload" in g.real()[0] and res[0]["did"] == "uploaded"
      and len(backups()) == n and (save_dir / "progression.dat").read_text() == "local v3",
      f"answer local: --force-upload, no backup needed, the local save untouched ({res})")
check(stamps().get(f"{TOKEN}:saves") == "1795060000.5", "and its printed timestamp is stored")

print("== backups")
for i in range(ss.SAVE_BACKUPS_KEPT + 3):
    local({"progression.dat": f"round {i}"})
    run(Gogdl({SP: plan("download")}), clock=lambda i=i: 1795080000.0 + i * 3600)
kept = backups()
check(len(kept) == ss.SAVE_BACKUPS_KEPT, f"only the last {ss.SAVE_BACKUPS_KEPT} backups are kept ({len(kept)})")
newest = home / ss.BACKUPS / TOKEN / "saves" / kept[-1] / "progression.dat"
check(newest.read_text() == f"round {ss.SAVE_BACKUPS_KEPT + 2}", "and the newest is the last local state")
same = 1795080000.0 + 50 * 3600  # after every backup above, so neither is pruned
local({"progression.dat": "same second, first"})
run(Gogdl({SP: plan("download")}), clock=lambda: same)
local({"progression.dat": "same second, second"})
run(Gogdl({SP: plan("download")}), clock=lambda: same)
last2 = backups()[-2:]
texts = sorted((home / ss.BACKUPS / TOKEN / "saves" / b / "progression.dat").read_text() for b in last2)
check(len(backups()) == ss.SAVE_BACKUPS_KEPT and texts == ["same second, first", "same second, second"],
      f"two backups in the same second do not overwrite each other ({last2})")
for f in save_dir.iterdir():
    f.unlink()
n = sorted(backups())
g = Gogdl({SP: plan("download", local={"files": 0, "newest": None})})
res = run(g)
check(res[0]["did"] == "downloaded" and sorted(backups()) == n,
      f"an empty local folder needs no backup, and the download goes ahead ({res})")
blocker = home / ss.BACKUPS / TOKEN / "blocked"
blocker.parent.mkdir(parents=True, exist_ok=True)
blocker.write_text("a file where the location's backup dir would go")
galaxy({"enabled": True, "locations": [{"name": "blocked", "location": "<?DOCUMENTS?>/Another World"}]})
local({"progression.dat": "keep me"})
g = Gogdl({SP: plan("download")})
res = run(g)
check(not g.real() and res[0]["did"] == "failed" and (save_dir / "progression.dat").read_text() == "keep me",
      f"a backup that fails stops the download: nothing is overwritten without one ({res})")
aw()

print("== failures never hold the launch")
g = Gogdl({SP: plan("download")}, rc=1)
res = run(g)
check(not g.real() and res[0]["did"] == "skipped", f"a dry run that fails (offline): skipped ({res})")
g = Gogdl({SP: "not json"})
res = run(g)
check(not g.real() and res[0]["did"] == "skipped", f"a dry run that prints garbage: skipped ({res})")
g = Gogdl({SP: plan("download")}, raise_on="--dry-run")
res = run(g)
check(not g.real() and res[0]["did"] == "skipped", f"a dry run that times out: skipped, no raise ({res})")
before = stamps()
g = Gogdl({SP: plan("download")}, real_rc=2)
res = run(g)
check(res[0]["did"] == "failed" and stamps() == before, f"a real sync that fails stores no timestamp ({res})")

print("== several locations")
other = docs / "Other"
galaxy({"enabled": True, "locations": [
    {"name": "mac", "location": "<?APPLICATION_SUPPORT?>/x"},
    {"name": "saves", "location": "<?DOCUMENTS?>/Another World"},
    {"name": "other", "location": "<?DOCUMENTS?>/Other"}]})
g = Gogdl({SP: plan("download"), str(other): plan("none")}, rc=0)
res = run(g)
check([r["name"] for r in res] == ["mac", "saves", "other"] and res[0]["did"] == "skipped"
      and "APPLICATION_SUPPORT" in res[0].get("reason", ""),
      f"a refused location is skipped with the resolver's reason, and the others still run ({res})")
check(f"{TOKEN}:saves" in stamps() and f"{TOKEN}:other" not in stamps(),
      "each location keeps its own timestamp")
ticks = iter([0.0, 0.0, ss.BUDGET + 1, ss.BUDGET + 2, ss.BUDGET + 3, ss.BUDGET + 4])
g = Gogdl({SP: plan("none"), str(other): plan("none")})
res = run(g, clock=lambda: next(ticks, ss.BUDGET + 9))
check(res[-1]["did"] == "skipped" and "budget" in res[-1].get("reason", ""),
      f"past the time budget the rest is skipped, so an offline launch waits at most that long ({res})")
fake_now = [0.0]
def slow_user(appid, index, name, verdict):
    fake_now[0] += ss.BUDGET * 2  # the user reads the question for a long time
    return None
g = Gogdl({SP: conflict, str(other): plan("none")})
galaxy({"enabled": True, "locations": [{"name": "saves", "location": "<?DOCUMENTS?>/Another World"},
                                        {"name": "other", "location": "<?DOCUMENTS?>/Other"}]})
res = run(g, choose=slow_user, clock=lambda: fake_now[0])
check([r["did"] for r in res] == ["kept-local", "nothing"],
      f"time spent waiting on the USER is not budget: the next location still syncs ({res})")

print("== the question, over the request spool (the launch's half)")
spool = home / ss.REQUEST_DIR
def plugin_side(answer_text, take=True, delay=0.3):
    """Stand in for the plugin: take the question, then write the answer."""
    def go():
        deadline = time.time() + 5
        while time.time() < deadline and not list(spool.glob("*.savepick")):
            time.sleep(0.02)
        names = [q.name for q in spool.glob("*.savepick")]
        seen.extend(names)
        if not take:
            return
        for q in spool.glob("*.savepick"):
            q.unlink()
        time.sleep(delay)
        if answer_text is not None:
            appid, index = names[0].split(".")[:2]
            (spool / f"{appid}.{index}{ss.ANSWER_SUFFIX}").write_text(answer_text)
    t = threading.Thread(target=go)
    t.start()
    return t
verdict = plan("conflict", local={"files": 1, "newest": 1795040000.9}, cloud={"files": 2, "newest": 1795050000.2})
for text, want in (("cloud", "cloud"), ("local", "local"), ("", None), ("garbage", None)):
    seen = []
    t = plugin_side(text)
    got = ss.ask(home, "77", 1, verdict, take_timeout=3, answer_timeout=3, poll=0.02)
    t.join()
    check(got == want, f"the answer {text!r} reads as {want!r}")
check(seen == ["77.1.1795040000.1795050000.savepick"],
      f"the question's NAME carries appid, location index and both dates, digits only ({seen})")
check(not list(spool.glob("*.saveanswer")), "the answer is consumed")
seen = []
(spool / f"77.1{ss.ANSWER_SUFFIX}").write_text("cloud")  # a stale answer from an earlier launch
t = plugin_side(None)
got = ss.ask(home, "77", 1, verdict, take_timeout=3, answer_timeout=0.3, poll=0.02)
t.join()
check(got is None, "a stale answer from an earlier launch is never this launch's answer")
seen = []
t = plugin_side(None, take=False)
got = ss.ask(home, "77", 1, verdict, take_timeout=0.3, answer_timeout=3, poll=0.02)
t.join()
check(got is None and not list(spool.glob("*.savepick")),
      "a question nobody takes (Decky not running) is withdrawn, and reads as no answer")
ss_ask, asked_with = ss.ask, []
ss.ask = lambda h, a, i, v, **kw: (asked_with.append((str(h), a, i)), "local")[1]
aw()
g = Gogdl({SP: conflict})
os.environ.pop(ss.STARTED_ENV, None)
res = ss.pre_launch("77", paths=paths, prefix=str(prefix), run=g)
ss.ask = ss_ask
check(asked_with == [(str(home), "77", 0)] and res[0]["did"] == "uploaded",
      f"by default a conflict ASKS over the spool (store home, appid, location index) ({asked_with}, {res})")

print("== after the game exits: upload what changed on this device (post_exit, step 7)")
KEY = f"{TOKEN}:saves"
def after(gogdl, where=str(prefix), appid="77", clock=None):
    logs.clear()
    kw = {"paths": paths, "run": gogdl}
    if clock is not None:
        kw["clock"] = clock
    return ss.post_exit(appid, where, **kw)
aw()
(home / "gogdl" / ss.TIMESTAMPS).unlink(missing_ok=True)
for f in spool.glob("*"):
    f.unlink()
local({"progression.dat": "played"})
g = Gogdl({SP: plan("upload", updated_local=["progression.dat"])})
res = after(g)
real = g.real()
check(g.calls and "--dry-run" in g.calls[0] and g.calls[0][g.calls[0].index("--ts") + 1] == "0",
      "it asks gogdl first (--dry-run, the stored timestamp): one set of rules for both ends of a launch")
check(len(real) == 1 and "--skip-download" in real[0]
      and res == [{"name": "saves", "action": "upload", "did": "uploaded"}],
      f"only this device changed: one real sync, --skip-download ({res})")
check(stamps() == {KEY: "1795060000.5"}, f"the timestamp the upload printed is stored ({stamps()})")
check((save_dir / "progression.dat").read_text() == "played", "the local save is untouched")
check(any("upload -> uploaded" in m for m in logs), f"the outcome is logged ({logs})")
g = Gogdl({SP: plan("upload")})
after(g)
check(g.calls[0][g.calls[0].index("--ts") + 1] == "1795060000.5", "and the next sync starts from it")
for action, extra, why in (
        ("conflict", {}, "both changed (Decide later, or the cloud changed mid-game): nothing, "
                         "the next launch asks"),
        ("download", {}, "only the cloud changed: nothing now, the next launch downloads it, after a backup"),
        ("download", {"local": {"files": 0, "newest": None}},
         "a local folder left empty: nothing (gogdl downloads into an empty side despite --skip-download)"),
        ("none", {}, "nothing changed: nothing")):
    before = stamps()
    g = Gogdl({SP: plan(action, **extra)})
    res = after(g)
    check(not g.real() and res and res[0]["did"] in ("nothing", "next-launch") and stamps() == before
          and not list(spool.glob("*.savepick")),
          f"{why} — never a download after exit, never a question ({res})")
check(after(Gogdl({SP: conflict}))[0]["did"] == "next-launch", "a conflict reads as left for the next launch")
aw(enabled=False)
g = Gogdl({SP: plan("upload")})
check(after(g) == [] and not g.calls,
      "cloud sync turned off (read at exit, so a toggle flipped mid-game counts): gogdl is never called")
aw()
g = Gogdl({SP: plan("upload")})
check(after(g, where=None) == [] and not g.calls, "no prefix (not a Proton launch): nothing")
check(after(g, appid=None) == [] and not g.calls, "no appid: nothing")
os.environ[ss.STARTED_ENV] = "77"
g = Gogdl({SP: plan("upload")})
check(after(g)[0]["did"] == "uploaded",
      "the once-per-launch marker of the PRE-launch sync does not stop the upload after exit")
os.environ.pop(ss.STARTED_ENV, None)
before = stamps()
res = after(Gogdl({SP: plan("upload")}, rc=1))
check(res[0]["did"] == "skipped" and stamps() == before, f"a dry run that fails (offline): skipped ({res})")
res = after(Gogdl({SP: plan("upload")}, raise_on="--dry-run"))
check(res[0]["did"] == "skipped", f"a dry run that times out: skipped, no raise ({res})")
res = after(Gogdl({SP: plan("upload")}, real_rc=2))
check(res[0]["did"] == "failed" and stamps() == before,
      f"an upload that fails stores no timestamp, so the next exit tries again ({res})")
galaxy({"enabled": True, "locations": [{"name": "saves", "location": "<?DOCUMENTS?>/Another World"},
                                        {"name": "other", "location": "<?DOCUMENTS?>/Other"}]})
ticks = iter([0.0, 0.0, ss.BUDGET + 1, ss.BUDGET + 2, ss.BUDGET + 3])
res = after(Gogdl({SP: plan("none"), str(other): plan("upload")}),
            clock=lambda: next(ticks, ss.BUDGET + 9))
check(res[-1]["did"] == "skipped" and "budget" in res[-1].get("reason", ""),
      f"past the time budget the rest is skipped: an exit offline ends in bounded time ({res})")
check(ss.POST_EXIT_LIMIT >= ss.LOCK_WAIT + ss.BUDGET + 2 * ss.CALL_TIMEOUT,
      "POST_EXIT_LIMIT bounds the whole upload: the lock wait, the budget, and one location's two calls "
      "started just before it ran out")
aw()

print("== one sync at a time: the upload after exit and the next launch's sync never overlap")
import fcntl
lockf = home / ss.LOCK_FILE
def hold():
    f = open(lockf, "a")
    fcntl.flock(f, fcntl.LOCK_EX)
    return f
def free():
    with open(lockf, "a") as f:
        try:
            fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return True
        except OSError:
            return False
h = hold()
g = Gogdl({SP: plan("download")})
os.environ.pop(ss.STARTED_ENV, None)
logs.clear()
t0 = time.monotonic()
res = ss.pre_launch("77", paths=paths, prefix=str(prefix), run=g, choose=None, lock_wait=0.3)
check(res == [] and not g.calls and time.monotonic() - t0 < 2 and any("still" in m for m in logs),
      f"a launch that cannot get the lock in time syncs nothing, says why, and starts the game ({logs})")
g = Gogdl({SP: plan("upload")})
res = ss.post_exit("77", str(prefix), paths=paths, run=g, lock_wait=0.3)
check(res == [] and not g.calls, "an upload that cannot get the lock does nothing (the next exit retries)")
threading.Timer(0.3, h.close).start()
g = Gogdl({SP: plan("none")})
os.environ.pop(ss.STARTED_ENV, None)
t0 = time.monotonic()
res = ss.pre_launch("77", paths=paths, prefix=str(prefix), run=g, choose=None, lock_wait=5)
check(res and res[0]["did"] == "nothing" and time.monotonic() - t0 >= 0.25,
      f"a launch right after an exit WAITS for that upload, then syncs ({res})")
check(free(), "the lock is released when the sync ends: the game, exec'd after it, never holds it")
ss.post_exit("77", str(prefix), paths=paths, run=Gogdl({SP: plan("upload")}))
check(free(), "and when the upload ends")
nolock = tmp / "elsewhere"
(nolock / "gogdl").mkdir(parents=True)
(nolock / "galaxy.json").write_text(json.dumps({"5": {"token": "x", "gid": "5"}}))
os.environ.pop(ss.STARTED_ENV, None)
ss.pre_launch("5", paths={**paths, "NOVADECK_STORE_HOME": str(nolock)}, prefix=str(prefix), run=g)
check(not (nolock / ss.LOCK_FILE).exists(), "a launch with nothing to sync never touches the lock")
real_flock = fcntl.flock
def broken_flock(fd, op):
    raise OSError(37, "No locks available")  # ENOLCK: an error, not a holder
ss.fcntl.flock = broken_flock
g = Gogdl({SP: plan("none")})
os.environ.pop(ss.STARTED_ENV, None)
logs.clear()
t0 = time.monotonic()
res = ss.pre_launch("77", paths=paths, prefix=str(prefix), run=g, choose=None, lock_wait=5)
ss.fcntl.flock = real_flock
check(res == [] and time.monotonic() - t0 < 1 and any("lock" in m for m in logs),
      f"a lock that ERRORS (not one held) is not waited on: the launch goes ahead at once, unsynced, logged ({logs})")

print("== the upload unit's entry point (novadeck_savesync.py post-exit APPID PREFIX)")
SS = str(pathlib.Path(sys.argv[1]) / "novadeck_savesync.py")
w = subprocess.run([sys.executable, SS, "post-exit", "77"], capture_output=True, text=True, timeout=30)
check(w.returncode == 1 and "usage" in w.stderr, "a command line without the prefix is refused")
marker = tmp / "upload.done"
code = (f"import sys, time; sys.path.insert(0, {sys.argv[1]!r}); import novadeck_savesync as ss\n"
        "def slow(appid, prefix):\n"
        "    time.sleep(1.0)\n"
        f"    open({str(marker)!r}, 'w').write(appid + ' ' + prefix)\n"
        "    return []\n"
        "ss.post_exit = slow\n"
        "sys.exit(ss.main(['x', 'post-exit', '77', '/pfx']))\n")
for sig in (signal.SIGTERM, signal.SIGINT):
    marker.unlink(missing_ok=True)
    w = subprocess.Popen([sys.executable, "-c", code], stderr=subprocess.PIPE, text=True)
    time.sleep(0.5)
    w.send_signal(sig)
    _, err = w.communicate(timeout=10)
    check(w.returncode == 0 and marker.exists() and marker.read_text() == "77 /pfx",
          f"{signal.Signals(sig).name} (a logout stopping the unit) waits for the upload to end ({w.returncode}, {err[-80:]!r})")

print("== why gogdl failed, in words the page can show")
OFFLINE = (
    "[SAVES] INFO: Local files: 2\n"
    "Traceback (most recent call last):\n"
    "  File \"/usr/lib/python3.14/site-packages/gogdl/saves.py\", line 244, in get_auth_ids\n"
    "requests.exceptions.ConnectionError: HTTPSConnectionPool(host='content-system.gog.com', port=443): "
    "Max retries exceeded with url: /products/1207658845/os/windows/builds?generation=2 (Caused by "
    "NameResolutionError(\"Failed to resolve 'content-system.gog.com' ([Errno -3] Temporary failure in "
    "name resolution)\"))\n")
aw()
local({"progression.dat": "offline"})
res = run(Gogdl({SP: plan("download")}, rc=1, stderr=OFFLINE))
check(res[0]["did"] == "skipped" and res[0]["reason"] == "GOG could not be reached (no network?)",
      f"offline before a launch: the reason says GOG could not be reached, not 'exited 1' ({res})")
res = after(Gogdl({SP: plan("upload")}, rc=1, stderr=OFFLINE))
check(res[0]["did"] == "skipped" and res[0]["reason"] == "GOG could not be reached (no network?)",
      f"...and after an exit ({res})")
res = after(Gogdl({SP: plan("upload")}, real_rc=1, stderr=OFFLINE))
check(res[0]["did"] == "failed" and "could not be reached" in res[0]["reason"],
      f"the network going away between the dry run and the upload: the same words ({res})")
LEAK = ("[SAVES] INFO: Uploading files\n"
        "ValueError: bad answer from https://auth.gog.com/token?client_id=1&client_secret=SEKRIT"
        "&refresh_token=TOKEN123 (status 500)\n"
        "[SAVES] INFO: Done\n")
res = after(Gogdl({SP: plan("upload")}, real_rc=2, stderr=LEAK))
reason = res[0].get("reason", "")
check(res[0]["did"] == "failed" and "bad answer from https://auth.gog.com/token" in reason
      and "exited 2" in reason,
      f"another failure: its last meaningful stderr line (not a trailing INFO log line) ({reason!r})")
check("SEKRIT" not in reason and "TOKEN123" not in reason and "client_secret" not in reason,
      "...with every URL's query string cut: gogdl puts the client secret and refresh token there")
res = after(Gogdl({SP: plan("upload")}, real_rc=2, stderr="E" * 900))
check(len(res[0].get("reason", "")) <= 200, "...and cut to length")
res = after(Gogdl({SP: plan("upload")}, rc=1, stderr=""))
check(res[0]["reason"] == "dry run exited 1", f"no stderr at all: the exit status, as before ({res})")
aw()

print("== what the last sync did, kept for the game page (save-status.json)")
def last():
    f = home / "gogdl" / ss.STATUS
    return json.loads(f.read_text()).get(TOKEN) if f.exists() else None
aw()
local({"progression.dat": "x"})
run(Gogdl({SP: plan("none")}), clock=lambda: 1795090000.0)
check(last() == {"at": 1795090000.0, "phase": "launch",
                 "outcomes": [{"name": "saves", "action": "none", "did": "nothing"}]},
      f"a launch's sync records when, which end, and each location's outcome ({last()})")
after(Gogdl({SP: plan("upload")}, real_rc=2), clock=lambda: 1795090100.0)
st = last() or {}
check(st.get("phase") == "exit" and st.get("at") == 1795090100.0 and st["outcomes"][0]["did"] == "failed"
      and "exited 2" in st["outcomes"][0].get("reason", ""),
      f"so does the upload after exit, its failure's REASON kept, not only logged ({st})")
check(sorted(json.loads((home / "gogdl" / ss.STATUS).read_text())) == [TOKEN], "one record per game, replaced each time")
h = hold()
os.environ.pop(ss.STARTED_ENV, None)
ss.pre_launch("77", paths=paths, prefix=str(prefix), run=Gogdl({SP: plan("none")}), choose=None,
              lock_wait=0.2, clock=lambda: 1795090200.0)
h.close()
st = last() or {}
check(st.get("phase") == "launch" and st.get("outcomes") == [] and "still running" in st.get("reason", ""),
      f"a launch that could not get the lock records why it synced nothing ({st})")
before = last()
aw(enabled=False)
run(Gogdl({SP: plan("none")}))
after(Gogdl({SP: plan("upload")}))
check(last() == before, "cloud sync off: nothing synced, so nothing recorded")
aw()
status_file = home / "gogdl" / ss.STATUS
status_file.unlink()
status_file.mkdir()
res = run(Gogdl({SP: plan("none")}))
status_file.rmdir()
check(res and res[0]["did"] == "nothing" and any("status" in m for m in logs),
      f"a status that cannot be written is logged and changes nothing else ({logs})")

print("== once per launch")
aw()
g = Gogdl({SP: plan("none")})
run(g)
n = len(g.calls)
second = ss.pre_launch("77", paths=paths, prefix=str(prefix), run=g)
check(second == [] and len(g.calls) == n and os.environ.get(ss.STARTED_ENV) == "77",
      "a second game-launch in the same chain (launch options + the in-tool shim) syncs nothing")

src = pathlib.Path(sys.argv[1], "game-launch").read_text()
main = src[src.index("def main"):]
check("import novadeck_savesync" in src and "novadeck_savesync = None" in src,
      "game-launch imports the sync softly: a missing helper costs the sync, not the game")
check(main.index("novadeck_dostarget.swap") < main.index("novadeck_savesync.pre_launch")
      < main.index("novadeck_gogsession.start"),
      "the sync runs after the DOSBox swap and BEFORE Comet starts (gogdl may rewrite auth.json, Comet reads it once)")
blk = main[main.index("if novadeck_savesync is not None"):main.index("if novadeck_gogsession is not None")]
check("except Exception" in blk.split("novadeck_savesync.pre_launch", 1)[1],
      "a failing sync never blocks the launch (its own handler)")
PY
)"
rc=$?
printf '%s\n' "$out"
PASS=$(grep -c '^  ok ' <<<"$out" || true)
FAIL=$(grep -c '^  FAIL' <<<"$out" || true)
[ "$rc" -eq 0 ] || { echo "  FAIL the save-sync checks crashed (exit $rc) — every check after the crash never ran"; FAIL=$((FAIL + 1)); }

echo
echo "savesync: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
