"""Which GOG games talk to the Galaxy client, for Comet (.claude/plans/gog-galaxy-comet.plan.md).

A game built on the Galaxy SDK signs in through the Galaxy client service on 127.0.0.1:9977. We
ship no client, so without Comet answering there the sign-in never completes, and Another World
20th Anniversary dies at its first achievement unlock. game-launch starts Comet around a launch,
and a launch knows only its appid, so this module writes `<store home>/galaxy.json`:

    unsigned appid → {token, gid, clientId, comet, install, cloud}

for every installed GOG Windows entry, keyed like first-run.json and dos-targets.json.
  - `comet`: the install ships the SDK DLL (Galaxy.dll / Galaxy64.dll, any case, anywhere in
    the tree). This selects games, it does not guard: a game without the SDK never calls 9977,
    so starting Comet for it would only cost a process.
  - `clientId`: the Galaxy client id from goggame-<gid>.info, or None. Cloud saves key on it.
  - `install`: the install folder (`<?INSTALL?>` in a save location).
  - `cloud`: {supported, enabled, locations} from GOG's config (cloud_config.py), `enabled` also
    needing the user's per-game switch; None while there is none. The launch side's pre-launch
    sync reads it (/usr/lib/novadeck/novadeck_savesync.py).

ROOT walks this tree, which the store user owns, so the walk does not follow symlinks, and the
info file goes through dos_targets.read_info (status.open_user_file).

It also owns the dummy GalaxyCommunication service some SDK versions need: the staged files and
the first-run step that registers it (first_run.py adds the step to every Galaxy game).
"""
import json
import os

# dos_targets as a MODULE, not `from ... import read_info`: dos_targets → install_requests →
# shortcuts → galaxy is an import cycle, and a name import fails on the half-initialised module.
from novadeck_stores import cli, cloud_config, dos_targets, installs, status

FILENAME = "galaxy.json"
SDK_DLLS = frozenset({"galaxy.dll", "galaxy64.dll"})

# The dummy GalaxyCommunication service (plan design §7), a first-run step of every Galaxy game.
# Staged name → shipped file. The step runs inside the game's runtime container, which shares
# /home but not this /usr, so the files are copied into the store home and the step runs the copy.
SERVICE_DIR = "galaxy-service"
SERVICE_BAT = "galaxy-service.bat"
SERVICE_FILES = {
    "GalaxyCommunication.exe": "/usr/share/comet-dummy-service/GalaxyCommunication.exe",  # pinned
    SERVICE_BAT: "/usr/lib/novadeck/galaxy-service.bat",  # ours (rootfs/overlay)
}
STAGE_TIMEOUT = 30


def path(p):
    return os.path.join(p["NOVADECK_STORE_HOME"], FILENAME)


def has_galaxy_sdk(install):
    """True when a Galaxy SDK DLL is anywhere under install. Engines bury it at different depths
    (Unity: <Game>_Data/Plugins/x86_64; Unreal: Engine/Binaries/ThirdParty/GOG/Win64), so the
    whole tree is walked. A missing or unreadable install is False."""
    for _dirpath, _dirs, files in os.walk(install, followlinks=False):
        if any(name.casefold() in SDK_DLLS for name in files):
            return True
    return False


def client_id(install, gid, uid):
    """The info file's clientId, or None when there is none or it is not a string."""
    info = dos_targets.read_info(os.path.join(install, f"goggame-{gid}.info"), uid)
    cid = info.get("clientId") if isinstance(info, dict) else None
    return cid if isinstance(cid, str) and cid else None


def build(registry, records, uid):
    """Unsigned appid (str) → {token, gid, clientId, comet} for every installed GOG Windows entry."""
    out = {}
    for token, row in registry.items():
        store, _, gid = token.partition(":")
        rec = records.get(token) or {}
        if (store != "gog" or not isinstance(row, dict) or row.get("state") == "shelf"
                or row.get("platform") != "windows" or not isinstance(row.get("appid"), int)
                or not rec.get("path")):
            continue
        install = rec["path"]
        out[str(row["appid"] & 0xFFFFFFFF)] = {
            "token": token, "gid": gid, "clientId": client_id(install, gid, uid),
            "comet": has_galaxy_sdk(install), "install": install}
    return out


def attach_cloud(rows, configs, toggles):
    """New rows, each with `cloud`: {supported, enabled, locations} from GOG's config for its
    clientId, `enabled` also needing the user's switch (absent = on); None while there is no config
    (no clientId, offline, not fetched yet), which the launch side skips."""
    out = {}
    for appid, row in rows.items():
        config = configs.get(row.get("clientId"))
        cloud = None if config is None else {
            "supported": config["supported"],
            "enabled": config["supported"] and toggles.get(row["token"], True),
            "locations": config["locations"] if config["supported"] else []}
        out[appid] = {**row, "cloud": cloud}
    return out


def sync(p, registry):
    """Rewrite galaxy.json from the registry when it changed. True when the file is current."""
    uid = int(p["NOVADECK_STORE_UID"])
    current = status.read_user_json(path(p), uid)
    rows = build(registry, installs.read_records(p), uid)
    configs = cloud_config.configs(p, [r["clientId"] for r in rows.values()])
    wanted = attach_cloud(rows, configs, cloud_config.toggles(p))
    if current == wanted or (current is None and not wanted):
        return True
    return cli.write_as_user(p, path(p), json.dumps(wanted, indent=1)) == 0


def service_dir(p):
    return os.path.join(p["NOVADECK_STORE_HOME"], SERVICE_DIR)


def service_step(p):
    """The first-run step that registers the service: the staged .bat, run in its own dir."""
    return {"argv": [os.path.join(service_dir(p), SERVICE_BAT)], "cwd": service_dir(p)}


def _same(src, staged, uid):
    """Does the staged copy (the store user's file) hold exactly the shipped bytes?"""
    f = status.open_user_file(staged, uid)
    if f is None:
        return False
    try:
        with f, open(src, "rb") as s:
            return f.read() == s.read()
    except OSError:
        return False


def stage_service(p):
    """Copy the shipped service files into the store home, as the store user, where a staged copy
    is missing or differs (an OTA can ship a new stub). True when every staged copy is current."""
    uid = int(p["NOVADECK_STORE_UID"])
    for name, src in SERVICE_FILES.items():
        staged = os.path.join(service_dir(p), name)
        if _same(src, staged, uid):
            continue
        if not os.path.isfile(src):
            return False
        if cli._run(p, ["install", "-D", "-m", "0644", src, staged], STAGE_TIMEOUT) != 0:
            return False
    return True


def read(p):
    """The whole table, or {} when there is none or it is unreadable."""
    data = status.read_user_json(path(p), int(p["NOVADECK_STORE_UID"]))
    return data if isinstance(data, dict) else {}
