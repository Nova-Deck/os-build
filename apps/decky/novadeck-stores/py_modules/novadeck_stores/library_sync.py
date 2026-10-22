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


def tab_members(registry):
    """{store: [unsigned appid]} — what each store's library tab shows (revision 2, R2): every
    registered entry of that store, installed or not, by its LIVE appid. The same registry rule as
    the game page, so a tab can never list a shortcut that is not ours. Retired appids are not
    members: those entries are on their way out of the library."""
    out = {store: [] for store in locations.STORE_DIRS}
    for token, row in registry.items():
        if not shortcuts.TOKEN.fullmatch(token) or not isinstance(row, dict):
            continue
        appid = shortcuts._u32(row.get("appid"))
        if appid is not None:
            out[token.split(":", 1)[0]].append(appid)
    return out


