"""Which GOG games have cloud saves, and where (.claude/plans/gog-galaxy-comet.plan.md, phase 3).

GOG publishes each game's cloud-save config per Galaxy client id, unauthenticated, at
remote-config.gog.com: `content.Windows.cloudStorage = {enabled, locations: [{name, location}]}`,
the locations in GOG's tokens (`<?DOCUMENTS?>/Another World`). This is the endpoint and the shape
Heroic reads (gog/library.ts getSaveSyncLocation). A supported game that names no location saves
under its client's Galaxy storage, Heroic's `__default` (save_sync.ts).

galaxy.py attaches the result to each galaxy.json row; the launch side
(/usr/lib/novadeck/novadeck_savesync.py) resolves and syncs it.

CACHED per clientId in the store home (CACHE), because galaxy.sync runs on every registry write:
a fresh entry is not fetched again, a stale one (MAX_AGE) is refetched and kept if that fails. A
failed fetch caches nothing, so the game simply has no cloud data until a later sync; within
RETRY_AFTER it is not retried, so an offline library sync does not wait on GOG per game.

The per-game switch (TOGGLES, token -> bool) is the user's; absent means ON (decided 2026-11-17).
"""
import http.client
import json
import os
import time
import urllib.parse
import urllib.request

from novadeck_stores import artwork, cli, status

URL = "https://remote-config.gog.com/components/galaxy_client/clients/{cid}?component_version=2.0.45"
CACHE = "gog-cloud-config.json"
TOGGLES = "cloud-saves.json"
TIMEOUT = 5
MAX_BYTES = 1 << 20
MAX_AGE = 7 * 24 * 3600
RETRY_AFTER = 600
_failed = {}  # clientId -> when its last fetch failed (this process only)


def default_location(cid):
    return {"name": "__default",
            "location": f"%LocalAppData%/GOG.com/Galaxy/Applications/{cid}/Storage/Shared/Files"}


def parse(data, cid):
    """{supported, locations} from a remote-config answer, or None when it is not GOG's shape."""
    content = data.get("content") if isinstance(data, dict) else None
    if not isinstance(content, dict):
        return None
    windows = content.get("Windows")
    storage = windows.get("cloudStorage") if isinstance(windows, dict) else None
    if not isinstance(storage, dict) or storage.get("enabled") is not True:
        return {"supported": False, "locations": []}
    locations = [{"name": loc["name"], "location": loc["location"]}
                 for loc in storage.get("locations") or []
                 if isinstance(loc, dict) and isinstance(loc.get("name"), str) and loc["name"]
                 and isinstance(loc.get("location"), str) and loc["location"]]
    return {"supported": True, "locations": locations or [default_location(cid)]}


def fetch_json(url):
    req = urllib.request.Request(url, headers={"User-Agent": "novadeck"})
    with urllib.request.urlopen(req, timeout=TIMEOUT, context=artwork.tls_context()) as resp:
        return json.loads(resp.read(MAX_BYTES).decode("utf-8", "replace"))


def _path(p, name):
    return os.path.join(p["NOVADECK_STORE_HOME"], name)


def _read(p, name):
    data = status.read_user_json(_path(p, name), int(p["NOVADECK_STORE_UID"]))
    return data if isinstance(data, dict) else {}


def configs(p, client_ids, fetch=None, clock=time.time):
    """{clientId: {supported, locations}} for those of client_ids GOG has answered for."""
    fetch = fetch or fetch_json
    cache = _read(p, CACHE)
    changed = False
    wanted = sorted({c for c in client_ids if isinstance(c, str) and c.isdigit()})
    for cid in wanted:
        entry = cache.get(cid)
        if isinstance(entry, dict) and clock() - entry.get("fetched", 0) < MAX_AGE:
            continue
        if clock() - _failed.get(cid, float("-inf")) < RETRY_AFTER:
            continue
        try:
            parsed = parse(fetch(URL.format(cid=urllib.parse.quote(cid))), cid)
        except (OSError, ValueError, http.client.HTTPException):
            parsed = None
        if parsed is None:
            _failed[cid] = clock()
            continue
        cache[cid] = {**parsed, "fetched": clock()}
        changed = True
    if changed:
        cli.write_as_user(p, _path(p, CACHE), json.dumps(cache, indent=1))
    return {cid: {"supported": cache[cid].get("supported") is True,
                  "locations": cache[cid].get("locations") or []}
            for cid in wanted if isinstance(cache.get(cid), dict)}


def toggles(p):
    """{token: bool} for the games the user switched; absent means on."""
    return {t: v for t, v in _read(p, TOGGLES).items() if isinstance(v, bool)}
