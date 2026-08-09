"""game-tweaks.json access for the plugin backend.

The plugin runs as root inside Decky's PluginLoader ("flags": ["root"] in plugin.json), so it
writes /etc/novadeck/game-tweaks.json directly — atomically, because two enforcers read this
file on their own schedules (novadeck-powerd's 3s tick, proton-wrapper at every exec) and
neither must ever see a half-written config. There is no privileged middleman daemon on
purpose: a socket-service intermediary earns its keep only when it also owns live perf state,
and ours lives in novadeck-powerd, which picks changes up on its next tick with no poke needed.

Sanitizing is SHALLOW on purpose. The deep validation already exists at the consumers —
novadeck_perf.sanitize_perf drops bad perf keys, proton-wrapper ignores unknown FEX keys — and
duplicating those rules here would just be a second copy to keep in sync. What the plugin
enforces is the envelope: dict shape, digit appids, a size cap, and appid "0" (Valve's "no app"
sentinel, which DOES occur on compat-tool probing launches — see novadeck_perf) never gets a
section.
"""
import json
import os
import pathlib
import tempfile

TWEAKS_CONFIG = pathlib.Path("/etc/novadeck/game-tweaks.json")
FEX_PROFILES_CONFIG = pathlib.Path("/usr/share/novadeck/fex-profiles.json")
MAX_PAYLOAD = 256 * 1024


def atomic_write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    finally:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass


def load_fex_profiles():
    """{name: label} from the shipped contract; the wrapper's own loader is the validator."""
    try:
        with FEX_PROFILES_CONFIG.open(encoding="utf-8") as f:
            contract = json.load(f)
        profiles = contract.get("profiles")
        if not isinstance(profiles, dict):
            return {}
        return {
            name: profile.get("label", name.title())
            for name, profile in profiles.items()
            if isinstance(profile, dict)
        }
    except (OSError, ValueError):
        return {}


def load_tweaks():
    """Absent or malformed is an empty config, never an error — same as every other reader."""
    try:
        with TWEAKS_CONFIG.open(encoding="utf-8") as f:
            loaded = json.load(f)
    except (OSError, ValueError):
        return {"global": {}, "games": {}}
    if not isinstance(loaded, dict):
        return {"global": {}, "games": {}}
    return {
        "global": loaded.get("global") if isinstance(loaded.get("global"), dict) else {},
        "games": {
            str(appid): game
            for appid, game in (loaded.get("games") or {}).items()
            if isinstance(game, dict)
        } if isinstance(loaded.get("games"), dict) else {},
    }


def sanitize_tweaks(data):
    if not isinstance(data, dict):
        raise ValueError("tweaks must be an object")
    if len(json.dumps(data)) > MAX_PAYLOAD:
        raise ValueError("tweaks payload too large")
    clean = {"global": {}, "games": {}}
    if isinstance(data.get("global"), dict):
        clean["global"] = data["global"]
    raw_games = data.get("games")
    if isinstance(raw_games, dict):
        for appid, game in raw_games.items():
            appid = str(appid)
            # "0" is the no-app sentinel: a section keyed on it would tune Valve's own
            # prefix-setup helper runs. Refuse it here so the UI cannot create one.
            if appid.isdigit() and appid != "0" and isinstance(game, dict):
                clean["games"][appid] = game
    return clean


def save_tweaks(data):
    clean = sanitize_tweaks(data)
    atomic_write(TWEAKS_CONFIG, json.dumps(clean, indent=2, sort_keys=True) + "\n")
    return load_tweaks()
