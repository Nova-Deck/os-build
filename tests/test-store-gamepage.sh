#!/usr/bin/env bash
# Offline checks for alien-games milestone 7 revision 2, R1 (.claude/plans/alien-games-panel.plan.md):
# the game page's Play row — Install / progress / Resume / Uninstall on Steam's own page for a
# NovaDeck entry, decided by the backend from the registry and the install activity.
#
#   tests/test-store-gamepage.sh
#
# WHY THIS FILE EXISTS. The page is patched into EVERY shortcut's page, so the decision that
# matters most is the refusal: an appid that is not ours (the user's own shortcuts, an emulator
# front end) must come back "not ours", or our row hides somebody else's Play. The second is the
# page outliving its appid: a finished install and an uninstall both REPLACE the entry, so the
# page has to find the entry's new appid through the token it already knew.
#
# WHAT IT CANNOT PROVE: that the anchors resolve on the arm64 client, or how the row looks and
# focuses. Those are the R4 hardware walkthrough.
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

echo "== page decisions"
pysuite "decisions" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])

def ok(m): print(f"  ok   {m}")
def bad(m): print(f"  FAIL {m}")

from novadeck_stores import game_page as gp

SIGNED = -1294967296          # the same entry as 3000000000, as the live API may hand it over
registry = {"epic:A": {"appid": 3000000000, "title": "Alba", "state": "shelf"},
            "gog:B": {"appid": 3000000001, "title": "Bee", "exe": "/g/b.exe"},
            "gog:C": {"appid": 3000000002, "title": "Cee", "state": "pending_shelf"},
            "epic:R": {"appid": 3000000003, "title": "Arr", "retired": [3000000009]},
            "../x": {"appid": 3000000004, "title": "forged"},
            "epic:junk": "not a row"}

(ok if gp.find(registry, 3000000000)[0] == "epic:A" else bad)("an entry is found by its live appid")
(ok if gp.find(registry, SIGNED)[0] == "epic:A" else bad)("a signed appid names the same entry as the unsigned one")
(ok if gp.find(registry, 12345) == (None, None) else bad)("an appid the registry does not hold is not ours")
(ok if gp.find(registry, 3000000009) == (None, None) else bad)(
    "a RETIRED appid is not a page of ours — that entry is on its way out")
(ok if gp.find(registry, 3000000004) == (None, None) else bad)("a row under a malformed token is never answered for")
(ok if gp.find(registry, 777, "epic:A")[0] == "epic:A" else bad)(
    "a page whose entry was replaced finds it again through the token it knew")
(ok if gp.find(registry, 777, "epic:missing") == (None, None) else bad)("a token the registry no longer holds is not ours")
(ok if gp.find(registry, 777, "../x") == (None, None) else bad)("a malformed token from the page is refused")
(ok if gp.find(registry, True) == (None, None) else bad)("a bool is not an appid")

def state(token, items=(), **kw):
    return gp.page_state(token, registry[token], list(items))

s = state("epic:A")
(ok if s["state"] == "install" and s["ours"] and s["appid"] == 3000000000 and s["title"] == "Alba" else bad)(
    f"a shelf tile with nothing on disk offers Install ({s})")
s = state("epic:A", [{"store": "epic", "id": "A", "state": "downloading", "percent": 41.5}])
(ok if s["state"] == "downloading" and s["percent"] == 41.5 else bad)(f"a running install shows its progress ({s})")
s = state("epic:A", [{"store": "epic", "id": "A", "state": "downloading"}])
(ok if s["state"] == "downloading" and "percent" not in s else bad)("a download with no progress line yet has no made-up percent")
s = state("epic:A", [{"store": "epic", "id": "A", "state": "interrupted"}])
(ok if s["state"] == "paused" else bad)(f"a stopped or failed install is paused, resumable ({s})")
s = state("epic:A", [{"store": "epic", "id": "A", "state": "installed"}])
(ok if s["state"] == "finishing" else bad)(
    f"installed on disk but still a shelf tile is finishing — the swap is seconds away ({s})")
s = state("epic:A", [{"store": "gog", "id": "B", "title": "Bee", "state": "downloading"}])
(ok if s["state"] == "install" and s.get("busy") == "Bee" else bad)(
    f"Install names the game already downloading — there is one install at a time ({s})")
s = state("epic:A", [{"store": "epic", "id": "A", "state": "interrupted"},
                     {"store": "gog", "id": "B", "title": "Bee", "state": "downloading"}])
(ok if s["state"] == "paused" and s.get("busy") == "Bee" else bad)("Resume is told about the other download too")
s = state("gog:B")
(ok if s["state"] == "installed" else bad)(f"the model-B entry is installed: Steam's own Play stays ({s})")
s = state("gog:C")
(ok if s["state"] == "stale" else bad)(f"an uninstalled entry whose swap failed is stale, not playable ({s})")
s = state("epic:R")
(ok if s["state"] == "installed" and s["appid"] == 3000000003 else bad)("a row with retired appids answers with its live one")
PY

echo "== the backend"
pysuite "backend" <<'PY'
import asyncio, json, os, pathlib, sys, tempfile, types
sys.path.insert(0, sys.argv[1])

def ok(m): print(f"  ok   {m}")
def bad(m): print(f"  FAIL {m}")

async def fake_emit(*a): pass
sys.modules["decky"] = types.SimpleNamespace(logger=types.SimpleNamespace(info=lambda *a: None), emit=fake_emit)
sys.path.insert(0, os.path.join(sys.argv[1], ".."))
import main

tmp = pathlib.Path(tempfile.mkdtemp(prefix="store-gamepage."))
p = {"NOVADECK_STORE_HOME": str(tmp), "NOVADECK_STORE_UID": str(os.getuid()), "NOVADECK_STORE_USER": "deck",
     "NOVADECK_GOGDL_AUTH": str(tmp / "auth.json")}
main.paths.store_paths = lambda ensure=False: p
(tmp / "shortcuts.json").write_text(json.dumps({"epic:A": {"appid": 3000000000, "title": "A", "state": "shelf"}}))
status_calls = []
def fake_status(pp):
    status_calls.append(1)
    return {"installs": []}
main.installs.install_status = fake_status
vols = [{"path": "/home/deck", "label": "Internal", "free": 5}, {"path": "/run/media/deck/SD", "label": "SD", "free": 9}]
main.locations.user_volumes = lambda user: vols
(tmp / "settings.json").write_text(json.dumps({"install_drive": "/run/media/deck/SD"}))

plugin = main.Plugin()
s = asyncio.run(plugin.game_state(424242))
(ok if s == {"ours": False} and not status_calls else bad)(
    f"another shortcut's page is answered from the registry alone — no systemctl per page ({s}, {len(status_calls)})")
s = asyncio.run(plugin.game_state(3000000000))
(ok if s["state"] == "install" and s["drive"] == {"label": "SD", "free": 9} else bad)(
    f"Install says where it will go: the preferred drive, as a tile press would ({s.get('drive')})")
s = asyncio.run(plugin.game_state(-1294967296))
(ok if s.get("token") == "epic:A" and s["appid"] == 3000000000 else bad)(
    f"a signed appid from the page finds the entry and answers unsigned ({s.get('appid')})")
# The swap: an install finished, the entry was removed and re-added under a new appid.
(tmp / "shortcuts.json").write_text(json.dumps({"epic:A": {"appid": 3000000077, "title": "A", "exe": "/g/a.exe"}}))
s = asyncio.run(plugin.game_state(3000000000, "epic:A"))
(ok if s.get("appid") == 3000000077 and s["state"] == "installed" else bad)(
    f"a page open across the swap gets the entry's NEW appid through its token, to move to ({s})")
s = asyncio.run(plugin.game_state(3000000000))
(ok if s == {"ours": False} else bad)(f"without the token the old appid is nobody's ({s})")
(tmp / "shortcuts.json").write_text(json.dumps({"epic:A": {"appid": 3000000000, "title": "A", "state": "shelf"}}))
main.installs.install_status = lambda pp: {"installs": [{"store": "gog", "id": "B", "title": "Bee", "state": "downloading"}]}
s = asyncio.run(plugin.game_state(3000000000))
(ok if s.get("busy") == "Bee" else bad)(f"the backend passes on which game holds the install slot ({s.get('busy')})")
main.installs.install_status = lambda pp: {"error": "status failed: OSError"}
s = asyncio.run(plugin.game_state(3000000000))
(ok if s == {"error": "status failed: OSError"} else bad)(f"an unreadable install status is an error, never 'Install' ({s})")
def malformed(pp):
    return {"installs": [{}]}["installs"][0]["store"]   # what a record missing its keys raises
main.installs.install_status = malformed
s = asyncio.run(plugin.game_state(3000000000))
(ok if s == {"error": "the install records are unreadable"} else bad)(
    f"a malformed install record is a worded error, never a raw exception on every poll ({s})")

calls = []
def fake_capture(pp, argv, timeout):
    calls.append(argv)
    return (0, json.dumps({"manifest": {"disk_size": 1234}}))
main.cli.capture = fake_capture
r1 = asyncio.run(plugin.install_size("epic", "A"))
r2 = asyncio.run(plugin.install_size("epic", "A"))
(ok if r1 == r2 == {"disk_size": 1234} and len(calls) == 1 else bad)(
    f"the size is asked of the store once and cached — every visit would be a login ({r1}, {len(calls)} calls)")
main.cli.capture = lambda pp, argv, timeout: (0, json.dumps(
    {"folder_name": "Bee", "size": {"*": {"disk_size": 100}, "en-US": {"disk_size": 7}, "de-DE": {"disk_size": 9}}}))
r = asyncio.run(plugin.install_size("gog", "G"))
(ok if r == {"disk_size": 109} else bad)(f"a GOG size is the common depots plus the largest language ({r})")
main.cli.capture = lambda pp, argv, timeout: (1, "")
r = asyncio.run(plugin.install_size("gog", "B"))
(ok if "error" in r and "gog:B" not in plugin._info else bad)(f"a failed lookup is an error and is NOT cached ({r})")

# The press reuses what the page already asked: no second login that can flake (HW 2026-10-22).
seen = {}
def fake_install(store, gid, title, drive, pp, vols=None, info=None):
    seen["info"] = info
    return {"started": True, "path": "/x"}
main.installs.install = fake_install
asyncio.run(plugin.install("epic", "A", "A", "/home/deck"))
(ok if seen.get("info") == {"disk_size": 1234, "folder": "A"} else bad)(
    f"install() is handed the page's cached store info ({seen.get('info')})")
asyncio.run(plugin.install("epic", "Uncached", "U", "/home/deck"))
(ok if seen.get("info") is None else bad)("with nothing cached, install() asks the store itself")

from novadeck_stores import shortcuts
(ok if shortcuts.remove_payload(1, 5, moved_to=-7)["moved_to"] == -7 and "moved_to" not in shortcuts.remove_payload(1, 5)
 else bad)("a removal names its replacement only when there is one")
r = asyncio.run(plugin.install_size("epic", "../x"))
(ok if "error" in r else bad)(f"a malformed id is refused before any CLI runs ({r})")
PY

echo "== the frontend"
SRC="$ROOT/apps/decky/novadeck-stores/src"
grep -q 'const removeGamePagePatch = applyGamePagePatch()' "$SRC/index.tsx" \
  && grep -A12 'onDismount()' "$SRC/index.tsx" | grep -q 'removeGamePagePatch()' \
  && ok "the game-page patch is applied at load and removed at dismount" \
  || bad "index.tsx does not apply AND remove the game-page patch"
grep -q 'basicAppDetailsSectionStylerClasses' "$SRC/GamePage.tsx" \
  && ok "the native Play row is hidden by Gaming Mode's PlaySection class (R0: play Container is absent)" \
  || bad "GamePage.tsx does not hide by basicAppDetailsSectionStylerClasses.PlaySection"
grep -q 'appDetailsHeaderClasses' "$SRC/GamePage.tsx" \
  && ok "the row is anchored after the header (R0: unifideck's fallback anchor)" \
  || bad "GamePage.tsx does not anchor on the app-details header"
[ -f "$SRC/GamePage.tsx" ] && ! grep -q '2_000_000_000\|2000000000' "$SRC/GamePage.tsx" \
  && ok "ownership is the backend's registry answer, never unifideck's appid threshold" \
  || bad "GamePage.tsx gates on an appid threshold (unifideck's rule, not ours)"

BRIDGE="$SRC/lib/shortcutBridge.ts"
grep -B2 'apps.RemoveShortcut(op.appid' "$BRIDGE" | grep -q 'followReplacement' \
  && ok "the bridge moves an open page to the replacement BEFORE removing (Steam sends it home otherwise)" \
  || bad "shortcutBridge.ts removes an entry without first moving its open page"

grep -q 'test-store-gamepage.sh' "$ROOT/Makefile" \
  && ok "this suite is wired into make test (a suite nothing runs is documentation)" \
  || bad "tests/test-store-gamepage.sh is not in the Makefile test target"

echo
echo "test-store-gamepage.sh: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
