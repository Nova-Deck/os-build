"""What Steam's own game page shows for one of our library entries (milestone 7 revision 2, R1).

The frontend patches the Play row of EVERY shortcut's page, and the page knows nothing but its
appid. Everything it shows is decided here, from the registry and the install activity:

  install      a shelf tile with nothing on disk: Install
  downloading  the install unit is running it: progress and Stop
  paused       a record that is neither running nor done: Resume and Remove
  finishing    the CLI says done, the swap to the model-B entry has not run yet (seconds)
  installed    the model-B entry: Steam's own Play stays, the page adds Uninstall
  stale        uninstalled, but the swap back to a shelf tile failed: nothing to play

An appid the registry does not hold is NOT OURS, and the page leaves it alone — the user's own
shortcuts get Steam's page untouched. Read-only, like install_status: the page polls it.
"""
from novadeck_stores import shortcuts


def find(registry, appid, token=None):
    """(token, row) for the entry whose LIVE appid is `appid`, else (None, None).

    `token` is what this page was told on an earlier poll. A finished install and an uninstall
    both REPLACE the entry (remove + re-add), so a page that is open across one outlives its
    appid; the token is how it finds the entry's new one. A retired appid alone answers nothing:
    that entry is on its way out of the library.
    """
    want = shortcuts._u32(appid)
    if want is not None:
        for t, row in registry.items():
            if shortcuts.TOKEN.fullmatch(t) and isinstance(row, dict) \
                    and shortcuts._u32(row.get("appid")) == want:
                return t, row
    if isinstance(token, str) and shortcuts.TOKEN.fullmatch(token):
        row = registry.get(token)
        if isinstance(row, dict) and shortcuts._u32(row.get("appid")) is not None:
            return token, row
    return None, None


def page_state(token, row, items):
    """The page's state for one found entry; `items` is install_status()["installs"]."""
    store, gid = token.split(":", 1)
    out = {"ours": True, "token": token, "store": store, "id": gid,
           "title": row.get("title") or gid, "appid": shortcuts._u32(row["appid"])}
    if not shortcuts.is_shelf(row):
        return {**out, "state": "stale" if row.get("state") == "pending_shelf" else "installed"}
    mine = next((i for i in items if i.get("store") == store and i.get("id") == gid), None)
    other = next((i for i in items if i is not mine and i.get("state") == "downloading"), None)
    if mine is not None and mine.get("state") == "downloading":
        return {**out, "state": "downloading",
                **({"percent": mine["percent"]} if "percent" in mine else {})}
    if mine is not None and mine.get("state") == "installed":
        return {**out, "state": "finishing"}
    # There is one install at a time: say which game holds it, rather than offering a press that
    # can only answer "another game is installing".
    busy = {"busy": other.get("title") or other.get("id")} if other is not None else {}
    return {**out, "state": "paused" if mine is not None else "install", **busy}
