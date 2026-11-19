"""Build-time check of 0001-sync-saves-add-dry-run.patch, run by the PKGBUILD's build() in the patched tree.

`legendary sync-saves --dry-run` must classify exactly as a real sync does and change NOTHING: no
upload or download, no save path stored in installed.json, not even the local directory a real
sync creates. It runs legendary's real main() and core against a seeded config dir; only the
network is stubbed, so this runs offline in the build container.

    python check-dry-run.py <patched legendary source dir>

Exits non-zero on the first failure. Run from build() rather than check() because the overlay
build runs makepkg with --nocheck.
"""
import contextlib
import datetime
import io
import json
import os
import sys
import tempfile

CONFIG = tempfile.mkdtemp()
os.environ["LEGENDARY_CONFIG_PATH"] = CONFIG
os.environ["WINEPREFIX"] = os.path.join(CONFIG, "no-prefix")  # legendary's own lookup: none here
os.environ.pop("STEAM_COMPAT_DATA_PATH", None)
sys.path.insert(0, sys.argv[1])
from legendary import cli  # noqa: E402  (the path and environment above first)

ACCOUNT = "0123456789abcdef0123456789abcdef"
OLD, SYNCED, NEW = 1_600_000_000, 1_700_000_000, 1_800_000_000
failures = []


def check(cond, message):
    print(f"  {'ok  ' if cond else 'FAIL'} {message}")
    if not cond:
        failures.append(message)


def forbidden(*_a, **_k):
    raise AssertionError("a dry run changed something")


def manifest(ts):
    return datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).strftime(
        "%Y.%m.%d-%H.%M.%S.manifest")


class OfflineCLI(cli.LegendaryCLI):
    """The real CLI and core, with the network and every write a dry run must not make stubbed."""
    cloud = {}  # app name -> the newest manifest's Unix time

    def __init__(self, *a, **k):
        super().__init__(*a, **k)
        self.core.login = lambda *_a, **_k: True
        self.core.egs.get_user_cloud_saves = self.cloud_saves
        self.core.download_saves = self.core.upload_save = forbidden
        self.core.lgd.set_installed_game = forbidden

    def cloud_saves(self, app_name="", manifests=False, filenames=None):
        files = {}
        for app, ts in self.cloud.items():
            if not app_name or app == app_name:
                files[f"{ACCOUNT}/x/{app}/y/{manifest(ts)}"] = {
                    "lastModified": datetime.datetime.fromtimestamp(ts, datetime.timezone.utc)
                    .strftime("%Y-%m-%dT%H:%M:%S.000Z")}
        return {"files": files}


cli.LegendaryCLI = OfflineCLI


def seed(games):
    """games: {app name: (CloudSaveFolder or None, save_path, save_timestamp)}"""
    with open(os.path.join(CONFIG, "config.ini"), "w") as f:
        f.write("[Legendary]\ndisable_auto_aliasing = true\n")
    with open(os.path.join(CONFIG, "user.json"), "w") as f:
        json.dump({"account_id": ACCOUNT, "displayName": "check"}, f)
    os.makedirs(os.path.join(CONFIG, "metadata"), exist_ok=True)
    installed = {}
    for app, (folder, save_path, ts) in games.items():
        attrs = {"CloudSaveFolder": {"type": "STRING", "value": folder}} if folder else {}
        with open(os.path.join(CONFIG, "metadata", f"{app}.json"), "w") as f:
            json.dump({"app_name": app, "app_title": app, "asset_infos": {},
                       "metadata": {"customAttributes": attrs}}, f)
        installed[app] = {"app_name": app, "title": app, "version": "1",
                          "install_path": os.path.join(CONFIG, "games", app),
                          "save_path": save_path, "save_timestamp": ts, "platform": "Windows"}
    with open(os.path.join(CONFIG, "installed.json"), "w") as f:
        json.dump(installed, f)


def installed_json():
    with open(os.path.join(CONFIG, "installed.json")) as f:
        return f.read()


def dry_run(*args):
    """Every stdout line of `legendary sync-saves --dry-run ARGS`, parsed as JSON."""
    argv, sys.argv = sys.argv, ["legendary", "sync-saves", *args, "--dry-run"]
    out = io.StringIO()
    try:
        with contextlib.redirect_stdout(out):
            cli.main()
    except SystemExit as exc:
        check(exc.code in (0, None), f"exits 0 (got {exc.code})")
    finally:
        sys.argv = argv
    lines = [line for line in out.getvalue().splitlines() if line.strip()]
    try:
        return [json.loads(line) for line in lines]
    except ValueError:
        check(False, f"stdout is JSON lines only ({out.getvalue()!r})")
        return []


def save_dir(files):
    d = tempfile.mkdtemp()
    for name, mtime in files.items():
        p = os.path.join(d, name)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w") as f:
            f.write(name)
        os.utime(p, (mtime, mtime))
    return d


def snapshot(d):
    return sorted((os.path.relpath(os.path.join(r, n), d), os.stat(os.path.join(r, n)).st_mtime)
                  for r, _, names in os.walk(d) for n in names)


def one(reports):
    check(len(reports) == 1, f"one JSON line for one game ({reports})")
    return reports[0] if reports else {}


FOLDER = "{AppData}/Game/Saved"

# Local changed since the last sync, the cloud did not.
seed({"Game": (FOLDER, None, SYNCED)})
OfflineCLI.cloud = {"Game": OLD}
d = save_dir({"slot1.sav": NEW, "sub/slot2.sav": OLD})
before, record = snapshot(d), installed_json()
r = one(dry_run("Game", "--save-path", d))
check(r.get("status") == "local_newer" and r.get("save_path") == d,
      f"only local changed: local_newer, at the given path ({r})")
check(r.get("local_newest") == NEW and r.get("cloud_newest") == OLD and r.get("last_sync") == SYNCED,
      f"each side's newest time and the last sync, as Unix times ({r})")
check(r.get("cloud_manifest") == manifest(OLD), f"the cloud manifest a download would take ({r})")
check(snapshot(d) == before, "the local files are untouched")
check(installed_json() == record, "--save-path is NOT stored in installed.json, as a real sync would")

# Both changed since the last sync: a real sync with -y only logs this.
OfflineCLI.cloud = {"Game": NEW + 600}
r = one(dry_run("Game", "--save-path", d))
check(r.get("status") == "conflict" and r.get("cloud_newest") == NEW + 600,
      f"both sides changed: conflict, with both dates ({r})")

# Same age: what a sync leaves behind (legendary names the uploaded manifest after the newest local
# file, then stores the sync time). The conflict test runs first, so both dates must not be more
# than 60 s past the last sync.
seed({"Game": (FOLDER, None, NEW + 30)})
OfflineCLI.cloud = {"Game": NEW}
r = one(dry_run("Game", "--save-path", d))
check(r.get("status") == "same_age", f"within legendary's 60 s of each other: same_age ({r})")
seed({"Game": (FOLDER, None, SYNCED)})

# No local folder: the cloud's saves would come down, and the folder is not created.
missing = os.path.join(tempfile.mkdtemp(), "not-yet")
OfflineCLI.cloud = {"Game": OLD}
r = one(dry_run("Game", "--save-path", missing))
check(r.get("status") == "remote_newer" and r.get("local_newest") is None,
      f"no local folder: remote_newer ({r})")
check(not os.path.exists(missing), "and the missing folder is NOT created, as a real sync would")

# Nothing on either side.
OfflineCLI.cloud = {}
r = one(dry_run("Game", "--save-path", missing))
check(r.get("status") == "no_save" and r.get("cloud_manifest") is None, f"both empty: no_save ({r})")

# No --save-path and none stored: legendary computes one and does not store it.
seed({"Game": ("{InstallDir}/Saved", None, None)})
record = installed_json()
r = one(dry_run("Game"))
check(r.get("save_path") == os.path.join(CONFIG, "games", "Game", "Saved"),
      f"the computed path, from {{InstallDir}} ({r})")
check(installed_json() == record, "the computed path is NOT stored either")

# A computed path that still holds a variable is not used.
seed({"Game": (FOLDER, None, None)})
r = one(dry_run("Game"))
check(r.get("status") == "no_save_path" and r.get("save_path") is None,
      f"{{AppData}} with no prefix: no_save_path, nothing checked ({r})")

# The same from a working directory the user cannot list: legendary leaves the unresolved path
# relative, realpath() anchors it at the cwd, and its case-insensitive search lists the cwd. As deck
# from /root that raised PermissionError (HW 2026-11-19); a dry run must still answer.
locked = tempfile.mkdtemp()
os.chmod(locked, 0o311)
cwd = os.getcwd()
os.chdir(locked)
try:
    r = one(dry_run("Game"))
finally:
    os.chdir(cwd)
    os.chmod(locked, 0o755)
check(r.get("status") == "no_save_path", f"an unlistable cwd: no_save_path, not a crash ({r})")

# A game without cloud saves says so instead of printing nothing.
seed({"NoCloud": (None, None, None)})
r = one(dry_run("NoCloud"))
check(r == {"app_name": "NoCloud", "status": "unsupported"}, f"no CloudSaveFolder: unsupported ({r})")

# Every installed game when no app name is given: one line each.
d2 = save_dir({"a.sav": OLD})
seed({"Game": (FOLDER, d2, SYNCED), "NoCloud": (None, None, None)})
OfflineCLI.cloud = {"Game": NEW}
reports = {r.get("app_name"): r for r in dry_run()}
check(set(reports) == {"Game", "NoCloud"}, f"one line per installed game ({sorted(reports)})")
check(reports.get("Game", {}).get("status") == "remote_newer" and reports["Game"].get("save_path") == d2,
      f"the stored save path is used ({reports.get('Game')})")

if failures:
    sys.exit(f"check-dry-run: {len(failures)} failed")
print("check-dry-run: all passed")
