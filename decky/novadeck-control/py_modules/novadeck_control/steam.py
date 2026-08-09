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
                if len(parts) >= 4 and parts[1] in ("appid", "name"):
                    values[parts[1]] = parts[3]
            appid = values.get("appid")
            name = values.get("name")
            if appid and name and appid not in seen:
                games.append({"appid": str(appid), "name": name})
                seen.add(appid)
    for game in _shortcut_games():
        if game["appid"] not in seen:
            games.append(game)
            seen.add(game["appid"])
    return sorted(games, key=lambda game: game["name"].casefold())
