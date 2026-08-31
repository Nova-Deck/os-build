"""Installed-games listing, read from Steam's own on-disk state (/home/deck).

Two sources, merged:
  - appmanifest_*.acf in every steamapps dir libraryfolders.vdf names (text VDF, but the two
    keys we need sit alone on their lines, so a line split beats shipping a VDF parser)
  - shortcuts.vdf for non-Steam shortcuts (binary VDF; the minimal reader below handles the
    three value types the file actually uses)
"""
from pathlib import Path

STEAM_ROOT = Path("/home/deck/.local/share/Steam")
STEAM_APPS_DIR = STEAM_ROOT / "steamapps"


def _read_cstring(data, offset):
    end = data.index(b"\0", offset)
    return data[offset:end].decode("utf-8", errors="replace"), end + 1


def _read_binary_vdf_object(data, offset=0):
    values = {}
    while offset < len(data):
        value_type = data[offset]
        offset += 1
        if value_type == 8:
            return values, offset
        key, offset = _read_cstring(data, offset)
        if value_type == 0:
            value, offset = _read_binary_vdf_object(data, offset)
        elif value_type == 1:
            value, offset = _read_cstring(data, offset)
        elif value_type == 2:
            if offset + 4 > len(data):
                raise ValueError("truncated binary VDF integer")
            value = int.from_bytes(data[offset:offset + 4], "little")
            offset += 4
        else:
            raise ValueError(f"unsupported binary VDF type {value_type}")
        values[key] = value
    return values, offset


def _shortcut_games():
    games = []
    for shortcuts_file in sorted((STEAM_ROOT / "userdata").glob("*/config/shortcuts.vdf")):
        try:
            root, _ = _read_binary_vdf_object(shortcuts_file.read_bytes())
        except (OSError, ValueError):
            continue
        shortcuts = root.get("shortcuts", {})
        if not isinstance(shortcuts, dict):
            continue
        for shortcut in shortcuts.values():
            if not isinstance(shortcut, dict):
                continue
            appid = shortcut.get("appid")
            name = shortcut.get("AppName")
            if isinstance(appid, int) and appid and isinstance(name, str) and name:
                games.append({"appid": str(appid), "name": name, "nonSteam": True})
    return games


# THE TWO THAT NO MECHANISM CATCHES, listed by appid because nothing in their appmanifest or their
# install tree distinguishes them from a game -- no toolmanifest.vdf, same StateFlags, same shape.
# Kept deliberately tiny: the toolmanifest test above is the general rule and covers every Proton,
# every Steam Linux Runtime and Valve's FEX tool without naming any of them. This is the exception
# list, and an entry earns its place only by being a stable appid that is never launched.
#
#   228980  Steamworks Common Redistributables -- a shared depot other apps pull in. It has no
#           launch configuration at all, so it can never be the thing a tweak applies to.
#   993090  Lossless Scaling -- on this platform it exists so lsfg-vk can read its DLL out of the
#           depot (see novadeck_framegen/prereq.py). It is a Windows overlay app; launching it here
#           does nothing, and its beta branch is switched in Steam's own UI, not ours.
NEVER_A_GAME = {"228980", "993090"}


def installed_games():
    steamapps_dirs = {STEAM_APPS_DIR}
    for library_file in (STEAM_APPS_DIR / "libraryfolders.vdf", STEAM_ROOT / "config/libraryfolders.vdf"):
        try:
            lines = library_file.read_text(encoding="utf-8", errors="replace").splitlines()
        except OSError:
            continue
        for line in lines:
            parts = line.strip().split('"')
            if len(parts) >= 4 and parts[1] == "path":
                steamapps_dirs.add(Path(parts[3]) / "steamapps")
    games = []
    seen = set()
    for steamapps_dir in sorted(steamapps_dirs):
        for manifest in sorted(steamapps_dir.glob("appmanifest_*.acf")):
            values = {}
            try:
                lines = manifest.read_text(encoding="utf-8", errors="replace").splitlines()
            except OSError:
                continue
            for line in lines:
                parts = line.strip().split('"')
                if len(parts) >= 4 and parts[1] in ("appid", "name", "installdir"):
                    values[parts[1]] = parts[3]
            appid = values.get("appid")
            name = values.get("name")
            # The two the mechanism below cannot see (see NEVER_A_GAME above).
            if appid in NEVER_A_GAME:
                continue
            # SKIP COMPAT TOOLS AND RUNTIMES. Proton, the Steam Linux Runtimes and Valve's FEX compat
            # tool install as ordinary apps with their own appmanifest, so they land in this list
            # beside real games -- and a per-game tweak on one is meaningless, since nothing ever
            # launches them directly. The test is MECHANICAL rather than a name match or an appid
            # list: a compat tool ships toolmanifest.vdf in its install directory, which is the same
            # file that makes Steam treat it as a tool. An appid list would rot the next time Valve
            # ships another runtime, and a name match would catch a game called "Proton".
            installdir = values.get("installdir")
            if installdir and (steamapps_dir / "common" / installdir / "toolmanifest.vdf").exists():
                continue
            if appid and name and appid not in seen:
                games.append({"appid": str(appid), "name": name})
                seen.add(appid)
    for game in _shortcut_games():
        if game["appid"] not in seen:
            games.append(game)
            seen.add(game["appid"])
    return sorted(games, key=lambda game: game["name"].casefold())
