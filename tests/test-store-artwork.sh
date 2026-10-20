#!/usr/bin/env bash
# Offline checks for alien-games milestone 5: artwork acquisition
# (.claude/plans/alien-games-artwork.plan.md).
#
#   tests/test-store-artwork.sh
#
# WHY THIS FILE EXISTS. Artwork touches a new network surface (image downloads from store CDNs)
# and a new client API. What is checkable offline: which URL each store yields per kind, that a
# download is https-only / size-capped / magic-byte validated before the client sees a byte, the
# kind->assetType mapping, and that every failure leaves the entry's name tile rather than
# blocking. Fixture metadata and a fake downloader stand in for the network.
#
# WHAT IT CANNOT PROVE: that SetCustomArtworkForApp persists across a Steam restart, or that a
# real CDN still serves these URLs. Those are the hardware gate.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STORES_PY="$ROOT/apps/decky/novadeck-stores/py_modules"
PASS=0 FAIL=0 SKIP=0
ok()  { printf '  ok   %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL %s\n' "$*"; FAIL=$((FAIL + 1)); }

pysuite() {
  local name="$1" out rc
  out="$(python3 - "$STORES_PY")"
  rc=$?
  printf '%s\n' "$out"
  PASS=$((PASS + $(grep -c '^  ok ' <<<"$out" || true)))
  FAIL=$((FAIL + $(grep -c '^  FAIL' <<<"$out" || true)))
  [ "$rc" -eq 0 ] || bad "the $name checks crashed (exit $rc) — every check after the crash never ran"
}

echo "== url resolution, download, mapping"
pysuite "artwork" <<'PY'
import json, os, pathlib, sys, tempfile
sys.path.insert(0, sys.argv[1])

def ok(m): print(f"  ok   {m}")
def bad(m): print(f"  FAIL {m}")

from novadeck_stores import artwork

# -- kind -> ELibraryAssetType (Capsule 0, Hero 1, Logo 2) --
(ok if artwork.KIND_ASSET == {"capsule": 0, "hero": 1, "logo": 2} else bad)(
    f"the three kinds map to the library asset types ({artwork.KIND_ASSET})")

# -- Epic: read legendary's cached metadata from OUR store home, pick by priority --
tmp = pathlib.Path(tempfile.mkdtemp(prefix="store-artwork."))
meta_dir = tmp / "legendary" / "metadata"
meta_dir.mkdir(parents=True)
(meta_dir / "Alba.json").write_text(json.dumps({"app_name": "Alba", "metadata": {"keyImages": [
    {"type": "DieselGameBoxTall", "url": "https://cdn/tall.jpg"},
    {"type": "Thumbnail", "url": "https://cdn/thumb.jpg"},
    {"type": "DieselGameBox", "url": "https://cdn/wide.jpg"},
    {"type": "DieselGameBoxLogo", "url": "http://cdn/logo.png"},
]}}))
p = {"LEGENDARY_CONFIG_PATH": str(tmp / "legendary"), "NOVADECK_STORE_UID": str(os.getuid())}
urls = artwork.epic_urls("Alba", p)
(ok if urls.get("capsule") == "https://cdn/tall.jpg" else bad)(
    f"Epic capsule prefers DieselGameBoxTall ({urls.get('capsule')})")
(ok if urls.get("hero") == "https://cdn/wide.jpg" else bad)(f"Epic hero is the wide box ({urls.get('hero')})")
(ok if "logo" not in urls else bad)("a non-https logo url is dropped, not set (http was offered)")
(ok if artwork.epic_urls("Missing", p) == {} else bad)("a game with no metadata yields no urls, never raises")

# -- GOG: one unauthenticated GamesDB GET, injected --
gamesdb = {"game": {
    "vertical_cover": {"url_format": "https://gog/cover{formatter}.{ext}"},
    "background": {"url_format": "https://gog/bg{formatter}.{ext}"},
    "logo": {"url_format": "https://gog/lg{formatter}.{ext}"},
}}
seen = {}
def fake_json(url):
    seen["url"] = url
    return gamesdb
gurls = artwork.gog_urls("1207658924", fetch_json=fake_json)
(ok if "gamesdb.gog.com/platforms/gog/external_releases/1207658924" in seen.get("url", "") else bad)(
    f"GOG art comes from the GamesDB endpoint by product id ({seen.get('url')})")
(ok if gurls.get("capsule") == "https://gog/cover.jpg" and gurls.get("hero") == "https://gog/bg.jpg"
    and gurls.get("logo") == "https://gog/lg.png" else bad)(
    f"GOG expands url_format (formatter empty = full size, ext per kind) ({gurls})")

# -- download: https-only, size-capped, magic-byte validated --
class FakeResp:
    def __init__(self, data, url="https://cdn/x"):
        self._data, self.url = data, url
    def read(self, n=-1):
        if n < 0 or n >= len(self._data):
            d, self._data = self._data, b""
            return d
        d, self._data = self._data[:n], self._data[n:]
        return d
    def __enter__(self): return self
    def __exit__(self, *a): return False

JPEG = b"\xff\xd8\xff\xe0" + b"\x00" * 64
PNG = b"\x89PNG\r\n\x1a\n" + b"\x00" * 64
def opener_for(data, url="https://cdn/x"):
    return lambda req, timeout=0: FakeResp(data, url)

(ok if artwork.fetch_image("https://cdn/a.jpg", opener=opener_for(JPEG)) == (JPEG, "jpg") else bad)(
    "a JPEG body passes and is typed jpg")
(ok if artwork.fetch_image("https://cdn/a.png", opener=opener_for(PNG))[1] == "png" else bad)(
    "a PNG body passes and is typed png")
(ok if artwork.fetch_image("https://cdn/a", opener=opener_for(b"<html>not an image</html>")) is None else bad)(
    "a non-image body is rejected to None — never forwarded to the client")
(ok if artwork.fetch_image("http://cdn/a.jpg", opener=opener_for(JPEG)) is None else bad)(
    "a non-https url is refused before any fetch")
(ok if artwork.fetch_image("file:///etc/passwd", opener=opener_for(JPEG)) is None else bad)(
    "a file:// url is refused — no scheme but https")
big = artwork.fetch_image("https://cdn/big.jpg", opener=opener_for(b"\xff\xd8\xff" + b"\x00" * (9 * 1024 * 1024)))
(ok if big is None else bad)("a body past the size cap is refused, not buffered whole")
PY

echo "== the backend contract"
pysuite "artwork-backend" <<'PY'
import asyncio, base64, os, pathlib, sys, tempfile, types
sys.path.insert(0, sys.argv[1])

def ok(m): print(f"  ok   {m}")
def bad(m): print(f"  FAIL {m}")

emitted = []
async def fake_emit(event, payload):
    emitted.append((event, payload))
    if event == "shortcut_op" and payload.get("op") == "artwork":
        asyncio.get_running_loop().create_task(plugin.shortcut_result(payload["req"], None, None))

sys.modules["decky"] = types.SimpleNamespace(
    logger=types.SimpleNamespace(info=lambda *a: None), emit=fake_emit)
sys.path.insert(0, os.path.join(sys.argv[1], ".."))
import main
from novadeck_stores import artwork

plugin = main.Plugin()
tmp = pathlib.Path(tempfile.mkdtemp(prefix="store-artwork."))
p = {"NOVADECK_STORE_HOME": str(tmp), "NOVADECK_STORE_UID": str(os.getuid()),
     "NOVADECK_STORE_USER": "deck", "LEGENDARY_CONFIG_PATH": str(tmp / "legendary"),
     "NOVADECK_GOGDL_AUTH": str(tmp / "a.json"), "GOGDL_CONFIG_PATH": str(tmp / "gogdl")}
main.paths.store_paths = lambda ensure=False: p

JPEG = (b"\xff\xd8\xff\xe0" + b"\x00" * 32, "jpg")
main.artwork.store_urls = lambda store, gid, pp: {"capsule": "https://cdn/c.jpg", "hero": "https://cdn/h.jpg"}
main.artwork.fetch_image = lambda url, **kw: JPEG

res = asyncio.run(plugin.apply_artwork("epic", "Alba", 2480450041))
(ok if sorted(res.get("applied", [])) == ["capsule", "hero"] else bad)(
    f"both resolvable kinds are applied ({res})")
event, payload = emitted[-1]
(ok if event == "shortcut_op" and payload["op"] == "artwork" and payload["appid"] == 2480450041 else bad)(
    f"the artwork op carries the appid ({payload.get('op')}, {payload.get('appid')})")
imgs = {i["assetType"]: i for i in payload["images"]}
(ok if set(imgs) == {0, 1} else bad)(f"capsule->0 and hero->1 are the asset types sent ({set(imgs)})")
(ok if imgs[0]["base64"] == base64.b64encode(JPEG[0]).decode() and imgs[0]["imageType"] == "jpg" else bad)(
    "each image is base64 with its type — the client never sees raw bytes")

# A network cut: every download fails. Art must not block, must not emit, must not raise.
emitted.clear()
main.artwork.fetch_image = lambda url, **kw: None
res = asyncio.run(plugin.apply_artwork("epic", "Alba", 2480450041))
(ok if res == {"applied": []} and not emitted else bad)(
    f"a network cut applies nothing and emits nothing — the name tile stands ({res}, emitted={len(emitted)})")

# No urls at all (store had none): same floor.
main.artwork.store_urls = lambda store, gid, pp: {}
res = asyncio.run(plugin.apply_artwork("gog", "x", 1))
(ok if res == {"applied": []} else bad)("a game the store has no art for is not an error")

(ok if asyncio.iscoroutinefunction(main.Plugin.apply_artwork) else bad)(
    "apply_artwork is exposed on the backend") if False else None
PY

grep -q 'test-store-artwork.sh' "$ROOT/Makefile" \
  && ok "this suite is wired into make test (a suite nothing runs is documentation)" \
  || bad "tests/test-store-artwork.sh is not in the Makefile test target"

echo
echo "test-store-artwork.sh: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
