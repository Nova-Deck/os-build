"""One-time setup steps a store title needs in its prefix before it first runs.

GOG ships a per-game companion installer (gog-support/<productId>/<exe>, Inno Setup) that writes
what Galaxy's own install would have left behind — registry keys above all. gogdl copies the game
files and nothing else, so without it a title that reads its install key (The Witcher EE:
HKLM\\Software\\CD Projekt RED\\The Witcher) exits silently. Heroic runs these after install
(src/backend/storeManagers/gog/setup.ts); we run them on FIRST PLAY instead, because the prefix is
Steam's and only exists once Steam has launched the shortcut.

This module only DECIDES. It writes `<store home>/first-run.json` — appid → {id, steps} — and
/usr/lib/novadeck/novadeck_firstrun.py (called by game-launch, which fronts every store launch)
runs a title's steps through the very chain Steam composed for it, then records the outcome in
the prefix. Keyed by appid because that is all a launch knows about itself; `id` carries the
build, so an update that ships a new support installer runs it again.

Each step runs with FEX_X87REDUCEDPRECISION=0: the baked Proton's FEX config turns reduced x87
precision on, and that garbles the strings of these 32-bit Delphi installers ("Path not fpund")
until they hang on a hidden error box (HW 2026-10-31, Witcher EE: off → done in 7 s).

Not handled: v2 manifests that want GOG's script interpreter (ISI) — it lives in the redist
depot, which we do not download — and GOG's redistributables (MSVC, DirectX).
"""
import json
import os

from novadeck_stores import cli, installs, status

FILENAME = "first-run.json"
STEP_ENV = {"FEX_X87REDUCEDPRECISION": "0"}
# The argument set HW-proven on Witcher EE — Heroic's, plus /supportDir and a log-free run.
LANGUAGE = "English"


def path(p):
    return os.path.join(p["NOVADECK_STORE_HOME"], FILENAME)


def _manifest(p, gid):
    """gogdl's build manifest for a product, or None."""
    data = status.read_user_json(
        os.path.join(p["GOGDL_CONFIG_PATH"], "heroic_gogdl", "manifests", gid),
        int(p["NOVADECK_STORE_UID"]))
    return data if isinstance(data, dict) else None


def _win(unix_path):
    """A host path as Wine sees it through Z:, which maps /."""
    return "Z:" + unix_path.replace("/", "\\")


def _support_exes(manifest, gid):
    """(productId, relative exe) for every support installer the manifest names for the base game
    and its installed DLCs."""
    wanted = {gid, *(str(d) for d in manifest.get("HGLdlcs") or [] if isinstance(d, (str, int)))}
    if manifest.get("version") == 1:
        commands = (manifest.get("product") or {}).get("support_commands") or []
        return [(str(c["gameID"]), c["executable"]) for c in commands
                if isinstance(c, dict) and isinstance(c.get("executable"), str) and c.get("gameID")
                and {"English", "Neutral"} & set(c.get("languages") or [])]
    if manifest.get("scriptInterpreter"):
        return []
    return [(str(prod["productId"]), prod["temp_executable"]) for prod in manifest.get("products") or []
            if isinstance(prod, dict) and str(prod.get("productId")) in wanted
            and isinstance(prod.get("temp_executable"), str) and prod["temp_executable"]]


def gog_steps(p, gid, install):
    """(steps, buildId) for an installed GOG title; steps is [] when it needs none."""
    manifest = _manifest(p, gid)
    if manifest is None:
        return [], None
    steps = []
    for pid, exe in _support_exes(manifest, gid):
        support = os.path.join(install, "gog-support", pid)
        full = os.path.join(support, exe)
        # A separator in the name would point the step outside this product's support dir.
        if os.path.basename(exe) != exe or not os.path.isfile(full):
            continue
        steps.append({"argv": [
            full, "/VERYSILENT", f"/DIR={_win(install)}", f"/Language={LANGUAGE}",
            f"/LANG={LANGUAGE}", f"/ProductId={pid}", "/galaxyclient",
            f"/buildId={manifest.get('buildId', '')}", "/versionName=",
            "/nodesktopshorctut", "/nodesktopshortcut",  # sic: GOG's typo, and the fix
            f"/lang-code={manifest.get('HGLInstallLanguage') or 'en-US'}",
            f"/supportDir={_win(support)}"], "cwd": install, "env": STEP_ENV})
    return steps, manifest.get("buildId")


def build(p, registry, records):
    """appid (str) → {id, steps} for every installed Windows GOG entry that has steps."""
    out = {}
    for token, row in registry.items():
        store, _, gid = token.partition(":")
        rec = records.get(token) or {}
        if (store != "gog" or not isinstance(row, dict) or row.get("state") == "shelf"
                or row.get("platform") != "windows" or not isinstance(row.get("appid"), int)
                or not rec.get("path")):
            continue
        steps, build_id = gog_steps(p, gid, rec["path"])
        if steps:
            out[str(row["appid"] & 0xFFFFFFFF)] = {"id": f"{token}:{build_id}", "steps": steps}
    return out


def sync(p, registry):
    """Rewrite first-run.json from the registry when it changed. True when the file is current."""
    wanted = build(p, registry, installs.read_records(p))
    current = status.read_user_json(path(p), int(p["NOVADECK_STORE_UID"]))
    if current == wanted or (current is None and not wanted):
        return True
    return cli.write_as_user(p, path(p), json.dumps(wanted, indent=1)) == 0
