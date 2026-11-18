"""The plugin's half of the cloud-save conflict question (.claude/plans/gog-galaxy-comet.plan.md,
phase 3 step 6; the launch's half is /usr/lib/novadeck/novadeck_savesync.py ask()).

A GOG game whose saves changed both here and in the cloud since the last sync is waiting in
game-launch on `<appid>.<index>.<local>.<cloud>.savepick` (install_requests.SAVE_PICK). The name
is all root reads: the game's title comes from the registry and the location's name from
galaxy.json, both the plugin's own files. The answer is `<appid>.<index>.saveanswer`, written as
the store user: `cloud` (the launch backs up the local folder, then downloads), `local` (it
uploads over the cloud), or empty (nothing is synced; the user is asked again next launch).
"""
import os

from novadeck_stores import cli, galaxy, install_requests

ANSWER_SUFFIX = ".saveanswer"
CHOICES = ("cloud", "local")


def parse(token):
    """(appid str, index, local, cloud) from a question's name, or None."""
    m = install_requests.SAVE_PICK.fullmatch(token or "")
    if m is None:
        return None
    return m.group(1), int(m.group(2)), int(m.group(3)), int(m.group(4))


def describe(p, token, registry):
    """The save_pick event for a question, or None when it names no location of ours (the launch
    then times out and keeps local)."""
    parsed = parse(token)
    if parsed is None:
        return None
    appid, index, local, cloud = parsed
    row = galaxy.read(p).get(appid)
    locations = (row.get("cloud") or {}).get("locations") if isinstance(row, dict) else None
    if not isinstance(locations, list) or index >= len(locations) or not isinstance(locations[index], dict):
        return None
    title = next((r.get("title") for r in registry.values()
                  if isinstance(r, dict) and isinstance(r.get("appid"), int)
                  and r["appid"] & 0xFFFFFFFF == int(appid)), None)
    return {"appid": int(appid), "index": index, "title": title or "This game",
            "location": str(locations[index].get("name") or ""), "localTime": local, "cloudTime": cloud}


def answer(p, appid, index, choice):
    """Hand the waiting launch its answer. True when written. `appid` must be digits and `index` a
    small non-negative int: together they name a file in the user's spool."""
    if (not isinstance(appid, str) or not install_requests.APPID.fullmatch(appid)
            or not isinstance(index, int) or isinstance(index, bool) or not 0 <= index <= 999
            or (choice is not None and choice not in CHOICES)):
        return False
    target = os.path.join(install_requests.spool_path(p), f"{appid}.{index}{ANSWER_SUFFIX}")
    return cli.write_as_user(p, target, choice or "") == 0
