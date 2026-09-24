"""Sign-in: where each store's login starts, and how its authorization code is recognised.

The login runs in Steam's own browser (the frontend opens it with NavigateToExternalWeb), so we
hold no handle on the page. What we can see is Steam's CEF target list, and each store's flow
ends on a page we can recognise there:

  GOG   redirects to embed.gog.com/on_login_success?code=... — the code is IN THE URL.
  Epic  lands on www.epicgames.com/id/api/redirect, a JSON document whose "authorizationCode"
        field carries it — the code is in the PAGE BODY, not the URL, so it takes one read of
        the page (cdp.read_body). That page is also loaded BEFORE the login form while signed
        out, with "authorizationCode": null, so a URL match alone proves nothing.

Everything in this module is pure except capture(), whose I/O is injected — the offline suite
drives it with fake target lists, and cdp.py supplies the real ones.

NEVER LOG A CODE. It is single-use and short-lived, but it is a credential for as long as it
lives, and the Decky log is readable by anyone with SSH on a dev card.
"""
import asyncio
import re
import time
from urllib.parse import parse_qs, urlparse

# GOG: the Galaxy client's login, which is what gogdl's token exchange expects the code to be
# issued for (gogdl/auth.py CODE_URL uses the same client id and redirect_uri).
GOG_LOGIN_URL = (
    "https://auth.gog.com/auth?client_id=46899977096215655"
    "&redirect_uri=https%3A%2F%2Fembed.gog.com%2Fon_login_success%3Forigin%3Dclient"
    "&response_type=code&layout=galaxy"
)
GOG_REDIRECT = "https://embed.gog.com/on_login_success"

# Epic: legendary's own login helper. It is a redirect to Epic's login with the redirectUrl
# legendary's client id needs, and legendary maintains it — building that URL here would pin a
# client id legendary can change from its remote config (egs.py update_egs_params).
EPIC_LOGIN_URL = "https://legendary.gl/epiclogin"
EPIC_REDIRECT = "https://www.epicgames.com/id/api/redirect"
_EPIC_CODE = re.compile(r'"authorizationCode"\s*:\s*"([^"]+)"')

LOGIN_URLS = {"epic": EPIC_LOGIN_URL, "gog": GOG_LOGIN_URL}
_REDIRECTS = {"epic": EPIC_REDIRECT, "gog": GOG_REDIRECT}

STORES = tuple(LOGIN_URLS)


def is_redirect(store, url):
    """True when url is the page that ends this store's login. Prefix match on scheme+host+path,
    so a login page that merely MENTIONS the redirect in its own query string does not count."""
    if not isinstance(url, str):
        return False
    parsed = urlparse(url)
    return f"{parsed.scheme}://{parsed.netloc}{parsed.path}" == _REDIRECTS[store]


def code_from_url(url):
    """GOG's code, from the redirect's query string. None when absent or empty."""
    values = parse_qs(urlparse(url).query).get("code")
    return values[0] if values and values[0] else None


def code_from_body(text):
    """Epic's code, from the redirect page's JSON. None for the signed-out null."""
    if not isinstance(text, str):
        return None
    m = _EPIC_CODE.search(text)
    return m.group(1) if m else None


def snapshot(targets):
    """What the target list looked like before the login opened, as {id: url}.

    A redirect page left over from an EARLIER sign-in still carries its code, and that code is
    already spent. Without this, a second connect would capture the stale one on its first poll
    and fail the exchange before the user has even seen the login.
    """
    return {t.get("id"): t.get("url") for t in targets if isinstance(t, dict)}


def _fresh_redirects(store, targets, before):
    for t in targets:
        if not isinstance(t, dict) or not is_redirect(store, t.get("url")):
            continue
        if before.get(t.get("id")) == t.get("url"):
            continue   # the same page that was there before this login began
        yield t


async def capture(store, list_targets, read_body, before, timeout, interval=1.0,
                  clock=time.monotonic, sleep=asyncio.sleep):
    """Poll until this store's redirect carries a code, or timeout. Returns the code or None.

    list_targets() -> list of CDP target dicts ({id, url, webSocketDebuggerUrl, ...}).
    read_body(target) -> the page's text, or None. Only called for Epic.

    A failed poll is not fatal: Steam's CEF port briefly refuses while its web helper restarts,
    and the user is mid-login when that happens. Only the timeout ends the wait.
    """
    deadline = clock() + timeout
    while clock() < deadline:
        try:
            targets = await list_targets()
        except OSError:
            targets = []
        for t in _fresh_redirects(store, targets, before):
            if store == "gog":
                code = code_from_url(t["url"])
            else:
                try:
                    code = code_from_body(await read_body(t))
                except OSError:
                    code = None
            if code:
                return code
        await sleep(interval)
    return None
