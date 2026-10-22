"""What each store account owns: [{id, title, installable[, requires]}].

Epic comes from `legendary list --json`. GOG has no CLI that lists a library, so it comes from
/usr/lib/novadeck/store-gog-owned, which asks GOG's API through gogdl's own session. Both run as
the store user through systemd-run (cli.py). Root never holds a token here, and the only output
read back is the list itself.

"Owned" and "installable" are different sets, and the difference is shown rather than hidden.
Epic draws it twice: a ThirdPartyManagedApp title (Origin / the EA App) has no Epic assets at all
and cannot be downloaded, while a partnerLinkType title (Ubisoft) downloads fine and needs its
launcher only to RUN — both carry `requires`, but only the first is `installable: False`
(measured on HW 2026-10-20; legendary's own model makes the same split). A GOG title with no
Windows build has nothing this milestone can download.
"""
import json
import subprocess

from novadeck_stores import cli

GOG_OWNED = "/usr/lib/novadeck/store-gog-owned"
# legendary list fetches the whole catalogue metadata on a cold cache; 55 titles took seconds on
# hardware, but a large library over a slow link can take much longer.
LIST_TIMEOUT = 180


def list_argv(store, p):
    if store == "epic":
        return ["legendary", "list", "--json"]
    if store == "gog":
        return [GOG_OWNED, p["NOVADECK_GOGDL_AUTH"]]
    raise ValueError(f"unknown store {store!r}")


def epic_titles(text):
    """Parse legendary's JSON list, or None when it is not one: an empty library and a broken
    answer must not look the same."""
    try:
        games = json.loads(text)
    except ValueError:
        return None
    if not isinstance(games, list):
        return None
    titles = []
    for game in games:
        meta = game.get("metadata") or {}
        attrs = meta.get("customAttributes") or {}
        third_party = (attrs.get("ThirdPartyManagedApp") or {}).get("value")
        partner_link = (attrs.get("partnerLinkType") or {}).get("value")
        # Epic's "digital extras" bundle (a soundtrack, an artbook) is its own owned item with no
        # mainGameItem, so legendary does not hide it as DLC — only this category says it is not
        # a game. It downloads, but nothing in it launches (Death Stranding Content, HW 2026-10-22).
        extras = any(isinstance(c, dict) and c.get("path") == "digitalextras"
                     for c in meta.get("categories") or [])
        title = {"id": game["app_name"], "title": game.get("app_title") or game["app_name"],
                 "installable": not third_party and not extras}
        if third_party or partner_link:
            title["requires"] = third_party or partner_link
        titles.append(title)
    return sorted(titles, key=lambda t: t["title"].casefold())


def _gog_titles(text):
    try:
        titles = json.loads(text)
    except ValueError:
        return None
    return titles if isinstance(titles, list) else None


def owned(store, p):
    """{"titles": [...]} or {"error": ...}. A failure is never an empty list — the panel would
    show it as "you own nothing"."""
    if store not in ("epic", "gog"):
        return {"error": f"unknown store {store!r}"}
    try:
        rc, out = cli.capture(p, list_argv(store, p), LIST_TIMEOUT)
    except (OSError, subprocess.SubprocessError) as exc:
        return {"error": f"cannot list the library: {type(exc).__name__}"}
    titles = (epic_titles if store == "epic" else _gog_titles)(out) if rc == 0 else None
    if titles is None:
        return {"error": f"cannot list the library (exit {rc})"}
    return {"titles": titles}
