"""Store-native grid art for alien-game library entries.

Art is set through Steam's own SetCustomArtworkForApp (milestone 5), so this module only RESOLVES
a URL per kind and DOWNLOADS it safely; the frontend bridge makes the client call. The source is
each store's own metadata — no SteamGridDB, so no new key and nothing to degrade when a key
service is down (the PRD risk table wants art to degrade, never block).

  Epic  legendary already caches keyImages per game under OUR store home — no network at all.
  GOG   one unauthenticated GET to the GamesDB endpoint, so root may fetch it without a token.

Every path here is best-effort: a kind with no source, a non-https url, an unreachable host or a
body that is not an image all resolve to "no art for this kind", never to an exception reaching
apply_artwork. The entry keeps its name tile; art is the bonus.
"""
import http.client
import json
import os
import ssl
import urllib.parse
import urllib.request

from novadeck_stores import status

# kind -> ELibraryAssetType (App.ts: Capsule 0, Hero 1, Logo 2). Icon/Header/HeroBlur are not
# sourced this milestone — the capsule is what prevents a broken tile.
KIND_ASSET = {"capsule": 0, "hero": 1, "logo": 2}

# A download is untrusted input from a store CDN. See fetch_image.
MAX_BYTES = 8 * 1024 * 1024
TIMEOUT = 20
_MAGIC = ((b"\xff\xd8\xff", "jpg"), (b"\x89PNG\r\n\x1a\n", "png"))

GAMESDB_URL = "https://gamesdb.gog.com/platforms/gog/external_releases/{id}"

# Epic keyImages types per kind, first match wins (the names Epic uses, widest-support first).
_EPIC_PRIORITY = {
    "capsule": ("DieselGameBoxTall", "OfferImageTall", "DieselStoreFrontTall", "Thumbnail"),
    "hero": ("DieselGameBox", "DieselGameBoxWide", "OfferImageWide"),
    "logo": ("DieselGameBoxLogo", "ProductLogo"),
}
# GOG GamesDB field per kind, with the extension its url_format expands to.
_GOG_FIELD = {"capsule": ("vertical_cover", "jpg"), "hero": ("background", "jpg"),
              "logo": ("logo", "png")}


def _https(url):
    """A url we are willing to fetch, or None. https only — the one network surface here must not
    be talked into a file:// read or a cleartext fetch by a url from store metadata."""
    return url if isinstance(url, str) and url.startswith("https://") else None


def epic_urls(gid, p):
    """{kind: https url} from legendary's cached metadata, read owner-checked like every other
    store file. No network. Absent metadata or a bad file yields {}."""
    path = os.path.join(p["LEGENDARY_CONFIG_PATH"], "metadata", f"{gid}.json")
    f = status.open_user_file(path, int(p["NOVADECK_STORE_UID"]))
    if f is None:
        return {}
    try:
        with f:
            data = json.loads(f.read().decode("utf-8", "replace"))
    except (OSError, ValueError):
        return {}
    images = data.get("keyImages") or data.get("metadata", {}).get("keyImages") or []
    if not isinstance(images, list):
        return {}
    by_type = {img["type"]: img["url"] for img in images
               if isinstance(img, dict) and isinstance(img.get("type"), str) and "url" in img}
    out = {}
    for kind, types in _EPIC_PRIORITY.items():
        for t in types:
            url = _https(by_type.get(t))
            if url:
                out[kind] = url
                break
    return out


def _gamesdb_url(entry, ext):
    """A GamesDB image object -> a concrete https url. The API gives a `url_format` carrying two
    placeholders: `{formatter}` (a size variant — empty is the full-size asset) and `{ext}`."""
    if not isinstance(entry, dict):
        return None
    fmt = entry.get("url_format")
    if isinstance(fmt, str):
        return _https(fmt.replace("{formatter}", "").replace("{ext}", ext))
    # Older shape: a plain url.
    return _https(entry.get("url"))


def _default_fetch_json(url):
    req = urllib.request.Request(url, headers={"User-Agent": "novadeck"})
    with urllib.request.urlopen(req, timeout=TIMEOUT, context=tls_context()) as resp:
        return json.loads(resp.read(MAX_BYTES).decode("utf-8", "replace"))


def gog_urls(gid, fetch_json=_default_fetch_json):
    """{kind: https url} from the unauthenticated GamesDB endpoint. A network failure yields {}."""
    try:
        data = fetch_json(GAMESDB_URL.format(id=int(gid)))
    except (OSError, ValueError, TypeError):
        return {}
    game = data.get("game") if isinstance(data, dict) else None
    if not isinstance(game, dict):
        return {}
    out = {}
    for kind, (field, ext) in _GOG_FIELD.items():
        url = _gamesdb_url(game.get(field), ext)
        if url:
            out[kind] = url
    return out


def store_urls(store, gid, p):
    if store == "epic":
        return epic_urls(gid, p)
    if store == "gog":
        return gog_urls(gid)
    return {}


# The system CA bundle, named explicitly. The plugin runs in Decky's PyInstaller bundle, whose own
# OpenSSL does not look in the system's trust store: every https fetch failed there with
# CERTIFICATE_VERIFY_FAILED ("unable to get local issuer certificate", HW 2026-10-21) while the
# same code passed under the system python. Verification stays ON — this only says where the
# roots are.
CA_BUNDLES = ("/etc/ssl/certs/ca-certificates.crt", "/etc/ssl/cert.pem")


def tls_context(bundles=CA_BUNDLES):
    cafile = next((b for b in bundles if os.path.isfile(b)), None)
    return ssl.create_default_context(cafile=cafile)


def _open(url, timeout):
    return urllib.request.urlopen(url, timeout=timeout, context=tls_context())


def fetch_image(url, opener=_open, log=None):
    """(bytes, 'jpg'|'png') or None. The bytes are untrusted: https only, read incrementally to a
    hard cap so a hostile length cannot exhaust memory, and the leading bytes must be a real JPEG
    or PNG signature before anything is handed back for the client."""
    if not _https(url):
        return None
    # Store CDNs hand out raw paths: Epic's keyImages carry spaces ("...Portrait Store
    # Banner-1200x1600-....jpg", HW 2026-10-21), which http.client refuses outright. Encode what
    # is not already a URL character; existing %-escapes are kept, never double-encoded.
    url = urllib.parse.quote(url, safe=":/?#[]@!$&'()*+,;=%~")
    try:
        with opener(url, timeout=TIMEOUT) as resp:
            # One byte past the cap so a body AT the cap is kept and a larger one is refused.
            data = resp.read(MAX_BYTES + 1)
    # HTTPException too: InvalidURL and a malformed response are neither OSError nor ValueError,
    # and one escaping here ended the whole background art pass at the first such tile.
    except (OSError, ValueError, http.client.HTTPException) as exc:
        # Still None — art never blocks — but say why: a TLS or network fault inside Decky's
        # bundled Python looks exactly like "no art" otherwise.
        if log:
            log(f"artwork fetch failed: {type(exc).__name__}: {exc}")
        return None
    return _image(data)


def _image(data):
    """(bytes, 'jpg'|'png') for a real JPEG or PNG within the cap, else None."""
    if not isinstance(data, bytes) or len(data) > MAX_BYTES:
        return None
    for magic, kind in _MAGIC:
        if data.startswith(magic):
            return data, kind
    return None
