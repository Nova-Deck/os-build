"""The hosts we made a Steam tile for: host id -> its name and the tile's appid.

The id is the durable key, as Steam's appid changes when a tile is made again and a host's name and
address are its owner's. Steam's file is never read or written: an entry is ours if it is in here.

Written as the session user, whose directory it is in: as root, a directory swapped for a link would
put the file somewhere else.
"""
import asyncio
import json
import os

from novadeck_streaming import api, unit, user, userfile

MAX_FILE = 64 * 1024
MAX_HOSTS = 64
TIMEOUT = 5
# $0 is the file. Same directory, so the rename replaces it whole.
WRITE = ('umask 077; d="${0%/*}"; mkdir -p "$d" && t="$(mktemp "$d/.hosts.XXXXXX")" && cat >"$t" '
         '&& mv -fT "$t" "$0"')

as_user = user.prefix


def _u32(appid):
    return appid & 0xFFFFFFFF if isinstance(appid, int) and not isinstance(appid, bool) else None


def load(path, uid):
    """{id: {name, appid}}, or None when the file is there but cannot be used."""
    raw = userfile.read(path, uid, MAX_FILE)
    if raw is None:
        return None if os.path.lexists(path) else {}
    try:
        rows = json.loads(raw)
    except (ValueError, RecursionError):
        return None
    if not isinstance(rows, dict):
        return None
    return {key: {"name": api._text(row.get("name")), "appid": _u32(row["appid"])}
            for key, row in rows.items()
            if api.UUID.fullmatch(key) and isinstance(row, dict) and _u32(row.get("appid")) is not None}


async def _save(path, rows):
    proc = await asyncio.create_subprocess_exec(
        *as_user(), "/bin/sh", "-c", WRITE, path, stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL, env=unit.clean_env())
    try:
        await asyncio.wait_for(proc.communicate(json.dumps(rows, indent=1).encode()), TIMEOUT)
        return proc.returncode == 0
    except asyncio.TimeoutError:
        return False
    finally:
        if proc.returncode is None:
            proc.kill()
            await proc.wait()


async def remember(path, uid, uuid, name, appid):
    rows = load(path, uid)
    if rows is None or _u32(appid) is None or not isinstance(uuid, str) or not api.UUID.fullmatch(uuid):
        return False
    if uuid not in rows and len(rows) >= MAX_HOSTS:
        return False
    return await _save(path, {**rows, uuid: {"name": api._text(name), "appid": _u32(appid)}})


async def forget(path, uid, uuid):
    rows = load(path, uid)
    if rows is None:
        return False
    return await _save(path, {k: v for k, v in rows.items() if k != uuid})
