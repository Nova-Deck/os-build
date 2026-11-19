"""Which Epic games have cloud saves, and where (.claude/plans/epic-cloud-saves.plan.md, step 3).

An Epic game with cloud saves names its save folder in its metadata, which legendary caches in
`<LEGENDARY_CONFIG_PATH>/metadata/<gid>.json`: `customAttributes.CloudSaveFolder` (in Epic's
variables, `{AppData}/../LocalLow/Studio/Game/`), with optional `CloudIncludeList` and
`CloudExcludeList` (comma-separated). A launch knows only its appid, so this module writes
`<store home>/epic-cloud.json`:

    unsigned appid → {token, gid, install, cloud}

for every installed Epic Windows entry, keyed like galaxy.json.
  - `install`: the install folder (`{InstallDir}`).
  - `cloud`: {supported, enabled, location, include, exclude}, or None while legendary has cached
    no metadata for the game. `enabled` needs `supported` and the user's per-game switch, which
    is cloud_config.TOGGLES, shared with GOG per token (absent = on, as for GOG). The filter lists
    have the spaces after the commas stripped (`*.sav, *.dat`), or are None when absent.
The launch side resolves the location (novadeck_savepaths.resolve_epic) and syncs it.

No network: the metadata is legendary's cache, which a library sync keeps current. It is read
owner-checked (status.open_user_file), because root reads it inside a tree the user owns.
"""
import json
import os

from novadeck_stores import cli, cloud_config, installs, status

FILENAME = "epic-cloud.json"
# The one folder's name, as the launch side names it (novadeck_epicsaves.LOCATION_NAME): the
# "Which saves?" question names location 0 of an Epic game by it.
LOCATION_NAME = "saves"


def path(p):
    return os.path.join(p["NOVADECK_STORE_HOME"], FILENAME)


def _metadata(p, gid):
    """The game's cached metadata, or None when there is none or it is unreadable."""
    data = status.read_user_json(os.path.join(p["LEGENDARY_CONFIG_PATH"], "metadata", f"{gid}.json"),
                                 int(p["NOVADECK_STORE_UID"]))
    return data if isinstance(data, dict) else None


def _attribute(attrs, name):
    value = attrs.get(name)
    value = value.get("value") if isinstance(value, dict) else None
    return value if isinstance(value, str) and value.strip() else None


def _filters(value):
    """A comma-separated filter list as a list, each item stripped and empty ones dropped."""
    if value is None:
        return None
    return [item.strip() for item in value.split(",") if item.strip()] or None


def cloud_folder(p, gid):
    """{supported, location, include, exclude} from the game's cached metadata, or None when
    legendary has cached none. A macOS-only folder is unsupported: we run the Windows build."""
    data = _metadata(p, gid)
    if data is None:
        return None
    meta = data.get("metadata")
    attrs = meta.get("customAttributes") if isinstance(meta, dict) else None
    attrs = attrs if isinstance(attrs, dict) else {}
    location = _attribute(attrs, "CloudSaveFolder")
    if location is None:
        return {"supported": False, "location": None, "include": None, "exclude": None}
    return {"supported": True, "location": location,
            "include": _filters(_attribute(attrs, "CloudIncludeList")),
            "exclude": _filters(_attribute(attrs, "CloudExcludeList"))}


def build(p, registry, records, toggles):
    """Unsigned appid (str) → {token, gid, install, cloud} for every installed Epic Windows entry."""
    out = {}
    for token, row in registry.items():
        store, _, gid = token.partition(":")
        rec = records.get(token) or {}
        if (store != "epic" or not isinstance(row, dict) or row.get("state") == "shelf"
                or row.get("platform") != "windows" or not isinstance(row.get("appid"), int)
                or not rec.get("path")):
            continue
        folder = cloud_folder(p, gid)
        cloud = None if folder is None else {
            "supported": folder["supported"],
            "enabled": folder["supported"] and toggles.get(token, True),
            "location": folder["location"], "include": folder["include"], "exclude": folder["exclude"]}
        out[str(row["appid"] & 0xFFFFFFFF)] = {"token": token, "gid": gid, "install": rec["path"],
                                               "cloud": cloud}
    return out


def sync(p, registry):
    """Rewrite epic-cloud.json from the registry when it changed. True when the file is current."""
    current = status.read_user_json(path(p), int(p["NOVADECK_STORE_UID"]))
    wanted = build(p, registry, installs.read_records(p), cloud_config.toggles(p))
    if current == wanted or (current is None and not wanted):
        return True
    return cli.write_as_user(p, path(p), json.dumps(wanted, indent=1)) == 0


def read(p):
    """The whole table, or {} when there is none or it is unreadable."""
    data = status.read_user_json(path(p), int(p["NOVADECK_STORE_UID"]))
    return data if isinstance(data, dict) else {}
