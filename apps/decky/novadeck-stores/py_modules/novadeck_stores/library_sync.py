"""Library-first (milestone 7): every owned game is a Steam tile, grouped in collections.

This module DECIDES; main.py carries the decisions out through the frontend bridge. A sync is:

  1. which owned titles still need a not-installed tile (to_shelve), and
  2. what the [NovaDeck] collections should hold afterwards (collection_ops).

Both are pure functions of the store's owned list and our registry, so a re-sync is idempotent:
a title with a registry row — shelf tile or installed entry — is never added twice, and the
collection memberships are re-asserted in full rather than patched, so one that drifted (a crash
between an add and its collection op, a user who dragged a tile out) heals on the next sync.

A title the store says cannot be installed (an Epic ThirdPartyManagedApp: no Epic assets at all,
library.py) gets no tile. A tile exists to be pressed, and pressing that one could only fail.
"""
from novadeck_stores import locations, shortcuts

PREFIX = "[NovaDeck] "
NOT_INSTALLED = f"{PREFIX}Not Installed"


def store_collection(store):
    return f"{PREFIX}{locations.STORE_DIRS[store]}"


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


def collection_ops(store, registry):
    """The full membership this store's rows imply:
      [NovaDeck] <Store>    every registered appid of this store
      [NovaDeck] Not Installed  this store's shelf tiles in, its installed entries out
    The other store's rows are not touched — each store's sync owns only its own."""
    rows = [row for token, row in registry.items()
            if token.startswith(f"{store}:") and isinstance(row, dict) and "appid" in row]
    shelf = [row["appid"] for row in rows if shortcuts.is_shelf(row)]
    installed = [row["appid"] for row in rows if not shortcuts.is_shelf(row)]
    return [
        {"name": store_collection(store), "add": [row["appid"] for row in rows], "remove": []},
        {"name": NOT_INSTALLED, "add": shelf, "remove": installed},
    ]


def collection_payload(req, op):
    return {"op": "collection", "req": req, "name": op["name"],
            "add": [int(a) for a in op["add"]], "remove": [int(a) for a in op["remove"]]}
