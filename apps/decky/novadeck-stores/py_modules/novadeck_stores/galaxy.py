"""Which GOG games talk to the Galaxy client, for Comet (.claude/plans/gog-galaxy-comet.plan.md).

A game built on the Galaxy SDK signs in through the Galaxy client service on 127.0.0.1:9977. We
ship no client, so without Comet answering there the sign-in never completes, and Another World
20th Anniversary dies at its first achievement unlock. game-launch starts Comet around a launch,
and a launch knows only its appid, so this module writes `<store home>/galaxy.json`:

    unsigned appid → {token, gid, clientId, comet}

for every installed GOG Windows entry, keyed like first-run.json and dos-targets.json.
  - `comet`: the install ships the SDK DLL (Galaxy.dll / Galaxy64.dll, any case, anywhere in
    the tree). This selects games, it does not guard: a game without the SDK never calls 9977,
    so starting Comet for it would only cost a process.
  - `clientId`: the Galaxy client id from goggame-<gid>.info, or None. Cloud saves key on it.

ROOT walks this tree, which the store user owns, so the walk does not follow symlinks, and the
info file goes through dos_targets.read_info (status.open_user_file).
"""
import json
import os

# dos_targets as a MODULE, not `from ... import read_info`: dos_targets → install_requests →
# shortcuts → galaxy is an import cycle, and a name import fails on the half-initialised module.
from novadeck_stores import cli, dos_targets, installs, status

FILENAME = "galaxy.json"
SDK_DLLS = frozenset({"galaxy.dll", "galaxy64.dll"})


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
            "comet": has_galaxy_sdk(install)}
    return out


def sync(p, registry):
    """Rewrite galaxy.json from the registry when it changed. True when the file is current."""
    uid = int(p["NOVADECK_STORE_UID"])
    current = status.read_user_json(path(p), uid)
    wanted = build(registry, installs.read_records(p), uid)
    if current == wanted or (current is None and not wanted):
        return True
    return cli.write_as_user(p, path(p), json.dumps(wanted, indent=1)) == 0


def read(p):
    """The whole table, or {} when there is none or it is unreadable."""
    data = status.read_user_json(path(p), int(p["NOVADECK_STORE_UID"]))
    return data if isinstance(data, dict) else {}
