"""Library-first (milestone 7): every owned game is a Steam tile, listed in its store's tab.

This module DECIDES; main.py carries the decisions out through the frontend bridge:

  * which owned titles still need a not-installed tile (to_shelve), and
  * what each store's library tab lists (tab_members).

Both are pure functions of the store's owned list and our registry, so a re-sync is idempotent:
a title with a registry row — shelf tile or installed entry — is never added twice.

A title the store says cannot be installed (an Epic ThirdPartyManagedApp: no Epic assets at all,
library.py) gets no tile. A tile exists to be pressed, and pressing that one could only fail.
"""
from novadeck_stores import locations, shortcuts


def to_shelve(store, titles, registry):
    """[{id, title}] for every installable owned title with no registry row yet, in the store's
    order. An id that could not be a token is skipped, never raised: one bad catalogue row must
    not stop the rest of the library from appearing."""
    out = []
    for t in titles:
        if not isinstance(t, dict) or not t.get("installable", True):
            continue
        gid, title = t.get("id"), t.get("title")
        token = f"{store}:{gid}"
        if not isinstance(gid, str) or not shortcuts.TOKEN.fullmatch(token) or token in registry:
            continue
        out.append({"id": gid, "title": title if isinstance(title, str) and title else gid})
    return out


def wanting_art(store, registry):
    """[(gid, appid)] for every entry of the store with no art recorded, in registry order. A row
    gets `art_ok` (the kinds applied) only once SetCustomArtworkForApp took EVERY kind the store
    had a url for, so a tile whose fetch failed in whole or in part -- a CDN timeout on the capsule,
    a SteamUI that was not listening yet -- is asked for again by the next sync instead of
    keeping its name tile (or a blank tile with a backdrop) for good. Both stores' sources
    are cheap to re-ask (Epic: legendary's local cache; GOG: one unauthenticated GET per tile),
    but only tiles WITHOUT art are, so a settled library costs a sync nothing."""
    out = []
    for token, row in registry.items():
        if not token.startswith(f"{store}:") or not isinstance(row, dict) or row.get("art_ok"):
            continue
        appid = shortcuts._u32(row.get("appid"))
        if appid is not None:
            out.append((token.split(":", 1)[1], appid))
    return out


def tab_members(registry):
    """{store: [unsigned appid], "installed": [unsigned appid]} — what the library tabs show
    (revision 2, R2). Each store's tab: every registered entry of that store, installed or not, by
    its LIVE appid. "installed": the entries that are installed games, which Steam's own Installed
    tab adds to its list — Steam leaves every shortcut out of it, since to Steam a not-installed
    stub tile looks just as installed as a game. The same registry rule as the game page, so no
    tab can list a shortcut that is not ours. Retired appids are not members: those entries are
    on their way out of the library."""
    out = {store: [] for store in locations.STORE_DIRS} | {"installed": []}
    for token, row in registry.items():
        if not shortcuts.TOKEN.fullmatch(token) or not isinstance(row, dict):
            continue
        appid = shortcuts._u32(row.get("appid"))
        if appid is None:
            continue
        out[token.split(":", 1)[0]].append(appid)
        # A pending_shelf row's game files are gone; only the entry is waiting to be edited back.
        if not shortcuts.is_shelf(row) and row.get("state") != "pending_shelf":
            out["installed"].append(appid)
    return out


