"""The per-game half of the switch: /etc/novadeck/game-tweaks.json.

Frame generation needs TWO things per game, and they live in different files. The tuning lives
in lsfg-vk's own conf.toml (see conf.py); the on/off lives here, as environment variables
game-launch applies before exec:

    "env": { "DISABLE_LSFGVK": null, "LSFGVK_PROFILE": "novadeck-<appid>" }

`null` is a TOMBSTONE, not a value -- game-launch's apply_env unsets the variable rather than
setting it empty. That matters: the session exports DISABLE_LSFGVK=1 for everything, and REMOVING
it is what turns the layer on for one game. Doing it this way meant no change to game-launch at
all, and a game with no tweak simply inherits the session default of off.

WE ARE THE SECOND WRITER OF THIS FILE. novadeck-control owns it too, so every write here is a
read-modify-write that touches only our two env keys and leaves the rest of the game's section --
fexProfile, cores, nice, powerProfile, the user's own env -- exactly as found. The write is
atomic because novadeck-powerd reads this file on a 3s tick and proton-wrapper reads it at every
exec, and neither may ever see it half-written.

Sanitizing stays SHALLOW for the same reason it does in novadeck-control: the real validation is
at the consumers, and a second copy of those rules here would only drift.
"""
import json
import os
import pathlib
import tempfile

TWEAKS_CONFIG = pathlib.Path("/etc/novadeck/game-tweaks.json")
# Our opt-in key. Distinct from `enabled`, which belongs to the control plugin and means
# per-game TUNING is on. See set_enabled() for why they must not be the same flag.
FRAMEGEN_KEY = "framegen"
MAX_PAYLOAD = 256 * 1024

DISABLE_VAR = "DISABLE_LSFGVK"
PROFILE_VAR = "LSFGVK_PROFILE"


def _atomic_write(path, text):
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


def load():
    try:
        with TWEAKS_CONFIG.open(encoding="utf-8") as f:
            loaded = json.load(f)
    except (OSError, ValueError):
        return {"global": {}, "games": {}}
    if not isinstance(loaded, dict):
        return {"global": {}, "games": {}}
    games = loaded.get("games")
    return {
        "global": loaded["global"] if isinstance(loaded.get("global"), dict) else {},
        "games": {
            str(appid): game for appid, game in games.items() if isinstance(game, dict)
        } if isinstance(games, dict) else {},
    }


def enabled_games():
    """appids whose env actually turns the layer on.

    The tombstone is the truth, not a flag of our own: a user who hand-edits the env back to
    absent has turned frame generation off, and the panel must agree with the file rather than
    with a parallel bookkeeping key that says otherwise.
    """
    found = set()
    for appid, game in load()["games"].items():
        env = game.get("env")
        if isinstance(env, dict) and DISABLE_VAR in env and env[DISABLE_VAR] is None:
            found.add(appid)
    return found


def tweaked_games():
    """appids the CONTROL plugin has per-game tuning enabled for.

    The panel needs this to decide whether the launch wrapper may be removed: frame generation
    and tuning both need it, so unwrapping just because frame generation went off would silently
    break tuning the user still has on.
    """
    return {
        appid for appid, game in load()["games"].items()
        if game.get("enabled") is True
    }


def set_enabled(appid, on):
    """Add or remove our two env keys for one game, touching nothing else."""
    appid = str(appid)
    # "0" is Valve's no-app sentinel and DOES occur (compat-tool probe launches). A section
    # keyed on it would apply to Steam's own helper runs -- refuse it here, as control does.
    if not appid.isdigit() or appid == "0":
        raise ValueError("bad appid")

    data = load()
    game = dict(data["games"].get(appid) or {})
    env = dict(game.get("env") or {}) if isinstance(game.get("env"), dict) else {}

    if on:
        env[DISABLE_VAR] = None
        env[PROFILE_VAR] = f"novadeck-{appid}"
        # OUR OWN OPT-IN KEY, deliberately not `enabled`. game-launch gates a game's entry on an
        # explicit opt-in, and we used to borrow `enabled` for it -- which is the control
        # plugin's "the user turned on per-game tuning" flag, so switching frame generation on
        # announced tuning the user never asked for. game-launch reads `framegen` for the env
        # alone and applies no tuning from it.
        game[FRAMEGEN_KEY] = True
    else:
        env.pop(DISABLE_VAR, None)
        env.pop(PROFILE_VAR, None)
        game.pop(FRAMEGEN_KEY, None)

    if env:
        game["env"] = env
    else:
        game.pop("env", None)

    # Drop a section only once it is EMPTY. It used to drop one holding nothing but `enabled`,
    # which was right while we were the ones who wrote `enabled` -- now that we never do, an
    # `enabled` still standing here is the control plugin's, and deleting it would silently
    # switch off the user's tuning because they toggled frame generation off.
    if not on and not game:
        data["games"].pop(appid, None)
    else:
        data["games"][appid] = game

    payload = json.dumps(data, indent=2, sort_keys=True) + "\n"
    if len(payload) > MAX_PAYLOAD:
        raise ValueError("tweaks payload too large")
    _atomic_write(TWEAKS_CONFIG, payload)
    return enabled_games()
