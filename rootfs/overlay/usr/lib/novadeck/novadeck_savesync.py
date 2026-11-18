"""Pre-launch GOG cloud-save sync: bring the cloud's saves down before the game reads them.

    pre_launch(appid)   called by game-launch, after the DOS swap and before Comet starts

For a GOG game with cloud saves on, each save location (galaxy.json's `cloud.locations`, written
by the novadeck-stores plugin) is resolved inside the game's Proton prefix (novadeck_savepaths)
and gogdl is asked what a sync WOULD do (`save-sync --dry-run`, our patch 0001). Then, per
location (.claude/plans/gog-galaxy-comet.plan.md design §6):

  none / upload   nothing now: a local change is uploaded after the game exits (step 7).
  download        only the cloud changed (or the local folder is empty): back the local folder
                  up, then `save-sync --skip-upload`.
  conflict        both changed. `choose(appid, name, verdict)` answers "cloud" (back up, then
                  --force-download), "local" (--force-upload) or None: keep local and sync
                  nothing. The picker that asks the user is step 6; until then, and on its
                  timeout, the answer is None.

The timestamp stored per `token:location` is EXACTLY what a real sync prints. GOG dates a cloud
file by its upload time, and gogdl prints its timestamp after that, so any earlier value would
read a file just uploaded as changed in the cloud (HW 2026-11-18).

A download overwrites saves, so it never runs without a backup of the folder it replaces
(`<store home>/save-backups/<token>/<location>/<UTC time>/`, the last SAVE_BACKUPS_KEPT kept); a
backup that fails stops that download.

Before Comet: gogdl may rewrite auth.json when it fetches the game's credentials, and Comet reads
it once at start. A prefix that does not exist yet (a first launch) is skipped: whether files
written before Proton creates it survive is plan step 5.

Like the rest of game-launch, nothing here may stop the game. Every gogdl call has a timeout, the
whole sync a BUDGET, and every failure is logged and skipped.
"""
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time

import novadeck_savepaths
from novadeck_gogsession import store_env

GOGDL = "/usr/bin/gogdl"
GALAXY_FILE = "galaxy.json"
TIMESTAMPS = "save-timestamps.json"  # in gogdl's config dir, beside its own state
BACKUPS = "save-backups"             # in the store home
SAVE_BACKUPS_KEPT = 5
CALL_TIMEOUT = 30   # one gogdl call: a credential fetch, a listing, a few save files
BUDGET = 90         # the whole pre-launch sync; an offline device waits at most about this
# Set once this launch has synced, so a second game-launch in the same chain (launch options AND
# the in-tool shim of a baked Proton) does not sync again.
STARTED_ENV = "NOVADECK_SAVES_SYNCED"
# The game's own loader environment, which gogdl (a host Python program) must not inherit.
DROPPED_ENV = ("LD_PRELOAD", "LD_LIBRARY_PATH")
PROG = "game-launch"


def log(message):
    print(f"{PROG}: saves: {message}", file=sys.stderr, flush=True)


def _read_json(path):
    try:
        return json.loads(pathlib.Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def cloud_row(home, appid):
    """This appid's galaxy.json row when its cloud sync is on and names locations, else None."""
    table = _read_json(pathlib.Path(home) / GALAXY_FILE)
    row = table.get(str(appid)) if isinstance(table, dict) else None
    cloud = row.get("cloud") if isinstance(row, dict) else None
    if not (isinstance(cloud, dict) and cloud.get("enabled") is True
            and isinstance(cloud.get("locations"), list) and cloud["locations"]
            and isinstance(row.get("gid"), str) and isinstance(row.get("token"), str)):
        return None
    return row


def _write_json(path, data):
    """Replace path atomically, 0600 (the store home's files are the user's alone)."""
    path = pathlib.Path(path)
    fd, tmp = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=1)
        os.replace(tmp, path)
    except BaseException:
        pathlib.Path(tmp).unlink(missing_ok=True)
        raise


class Session:
    """What every location of one launch shares: paths, gogdl's environment, the stored stamps."""

    def __init__(self, appid, row, paths, prefix, run, choose, clock):
        self.appid, self.row, self.prefix = str(appid), row, prefix
        self.run, self.choose, self.clock = run, choose, clock
        self.home = pathlib.Path(paths["NOVADECK_STORE_HOME"])
        self.auth = paths["NOVADECK_GOGDL_AUTH"]
        self.stamp_file = pathlib.Path(paths["GOGDL_CONFIG_PATH"]) / TIMESTAMPS
        self.env = {k: v for k, v in os.environ.items() if k not in DROPPED_ENV}
        self.env["GOGDL_CONFIG_PATH"] = paths["GOGDL_CONFIG_PATH"]

    def stamps(self):
        data = _read_json(self.stamp_file)
        return data if isinstance(data, dict) else {}

    def store_stamp(self, key, value):
        _write_json(self.stamp_file, {**self.stamps(), key: value})

    def gogdl(self, path, name, ts, *flags):
        """(exit status, stdout) of one save-sync call, or (None, why) when it could not run."""
        argv = [GOGDL, "--auth-config-path", self.auth, "save-sync", path, self.row["gid"],
                "--os", "windows", "--name", name, "--ts", ts, *flags]
        try:
            done = self.run(argv, capture_output=True, text=True, timeout=CALL_TIMEOUT,
                            env=self.env, check=False)
        except subprocess.TimeoutExpired:
            return None, f"gogdl timed out after {CALL_TIMEOUT}s"
        except OSError as exc:
            return None, f"gogdl did not run ({exc.strerror})"
        return done.returncode, (done.stdout or "").strip()

    def backup(self, name, path):
        """Copy the location's folder aside before a download replaces it. True when done or when
        there is nothing to keep."""
        src = pathlib.Path(path)
        if not src.is_dir() or not any(src.iterdir()):
            return True
        root = self.home / BACKUPS / self.row["token"] / name
        base = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime(self.clock()))
        dest, n = root / base, 1
        while dest.exists():
            dest, n = root / f"{base}-{n}", n + 1
        try:
            root.mkdir(parents=True, exist_ok=True)
            shutil.copytree(src, dest, symlinks=True)
        except OSError as exc:
            log(f"{name}: backup failed ({exc}); not downloading over the local save")
            return False
        for old in sorted(p for p in root.iterdir() if p.is_dir())[:-SAVE_BACKUPS_KEPT]:
            shutil.rmtree(old, ignore_errors=True)
        return True


def _real_sync(s, key, name, path, ts, flag, did):
    rc, out = s.gogdl(path, name, ts, flag)
    if rc != 0:
        return {"did": "failed", "reason": f"save-sync {flag} exited {rc}: {out}"[:200]}
    try:
        stamp = out.splitlines()[-1].strip()
        float(stamp)
    except (IndexError, ValueError):
        return {"did": "failed", "reason": f"save-sync {flag} printed no timestamp"}
    s.store_stamp(key, stamp)
    return {"did": did}


def _download(s, key, name, path, ts, flag):
    if not s.backup(name, path):
        return {"did": "failed", "reason": "the local folder could not be backed up"}
    return _real_sync(s, key, name, path, ts, flag, "downloaded")


def sync_location(s, location):
    """One location's pre-launch outcome: {name, action?, did, reason?}."""
    name = location.get("name") if isinstance(location, dict) else None
    if not isinstance(name, str) or not name:
        return {"name": str(name), "did": "skipped", "reason": "a location with no name"}
    path, reason = novadeck_savepaths.resolve(location.get("location"), s.row.get("install") or "",
                                              s.prefix)
    if path is None:
        return {"name": name, "did": "skipped", "reason": reason}
    key = f"{s.row['token']}:{name}"
    ts = s.stamps().get(key, "0")
    rc, out = s.gogdl(path, name, ts, "--dry-run")
    try:
        verdict = json.loads(out) if rc == 0 else None
        action = verdict["action"] if isinstance(verdict, dict) else None
    except (ValueError, KeyError, TypeError):
        action = None
    if action is None:
        why = out if rc is None else f"dry run exited {rc}" if rc else "dry run printed no verdict"
        return {"name": name, "did": "skipped", "reason": why}
    head = {"name": name, "action": action}
    if action == "download":
        return {**head, **_download(s, key, name, path, ts, "--skip-upload")}
    if action == "conflict":
        answer = s.choose(s.appid, name, verdict) if s.choose else None
        if answer == "cloud":
            return {**head, **_download(s, key, name, path, ts, "--force-download")}
        if answer == "local":
            return {**head, **_real_sync(s, key, name, path, ts, "--force-upload", "uploaded")}
        return {**head, "did": "kept-local"}
    return {**head, "did": "nothing"}


def pre_launch(appid, paths=None, prefix=None, run=subprocess.run, choose=None, clock=time.time):
    """Sync this launch's cloud saves down, if any. Returns one outcome per location ([] when there
    is nothing to do)."""
    if not appid or os.environ.get(STARTED_ENV):
        return []
    paths = store_env() if paths is None else paths
    home = paths.get("NOVADECK_STORE_HOME")
    row = cloud_row(home, appid) if home else None
    if row is None:
        return []
    if prefix is None:
        compat = os.environ.get("STEAM_COMPAT_DATA_PATH")
        prefix = os.path.join(compat, "pfx") if compat else None
    if not prefix or not os.path.isdir(os.path.join(prefix, "drive_c")):
        log(f"{row['token']}: no prefix yet (first launch); cloud saves not synced before it")
        return []
    os.environ[STARTED_ENV] = str(appid)
    s = Session(appid, row, paths, prefix, run, choose, clock)
    deadline = clock() + BUDGET
    outcomes = []
    for location in row["cloud"]["locations"]:
        if clock() > deadline:
            name = location.get("name") if isinstance(location, dict) else None
            outcomes.append({"name": str(name), "did": "skipped", "reason": f"past the {BUDGET}s budget"})
            continue
        outcome = sync_location(s, location)
        outcomes.append(outcome)
        log(f"{outcome['name']}: {outcome.get('action', '-')} -> {outcome['did']}"
            + (f" ({outcome['reason']})" if outcome.get("reason") else ""))
    return outcomes
