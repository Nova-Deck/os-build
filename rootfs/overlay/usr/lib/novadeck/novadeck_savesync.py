"""GOG cloud-save sync: the cloud's saves down before a game reads them, this device's up after.

    pre_launch(appid)           called by game-launch, after the DOS swap and before Comet starts
    post_exit(appid, prefix)    once the game has exited: `novadeck_savesync.py post-exit APPID
                                PREFIX`, the unit the novadeck_gogsession watcher hands it to

For a GOG game with cloud saves on, each save location (galaxy.json's `cloud.locations`, written
by the novadeck-stores plugin) is resolved inside the game's Proton prefix (novadeck_savepaths)
and gogdl is asked what a sync WOULD do (`save-sync --dry-run`, our patch 0001). Then, per
location (.claude/plans/gog-galaxy-comet.plan.md design §6):

  none / upload   nothing now: a local change is uploaded after the game exits (step 7).
  download        only the cloud changed (or the local folder is empty): back the local folder
                  up, then `save-sync --skip-upload`.
  conflict        both changed: the user is asked (ask(), below). "cloud" backs up, then
                  --force-download; "local" is --force-upload; no answer (Decide later, B, a
                  timeout, Decky not running) keeps local and syncs nothing.

THE QUESTION goes over the request spool the DOS version picker uses (novadeck_dostarget): ask()
creates `<store home>/requests/<appid>.<location index>.<local newest>.<cloud newest>.savepick`,
digits only, because the plugin (root) never reads a file the user owns; the FILENAME is the
whole message. The plugin takes it, looks the location's name up in its own galaxy.json, shows
"Which saves?" with both dates, and writes `<appid>.<location index>.saveanswer` back: `cloud`,
`local`, or empty. Not taken within TAKE_TIMEOUT means the plugin is not running. Time spent
waiting on the USER does not count against BUDGET, so a slow answer never costs the game's
other locations their sync.

The timestamp stored per `token:location` is EXACTLY what a real sync prints. GOG dates a cloud
file by its upload time, and gogdl prints its timestamp after that, so any earlier value would
read a file just uploaded as changed in the cloud (HW 2026-11-18).

A download overwrites saves, so it never runs without a backup of the folder it replaces
(`<store home>/save-backups/<token>/<location>/<UTC time>/`, the last SAVE_BACKUPS_KEPT kept); a
backup that fails stops that download.

Before Comet: gogdl may rewrite auth.json when it fetches the game's credentials, and Comet reads
it once at start. A prefix that does not exist yet (a first launch) is synced too: the resolver
uses the layout Proton is about to create, and files written there before Proton creates the
prefix survive its setup (HW 2026-11-19, plan step 5: Proton's copy_pfx only adds files that are
missing). That is what brings a new device's saves down before the game first starts.

AFTER EXIT (post_exit): the same dry run, and only an "upload" verdict (this device changed, the
cloud did not) is acted on, with `save-sync --skip-download`; its printed timestamp is stored. A
conflict is left for the next launch to ask about, which is what Decide later promises; a cloud
change waits for the next launch's download, which backs up first. So nothing is ever downloaded
after exit, and gogdl's "an empty side is downloaded into whatever the skip flags say" never runs
there. It runs in a unit of its own (novadeck-gog-upload-<pid>), outside the game's process tree,
and outside the Comet unit a relaunch stops: stopping that never waits on an upload, nor cuts one
short. (A relaunch's own pre-launch sync does wait for it, through the lock below.)

ONE SYNC AT A TIME: both ends hold LOCK_FILE (flock, in the store home) for their whole run. Quit
and press Play at once, and the new launch's dry run would otherwise race the upload still in
flight, and read half an upload as a cloud change. The launch waits up to LOCK_WAIT, then starts
the game unsynced. The lock fd is close-on-exec and closed before return: the game never holds it.

Like the rest of game-launch, nothing here may stop the game. Every gogdl call has a timeout, the
whole sync a BUDGET, and every failure is logged and skipped.
"""
import contextlib
import fcntl
import json
import os
import pathlib
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time

import novadeck_savepaths
from novadeck_storeenv import read_json, store_env

GOGDL = "/usr/bin/gogdl"
GALAXY_FILE = "galaxy.json"
TIMESTAMPS = "save-timestamps.json"  # in gogdl's config dir, beside its own state
# Beside it: what each game's last sync did, {token: {at, phase, outcomes, reason?}}. The game page
# (novadeck-stores cloud_saves.py) shows it: a reason computed here must reach the screen.
STATUS = "save-status.json"
BACKUPS = "save-backups"             # in the store home
SAVE_BACKUPS_KEPT = 5
CALL_TIMEOUT = 30   # one gogdl call: a credential fetch, a listing, a few save files
BUDGET = 90         # the whole pre-launch sync; an offline device waits at most about this
MAX_REASON = 200   # a reason is one line on the game page
OFFLINE = "GOG could not be reached (no network?)"
# What requests/urllib3 put in a traceback when there is no route to GOG.
NETWORK_MARKERS = ("ConnectionError", "NameResolutionError", "Temporary failure in name resolution",
                   "Max retries exceeded", "Network is unreachable", "ConnectTimeout", "ReadTimeout")
LOG_LINE = re.compile(r"^\[\w+\] (DEBUG|INFO|WARNING):")  # gogdl's own logger, not the failure
QUERY = re.compile(r"\?[^\s'\")]*")                        # a URL's query string
LOCK_FILE = ".savesync.lock"  # in the store home
LOCK_WAIT = BUDGET            # a launch waits this long for an upload still in flight
# The upload after exit, at most: the lock wait, the budget, and one location's two calls started
# just before it ran out. Its unit's stop timeout is sized from it.
POST_EXIT_LIMIT = LOCK_WAIT + BUDGET + 2 * CALL_TIMEOUT
SELF = os.path.abspath(__file__)
# Set once this launch has synced, so a second game-launch in the same chain (launch options AND
# the in-tool shim of a baked Proton) does not sync again.
STARTED_ENV = "NOVADECK_SAVES_SYNCED"
# The game's own loader environment, which gogdl (a host Python program) must not inherit.
DROPPED_ENV = ("LD_PRELOAD", "LD_LIBRARY_PATH")
REQUEST_DIR = "requests"
PICK_SUFFIX = ".savepick"
ANSWER_SUFFIX = ".saveanswer"
CHOICES = ("cloud", "local")
TAKE_TIMEOUT = 10.0      # the plugin takes a request within a beat or two; else it is not running
ANSWER_TIMEOUT = 120.0   # then the user has this long; past it, nothing is synced
POLL = 0.2
ASK = object()           # pre_launch's default chooser: ask the user (tests pass their own)
PROG = "game-launch"


def log(message):
    print(f"{PROG}: saves: {message}", file=sys.stderr, flush=True)


def _wait(predicate, timeout, poll):
    end = time.monotonic() + timeout
    while not predicate():
        if time.monotonic() >= end:
            return False
        time.sleep(poll)
    return True


def _stamp(side):
    newest = side.get("newest") if isinstance(side, dict) else None
    return int(newest) if isinstance(newest, (int, float)) and newest > 0 else 0


def ask(home, appid, index, verdict, take_timeout=TAKE_TIMEOUT, answer_timeout=ANSWER_TIMEOUT,
        poll=POLL):
    """"cloud", "local", or None when nobody answered (plugin down, Decide later, timeout).
    Never raises: a failed ask is an unanswered one."""
    spool = pathlib.Path(home) / REQUEST_DIR
    name = f"{appid}.{index}.{_stamp(verdict.get('local'))}.{_stamp(verdict.get('cloud'))}"
    request = spool / f"{name}{PICK_SUFFIX}"
    answer = spool / f"{appid}.{index}{ANSWER_SUFFIX}"
    try:
        spool.mkdir(mode=0o700, exist_ok=True)
        answer.unlink(missing_ok=True)  # a stale answer from an earlier launch is not this one's
        os.close(os.open(request, os.O_CREAT | os.O_WRONLY | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600))
    except OSError as exc:
        log(f"could not ask which saves to keep ({exc}); keeping local")
        return None
    log("asking which saves to keep")
    if not _wait(lambda: not request.exists(), take_timeout, poll):
        request.unlink(missing_ok=True)
        log("the NovaDeck Stores plugin did not take the question; keeping local")
        return None
    if not _wait(answer.exists, answer_timeout, poll):
        log("no answer in time; keeping local")
        return None
    try:
        text = answer.read_text(encoding="utf-8").strip()
        answer.unlink(missing_ok=True)
    except OSError:
        return None
    return text if text in CHOICES else None


def _acquire(fd, timeout, poll):
    """True once the lock is ours; False when it stayed held past timeout, or cannot be taken at
    all (an error is not a holder, so it is not waited on)."""
    end = time.monotonic() + timeout
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return True
        except BlockingIOError:  # EWOULDBLOCK: another sync holds it
            if time.monotonic() >= end:
                return False
            time.sleep(poll)
        except OSError as exc:
            log(f"the sync lock could not be taken ({exc})")
            return False


@contextlib.contextmanager
def _locked(home, timeout, poll=POLL):
    """Hold the store home's sync lock while the block runs; yields False when it could not be had
    within timeout. Closing the fd releases it."""
    try:
        fd = os.open(pathlib.Path(home) / LOCK_FILE,
                     os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    except OSError as exc:
        log(f"the sync lock could not be opened ({exc})")
        yield False
        return
    try:
        yield _acquire(fd, timeout, poll)
    finally:
        os.close(fd)


def failure(stderr):
    """Why a gogdl call failed, from its stderr, in words the game page can show; "" when it
    said nothing. gogdl lets a network error escape as a traceback (requests' ConnectionError on
    its first call), which reads as OFFLINE. Anything else is its last line that is not one of its
    own log lines, with every URL's query string cut (gogdl's token refresh carries the client
    secret and the refresh token there) and cut to MAX_REASON."""
    text = stderr or ""
    if any(marker in text for marker in NETWORK_MARKERS):
        return OFFLINE
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    last = next((line for line in reversed(lines) if not LOG_LINE.match(line)), "")
    return QUERY.sub("", last)[:MAX_REASON]


def cloud_row(home, appid):
    """This appid's galaxy.json row when its cloud sync is on and names locations, else None."""
    table = read_json(pathlib.Path(home) / GALAXY_FILE)
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
        self.waited = 0.0  # seconds spent waiting on the user, which the budget does not count
        self.home = pathlib.Path(paths["NOVADECK_STORE_HOME"])
        self.auth = paths["NOVADECK_GOGDL_AUTH"]
        self.stamp_file = pathlib.Path(paths["GOGDL_CONFIG_PATH"]) / TIMESTAMPS
        self.status_file = pathlib.Path(paths["GOGDL_CONFIG_PATH"]) / STATUS
        self.env = {k: v for k, v in os.environ.items() if k not in DROPPED_ENV}
        self.env["GOGDL_CONFIG_PATH"] = paths["GOGDL_CONFIG_PATH"]

    def stamps(self):
        data = read_json(self.stamp_file)
        return data if isinstance(data, dict) else {}

    def store_stamp(self, key, value):
        _write_json(self.stamp_file, {**self.stamps(), key: value})

    def record(self, phase, outcomes, reason=None):
        """Keep this run's outcome for the game page; a failure to is logged, nothing more."""
        entry = {"at": self.clock(), "phase": phase, "outcomes": outcomes,
                 **({"reason": reason} if reason else {})}
        current = read_json(self.status_file)
        try:
            _write_json(self.status_file,
                        {**(current if isinstance(current, dict) else {}), self.row["token"]: entry})
        except OSError as exc:
            log(f"the sync status for the game page was not written ({exc})")

    def gogdl(self, path, name, ts, *flags):
        """(exit status, stdout, why it failed) of one save-sync call; (None, why, why) when it
        could not run. `why` is "" on success, else words the game page can show (failure())."""
        argv = [GOGDL, "--auth-config-path", self.auth, "save-sync", path, self.row["gid"],
                "--os", "windows", "--name", name, "--ts", ts, *flags]
        try:
            done = self.run(argv, capture_output=True, text=True, timeout=CALL_TIMEOUT,
                            env=self.env, check=False)
        except subprocess.TimeoutExpired:
            why = f"gogdl timed out after {CALL_TIMEOUT}s"
            return None, why, why
        except OSError as exc:
            why = f"gogdl did not run ({exc.strerror})"
            return None, why, why
        why = "" if done.returncode == 0 else failure(done.stderr)
        return done.returncode, (done.stdout or "").strip(), why

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
    rc, out, why = s.gogdl(path, name, ts, flag)
    if rc is None or why == OFFLINE:
        return {"did": "failed", "reason": why}
    if rc != 0:
        return {"did": "failed", "reason": f"save-sync {flag} exited {rc}{f': {why}' if why else ''}"[:MAX_REASON]}
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


def _choose(s, index, name, verdict):
    if s.choose is None:
        return None
    started = s.clock()
    try:
        return s.choose(s.appid, index, name, verdict)
    finally:
        s.waited += s.clock() - started


def _classify(s, location):
    """Resolve one location and ask gogdl what a sync would do (both ends of a launch use this).
    Returns (outcome, None) when the location is skipped, else (None, (name, path, key, ts,
    verdict))."""
    name = location.get("name") if isinstance(location, dict) else None
    if not isinstance(name, str) or not name:
        return {"name": str(name), "did": "skipped", "reason": "a location with no name"}, None
    path, reason = novadeck_savepaths.resolve(location.get("location"), s.row.get("install") or "",
                                              s.prefix)
    if path is None:
        return {"name": name, "did": "skipped", "reason": reason}, None
    key = f"{s.row['token']}:{name}"
    ts = s.stamps().get(key, "0")
    rc, out, why = s.gogdl(path, name, ts, "--dry-run")
    try:
        verdict = json.loads(out) if rc == 0 else None
        action = verdict["action"] if isinstance(verdict, dict) else None
    except (ValueError, KeyError, TypeError):
        action = None
    if action is None:
        if rc is None or why == OFFLINE:
            reason = why
        elif rc:
            reason = f"dry run exited {rc}{f': {why}' if why else ''}"[:MAX_REASON]
        else:
            reason = "dry run printed no verdict"
        return {"name": name, "did": "skipped", "reason": reason}, None
    return None, (name, path, key, ts, verdict)


def sync_location(s, index, location):
    """One location's pre-launch outcome: {name, action?, did, reason?}."""
    skipped, found = _classify(s, location)
    if skipped is not None:
        return skipped
    name, path, key, ts, verdict = found
    action = verdict["action"]
    head = {"name": name, "action": action}
    if action == "download":
        return {**head, **_download(s, key, name, path, ts, "--skip-upload")}
    if action == "conflict":
        answer = _choose(s, index, name, verdict)
        if answer == "cloud":
            return {**head, **_download(s, key, name, path, ts, "--force-download")}
        if answer == "local":
            return {**head, **_real_sync(s, key, name, path, ts, "--force-upload", "uploaded")}
        return {**head, "did": "kept-local"}
    return {**head, "did": "nothing"}


def upload_location(s, index, location):
    """One location's after-exit outcome: only "upload" (this device alone changed) syncs."""
    skipped, found = _classify(s, location)
    if skipped is not None:
        return skipped
    name, path, key, ts, verdict = found
    head = {"name": name, "action": verdict["action"]}
    if verdict["action"] == "upload":
        return {**head, **_real_sync(s, key, name, path, ts, "--skip-download", "uploaded")}
    if verdict["action"] == "conflict":
        return {**head, "did": "next-launch"}
    return {**head, "did": "nothing"}


def _each_location(s, step, label):
    """step() over the row's locations within BUDGET (time waiting on the user not counted)."""
    deadline = s.clock() + BUDGET
    outcomes = []
    for index, location in enumerate(s.row["cloud"]["locations"]):
        if s.clock() - s.waited > deadline:
            name = location.get("name") if isinstance(location, dict) else None
            outcomes.append({"name": str(name), "did": "skipped", "reason": f"past the {BUDGET}s budget"})
            continue
        outcome = step(s, index, location)
        outcomes.append(outcome)
        log(f"{label}{outcome['name']}: {outcome.get('action', '-')} -> {outcome['did']}"
            + (f" ({outcome['reason']})" if outcome.get("reason") else ""))
    return outcomes


def pre_launch(appid, paths=None, prefix=None, run=subprocess.run, choose=ASK, clock=time.time,
               lock_wait=LOCK_WAIT):
    """Sync this launch's cloud saves down, if any. Returns one outcome per location ([] when there
    is nothing to do). `choose` answers a conflict; by default the user is asked (ask()), None
    never asks."""
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
    if not prefix:
        log(f"{row['token']}: not a Proton launch (no STEAM_COMPAT_DATA_PATH); saves not synced")
        return []
    os.environ[STARTED_ENV] = str(appid)
    if choose is ASK:
        choose = lambda a, i, n, v: ask(home, a, i, v)  # noqa: E731 - resolved at call time
    s = Session(appid, row, paths, prefix, run, choose, clock)
    with _locked(home, lock_wait) as held:
        if not held:
            why = "an upload from the last exit is still running; saves not synced"
            log(f"{row['token']}: {why}")
            s.record("launch", [], why)
            return []
        outcomes = _each_location(s, sync_location, "")
        s.record("launch", outcomes)
        return outcomes


def post_exit(appid, prefix, paths=None, run=subprocess.run, clock=time.time, lock_wait=LOCK_WAIT):
    """Upload what changed on this device since the last sync, once the game has exited. Returns
    one outcome per location ([] when there is nothing to do). The cloud toggle is read now, so
    one turned off mid-game is respected."""
    if not appid or not prefix:
        return []
    paths = store_env() if paths is None else paths
    home = paths.get("NOVADECK_STORE_HOME")
    row = cloud_row(home, appid) if home else None
    if row is None:
        return []
    s = Session(appid, row, paths, prefix, run, None, clock)
    with _locked(home, lock_wait) as held:
        if not held:
            why = (f"the sync lock was not had within {lock_wait}s; nothing uploaded "
                   "(the next exit tries again)")
            log(f"after exit: {row['token']}: {why}")
            s.record("exit", [], why)
            return []
        outcomes = _each_location(s, upload_location, "after exit: ")
        s.record("exit", outcomes)
        return outcomes


def main(argv):
    """The upload unit's process: novadeck_savesync.py post-exit APPID PREFIX."""
    if len(argv) != 4 or argv[1] != "post-exit":
        print("usage: novadeck_savesync.py post-exit APPID PREFIX", file=sys.stderr)
        return 1
    # A stop (a logout) waits for the upload: one cut short leaves the cloud half-written. The
    # unit's KillMode=mixed spares gogdl, and its TimeoutStopSec bounds the wait.
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    post_exit(argv[2], argv[3])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
