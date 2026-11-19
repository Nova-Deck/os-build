"""What is Epic's in the cloud-save sync; novadeck_savesync does the rest for both stores.

    row(table, appid)                 this appid's epic-cloud.json row, shaped like a GOG one
    account_id(config path)           legendary's account id, for {EpicID}
    dry_run_argv / sync_argv          the legendary calls
    verdict(stdout, gid)              the dry run's answer, in the GOG sync's vocabulary
    whole_install(path, install, include)   a folder a download must never run in
    selects(relpath, include, exclude)   is this file one the game's filters select (the backup)
    NOTHING_PACKED                    what legendary says when an upload found no file to send

THE ROW. The plugin writes epic-cloud.json (py_modules/novadeck_stores/epic_cloud.py) with ONE
folder per game. row() hands the shared sync a GOG-shaped row: `cloud.locations` holding that folder
under the name LOCATION_NAME, plus `store: "epic"` and the filter lists.

THE VERDICT comes from `legendary sync-saves --dry-run` (our patch 0001, packages/legendary): one
JSON line with legendary's own SaveGameStatus. ACTIONS maps it to the GOG sync's actions, so one
policy serves both (.claude/plans/epic-cloud-saves.plan.md design §3). `unsupported` and
`no_save_path` are reasons, not actions: the location is skipped and the game page says why.

THE BACKUP before a download. legendary's download DELETES the local save files before it fetches
the cloud's (core.py download_saves), so a backup is what makes it recoverable. A game's folder may
be the whole install (Fallout: `{InstallDir}/`, `*.sav, *.dat` minus `critter.dat, master.dat`, with
an uppercase MASTER.DAT and CRITTER.DAT in each of four language folders), so the backup copies
what the game's filters select, include AND exclude, in any case. That is exactly what our
legendary deletes and uploads (patch 0002, packages/legendary): stock legendary matched
case-sensitively and read the download's lists unstripped. With no include list, a download deletes
everything in the folder not excluded. When that folder is the whole install folder, the download
would delete the game, so whole_install() refuses it.

AN UPLOAD THAT SENT NOTHING. When the filters select no file, legendary logs "No files to upload"
and still exits 0, and stores a sync time. That is not an upload (Fallout before patch 0002, HW
2026-11-19), so the sync records it as skipped, with NOTHING_PACKED's reason.
"""
import fnmatch
import json
import os

from novadeck_storeenv import read_json

LEGENDARY = "/usr/bin/legendary"
TABLE = "epic-cloud.json"  # in the store home, written by the plugin
LOCATION_NAME = "saves"    # Epic names no locations; one name keeps the backups and the page apart
OFFLINE = "Epic could not be reached (no network?)"
# legendary's SaveGameStatus (lowercased by the dry run) -> the GOG sync's action.
ACTIONS = {"local_newer": "upload", "remote_newer": "download", "conflict": "conflict",
           "same_age": "none", "no_save": "none"}
NOTHING_PACKED = "No files to upload"  # legendary core.py upload_save, logged on stderr
REASONS = {"unsupported": "legendary says the game has no cloud saves (unsupported)",
           "no_save_path": "legendary could not work out the save folder (no_save_path)"}


def _filters(value):
    if not isinstance(value, list):
        return None
    return [v for v in value if isinstance(v, str) and v] or None


def row(table, appid):
    """This appid's row when its cloud sync is on, shaped like a GOG row; else None."""
    r = table.get(str(appid)) if isinstance(table, dict) else None
    cloud = r.get("cloud") if isinstance(r, dict) else None
    if not (isinstance(cloud, dict) and cloud.get("enabled") is True
            and isinstance(cloud.get("location"), str) and cloud["location"].strip()
            and isinstance(r.get("gid"), str) and isinstance(r.get("token"), str)):
        return None
    return {**r, "store": "epic",
            "cloud": {"enabled": True,
                      "locations": [{"name": LOCATION_NAME, "location": cloud["location"]}],
                      "include": _filters(cloud.get("include")),
                      "exclude": _filters(cloud.get("exclude"))}}


def account_id(config_path):
    """legendary's account id (user.json), or None when it is not there."""
    data = read_json(os.path.join(config_path, "user.json")) if config_path else None
    value = data.get("account_id") if isinstance(data, dict) else None
    return value if isinstance(value, str) and value else None


def dry_run_argv(gid, path):
    return [LEGENDARY, "sync-saves", gid, "--save-path", path, "--dry-run"]


def sync_argv(gid, path, flag):
    """A real sync: -y, because legendary would otherwise prompt on a terminal it does not have."""
    return [LEGENDARY, "-y", "sync-saves", gid, "--save-path", path, flag]


def _newest(value):
    return float(value) if isinstance(value, (int, float)) and value > 0 else None


def verdict(stdout, gid):
    """(verdict, None) for an actionable status, (None, reason) for one that says why not, or
    (None, None) when stdout holds no line for this game. A verdict is {action, status, local:
    {newest}, cloud: {newest}}, the shape novadeck_savesync acts on and ask() reads."""
    for line in reversed((stdout or "").splitlines()):
        try:
            data = json.loads(line)
        except ValueError:
            continue
        if not isinstance(data, dict) or data.get("app_name") != gid:
            continue
        status = data.get("status")
        if status in REASONS:
            return None, REASONS[status]
        if status not in ACTIONS:
            return None, None
        return {"action": ACTIONS[status], "status": status,
                "local": {"newest": _newest(data.get("local_newest"))},
                "cloud": {"newest": _newest(data.get("cloud_newest"))}}, None
    return None, None


def whole_install(path, install, include):
    """True when a download would run over the whole install folder with no include list."""
    if include or not install:
        return False
    return os.path.realpath(path) == os.path.realpath(install)


def _matches(rel, patterns):
    """legendary's _filename_matches as patched (0002): a pattern ending in / is a folder prefix, a
    plain pattern a suffix, and both may use fnmatch wildcards, all in any case."""
    rel = rel.casefold()
    for pattern in (p.casefold() for p in patterns):
        if pattern.endswith("/") and rel.startswith(pattern):
            return True
        if rel.endswith(pattern) or fnmatch.fnmatchcase(rel, pattern):
            return True
    return False


def selects(relpath, include, exclude=None):
    """Do the game's filters select this file (a /-separated path relative to the save folder)?
    Selected by the include list (all files without one) and not excluded: what legendary's upload
    sends and its download deletes. No lists at all (GOG) selects everything."""
    if include and not _matches(relpath, include):
        return False
    return not (exclude and _matches(relpath, exclude))
