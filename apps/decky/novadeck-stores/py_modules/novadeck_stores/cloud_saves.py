"""The game page's "Cloud saves" row (.claude/plans/gog-galaxy-comet.plan.md, phase 3 step 8;
.claude/plans/epic-cloud-saves.plan.md step 6).

An installed GOG or Epic game's page shows whether its saves sync with the store's cloud, a switch
for it, when they last synced, and what the last sync could not do. Its state, from the game's
galaxy.json (or epic-cloud.json) row:

  none          no row: not an installed GOG or Epic Windows game; the page shows nothing
  unavailable   no switch, and why: `no-client` (the install names no Galaxy client id, which cloud
                saves key on), `unknown` (GOG's config not fetched yet; the next library sync
                retries), `unsupported` (GOG has no cloud saves for the game)
  on / off      the switch, `lastSync` (the newest stored stamp of the game's locations, or None)
                and `notes`: what the LAST run (before a launch, or after an exit) could not do,
                in words, from the launch side's record (novadeck_savesync.STATUS)

EPIC rows come from epic-cloud.json (epic_cloud.py), with the same states: `unknown` when
legendary has cached no metadata for the game, `unsupported` with no CloudSaveFolder (`no-client` is
GOG's only). The last sync is legendary's own `save_timestamp` (installed.json), because the launch
stores no timestamp for Epic; the notes come from the same status file, keyed by token.

THE SWITCH is the user's, stored per TOKEN in cloud_config.TOGGLES (absent = on), which galaxy.sync
reads on every library change. set_enabled also rewrites the game's galaxy.json row at once, with
the rule galaxy.attach_cloud applies, because the launch reads galaxy.json and must not sync a
game the user just turned off until some later library sync.
"""
import json
import os

from novadeck_stores import cli, cloud_config, epic_cloud, galaxy, status

TIMESTAMPS = "save-timestamps.json"  # novadeck_savesync.TIMESTAMPS, in GOGDL_CONFIG_PATH
STATUS = "save-status.json"          # novadeck_savesync.STATUS, beside it
TOGGLES = cloud_config.TOGGLES
MAX_REASON = 200
PHASES = {"launch": "at the last launch", "exit": "after the last exit"}
CONFLICT = ("kept-local", "next-launch")
PROBLEM = ("skipped", "failed")


def _gogdl_file(p, name):
    return os.path.join(p["GOGDL_CONFIG_PATH"], name)


def _user_json(p, path):
    data = status.read_user_json(path, int(p["NOVADECK_STORE_UID"]))
    return data if isinstance(data, dict) else {}


def last_sync(p, token):
    """The newest stored stamp of the game's locations, or None when it never synced."""
    newest = None
    for key, value in _user_json(p, _gogdl_file(p, TIMESTAMPS)).items():
        if not (isinstance(key, str) and key.startswith(f"{token}:")):
            continue
        try:
            stamp = float(value)
        except (TypeError, ValueError):
            continue
        newest = stamp if newest is None or stamp > newest else newest
    return newest


def epic_last_sync(p, gid):
    """legendary's save_timestamp for the game (installed.json), or None when it never synced."""
    path = os.path.join(p.get("LEGENDARY_CONFIG_PATH") or "", "installed.json")
    entry = _user_json(p, path).get(gid)
    stamp = entry.get("save_timestamp") if isinstance(entry, dict) else None
    return float(stamp) if isinstance(stamp, (int, float)) and not isinstance(stamp, bool) else None


def _text(value):
    return value[:MAX_REASON] if isinstance(value, str) else ""


def notes(p, token):
    """What the last run could not do, one sentence per location (or one for the whole run)."""
    record = _user_json(p, _gogdl_file(p, STATUS)).get(token)
    if not isinstance(record, dict):
        return []
    when = PHASES.get(record.get("phase"), "at the last sync")
    reason = _text(record.get("reason"))
    if reason:
        return [f"Not synced {when}: {reason}"]
    out = []
    outcomes = record.get("outcomes")
    for outcome in outcomes if isinstance(outcomes, list) else []:
        if not isinstance(outcome, dict):
            continue
        name = _text(outcome.get("name")) or "a save location"
        did = outcome.get("did")
        if did in CONFLICT:
            out.append(f"{name}: changed here and in the cloud; you will be asked at the next launch")
        elif did in PROBLEM:
            out.append(f"{name}: not synced {when}: {_text(outcome.get('reason')) or 'no reason recorded'}")
    return out


def _row(p, appid):
    """(row, store) for the appid: its galaxy.json row ("gog"), else its epic-cloud.json row
    ("epic"); (None, None) when it has neither."""
    for store, table in (("gog", galaxy), ("epic", epic_cloud)):
        row = table.read(p).get(str(appid))
        if isinstance(row, dict) and isinstance(row.get("token"), str):
            return row, store
    return None, None


# GOG's DOSBox classics sync `<install>/cloud_saves`, a folder their installer ships and their
# DOSBox config writes saves into. GOG's remote config also enables that location for classics it
# never wired up: Master of Magic Classic's install has no such folder and nothing names one, and
# GOG's store lists no "Cloud saves" for it (HW 2026-11-19). Such a game has no cloud saves.
INSTALL_CLOUD_SAVES = "<?INSTALL?>/cloud_saves"


def _only_absent_install_folder(row, cloud):
    """Every location is the install's cloud_saves, and the install has no such folder. Read live,
    so a folder that appears (saves restored into it) brings the switch back. Any other location
    is trusted even before it exists: a game creates its save folder on its first save."""
    locations = cloud.get("locations") or []
    install = row.get("install")
    if not locations or not isinstance(install, str) or not install:
        return False
    if any(loc.get("location", "").lower() != INSTALL_CLOUD_SAVES.lower() for loc in locations):
        return False
    return not os.path.isdir(os.path.join(install, "cloud_saves"))


def _state(row, store):
    """(state, why) from a galaxy.json or epic-cloud.json row."""
    cloud = row.get("cloud")
    if store == "epic":
        if not isinstance(cloud, dict):
            return "unavailable", "unknown"
        if cloud.get("supported") is not True:
            return "unavailable", "unsupported"
        return ("on" if cloud.get("enabled") is True else "off"), None
    if not row.get("clientId"):
        return "unavailable", "no-client"
    if not isinstance(cloud, dict):
        return "unavailable", "unknown"
    if cloud.get("supported") is not True or _only_absent_install_folder(row, cloud):
        return "unavailable", "unsupported"
    return ("on" if cloud.get("enabled") is True else "off"), None


def page(p, appid):
    """The row for one appid (unsigned, as a string)."""
    row, store = _row(p, appid)
    if row is None:
        return {"state": "none"}
    state, why = _state(row, store)
    if why is not None:
        return {"state": state, "why": why}
    synced = epic_last_sync(p, row.get("gid")) if store == "epic" else last_sync(p, row["token"])
    return {"state": state, "lastSync": synced, "notes": notes(p, row["token"])}


def set_enabled(p, appid, enabled):
    """Turn the game's cloud saves on or off: the stored switch, then its galaxy.json (or
    epic-cloud.json) row. The row's new state, or {error}. The caller holds the plugin's shortcut
    lock (a registry write rewrites both files too)."""
    if not isinstance(enabled, bool):
        return {"error": "the switch must be on or off"}
    row, store = _row(p, appid)
    if row is None:
        return {"error": "not an installed GOG or Epic game"}
    state, why = _state(row, store)
    if why is not None:
        return {"error": f"cloud saves are not available for this game ({why})"}
    toggles = {**cloud_config.toggles(p), row["token"]: enabled}
    if cli.write_as_user(p, os.path.join(p["NOVADECK_STORE_HOME"], TOGGLES),
                         json.dumps(toggles, indent=1)) != 0:
        return {"error": "the switch could not be saved"}
    table = galaxy if store == "gog" else epic_cloud
    updated = {**table.read(p), str(appid): {**row, "cloud": {**row["cloud"], "enabled": enabled}}}
    if cli.write_as_user(p, table.path(p), json.dumps(updated, indent=1)) != 0:
        return {"error": "the switch is saved, but the launch will only see it after the next library sync"}
    return page(p, appid)
