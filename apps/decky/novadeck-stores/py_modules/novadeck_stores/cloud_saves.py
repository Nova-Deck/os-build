"""The game page's "Cloud saves" row (.claude/plans/gog-galaxy-comet.plan.md, phase 3 step 8).

An installed GOG game's page shows whether its saves sync with GOG's cloud, a switch for it, when
they last synced, and what the last sync could not do. Its state, from galaxy.json's row:

  none          no row: not an installed GOG Windows game; the page shows nothing
  unavailable   no switch, and why: `no-client` (the install names no Galaxy client id, which cloud
                saves key on), `unknown` (GOG's config not fetched yet; the next library sync
                retries), `unsupported` (GOG has no cloud saves for the game)
  on / off      the switch, `lastSync` (the newest stored stamp of the game's locations, or None)
                and `notes`: what the LAST run (before a launch, or after an exit) could not do,
                in words, from the launch side's record (novadeck_savesync.STATUS)

THE SWITCH is the user's, stored per TOKEN in cloud_config.TOGGLES (absent = on), which galaxy.sync
reads on every library change. set_enabled also rewrites the game's galaxy.json row at once, with
the rule galaxy.attach_cloud applies, because the launch reads galaxy.json and must not sync a
game the user just turned off until some later library sync.
"""
import json
import os

from novadeck_stores import cli, cloud_config, galaxy, status

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
    row = galaxy.read(p).get(str(appid))
    return row if isinstance(row, dict) and isinstance(row.get("token"), str) else None


def _state(row):
    """(state, why) from a galaxy.json row."""
    cloud = row.get("cloud")
    if not row.get("clientId"):
        return "unavailable", "no-client"
    if not isinstance(cloud, dict):
        return "unavailable", "unknown"
    if cloud.get("supported") is not True:
        return "unavailable", "unsupported"
    return ("on" if cloud.get("enabled") is True else "off"), None


def page(p, appid):
    """The row for one appid (unsigned, as a string)."""
    row = _row(p, appid)
    if row is None:
        return {"state": "none"}
    state, why = _state(row)
    if why is not None:
        return {"state": state, "why": why}
    return {"state": state, "lastSync": last_sync(p, row["token"]), "notes": notes(p, row["token"])}


def set_enabled(p, appid, enabled):
    """Turn the game's cloud saves on or off: the stored switch, then its galaxy.json row. The
    row's new state, or {error}. The caller holds the plugin's shortcut lock (a registry write
    rewrites galaxy.json too)."""
    if not isinstance(enabled, bool):
        return {"error": "the switch must be on or off"}
    row = _row(p, appid)
    if row is None:
        return {"error": "not an installed GOG game"}
    state, why = _state(row)
    if why is not None:
        return {"error": f"cloud saves are not available for this game ({why})"}
    toggles = {**cloud_config.toggles(p), row["token"]: enabled}
    if cli.write_as_user(p, os.path.join(p["NOVADECK_STORE_HOME"], TOGGLES),
                         json.dumps(toggles, indent=1)) != 0:
        return {"error": "the switch could not be saved"}
    table = galaxy.read(p)
    updated = {**table, str(appid): {**row, "cloud": {**row["cloud"], "enabled": enabled}}}
    if cli.write_as_user(p, galaxy.path(p), json.dumps(updated, indent=1)) != 0:
        return {"error": "the switch is saved, but the launch will only see it after the next library sync"}
    return page(p, appid)
