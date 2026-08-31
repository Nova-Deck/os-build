"""~/.config/lsfg-vk/conf.toml — the file lsfg-vk actually reads.

WHY A CONFIG FILE AND NOT ENVIRONMENT VARIABLES. lsfg-vk can be driven entirely from env
(LSFGVK_ENV=1 plus LSFGVK_MULTIPLIER and friends), which would have been less code. But
`multiplier`, `flow_scale` and `performance_mode` HOT-RELOAD from the file -- the layer watches it
with inotify -- so changing them applies to the game that is already running. Tuning while you
play is most of what a Quick Access panel is for, and env-only configuration cannot do it.

(There is a second reason. LSFGVK_* globals are silently ignored on a first run: getOrDefault()
calls parseGlobalEnv() on the LSFGVK_ENV branch and the config-exists branch, but not on the
branch that writes a fresh default config and returns it. So env-only configuration is
unreliable exactly once per user, which is the worst possible frequency.)

WE ARE NOT THE ONLY WRITER. The layer itself creates this file, seeded with upstream's sample
profiles, the first time it loads without one; and the user may hand-edit it. So this reads what
is there, replaces only the profiles WE manage (`novadeck-<appid>`), and preserves everything
else -- global keys and foreign profiles alike. Blowing away a user's own profile because we
wanted to write ours would be unforgivable and is easy to avoid.

PROFILES ARE SELECTED BY NAME, NOT MATCHED. Upstream can identify a process by executable name,
wine exe, /proc/self/comm or SteamAppId. All of those are guesses that can hit the wrong binary
(UE titles ship several) or miss under pressure-vessel. We set LSFGVK_PROFILE per game instead,
which is checked before any of them and cannot be ambiguous, and leave `active_in` empty.
"""
import os
import pathlib
import tempfile

try:
    import tomllib  # 3.11+
except ImportError:  # pragma: no cover - the image ships 3.11+
    tomllib = None

CONFIG_PATH = pathlib.Path("/home/deck/.config/lsfg-vk/conf.toml")
PROFILE_PREFIX = "novadeck-"

# Upstream's own bounds (config.cpp): a multiplier below 2 generates nothing, and flow scale
# outside this range is rejected outright. Clamp rather than reject -- a slider that refuses to
# move is worse UI than one that stops.
MULTIPLIER_MIN, MULTIPLIER_MAX = 2, 4
FLOW_MIN, FLOW_MAX = 0.25, 1.0


def profile_name(appid):
    return f"{PROFILE_PREFIX}{appid}"


def _quote(value):
    """TOML basic string. The only values we ever write are profile names and paths."""
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def _fmt(value):
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        # Always a decimal point: TOML types 1 and 1.0 differently, and flow_scale is a float
        # upstream. `%r` on 0.85 is fine; the concern is 1.0 rendering as "1".
        return f"{value:.6g}" if value != int(value) else f"{value:.1f}"
    return _quote(str(value))


def load():
    """Parsed config, or an empty one. Absent or malformed is never an error here."""
    if tomllib is None:
        return {}
    try:
        with CONFIG_PATH.open("rb") as f:
            return tomllib.load(f)
    except (OSError, ValueError):
        return {}


def _atomic_write(path, text):
    """Written as the DECK user, not root.

    The plugin runs as root (plugin.json flags), and this file lives in the user's home. A
    root-owned conf.toml would make lsfg-vk's own writes fail and the UI unable to fix it, so
    the ownership is restored explicitly. os.replace keeps the swap atomic -- the layer watches
    this path with inotify and must never read a half-written file.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        os.chmod(tmp, 0o644)
        try:
            stat = path.parent.stat()
            os.chown(tmp, stat.st_uid, stat.st_gid)
        except OSError:
            pass  # not root, or an odd home; the write itself still matters more
        os.replace(tmp, path)
    finally:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass


# The reader (readConfig, config.cpp) is STRICT, and every one of these is a hard throw that
# leaves the layer uninitialised and skipped by the Vulkan loader -- with the library still mapped
# into the game, so it looks like it loaded. Verified against upstream's own `lsfg-vk-cli validate`
# rather than by reading the source, which is how the second and third of these were found:
#   * `version` must be present, top-level, and exactly 2
#   * the ONLY legal top-level keys are version / global / profile -- anything else is
#     "Unknown key in configuration", so a stray key cannot be carried through
#   * `[global]` must EXIST and be a table, even when empty
#   * the only legal keys inside it are allow_fp16 / dll / log_level / log_file
GLOBAL_KEYS = ("allow_fp16", "dll", "log_level", "log_file")


def _render(config):
    """Re-emit the whole config in the only shape the reader accepts.

    Preserving foreign keys is the RIGHT instinct and the WRONG action here: an unknown key at
    the top level or in [global] is rejected outright, so carrying one through would hand the
    user a config their layer refuses to load. What is preserved is everything legal -- the four
    global settings, and every profile including ones we do not manage.
    """
    lines = ["version = 2", ""]

    # Always emitted, even empty: a missing [global] is "Invalid global section in configuration".
    lines.append("[global]")
    globals_ = config.get("global")
    if isinstance(globals_, dict):
        for key in GLOBAL_KEYS:
            if key in globals_:
                lines.append(f"{key} = {_fmt(globals_[key])}")
    lines.append("")

    for profile in config.get("profile", []):
        if not isinstance(profile, dict):
            continue
        lines.append("[[profile]]")
        for key in ("name", "multiplier", "flow_scale", "performance_mode",
                    "pacing", "override_present_mode"):
            if key in profile:
                lines.append(f"{key} = {_fmt(profile[key])}")
        active = profile.get("active_in")
        if isinstance(active, list):
            lines.append("active_in = [" + ", ".join(_quote(str(a)) for a in active) + "]")
        lines.append("")
    return "\n".join(lines).rstrip("\n") + "\n"


def read_profiles():
    """{appid: settings} for the profiles this plugin manages. Foreign profiles are ignored."""
    managed = {}
    for profile in load().get("profile", []) or []:
        if not isinstance(profile, dict):
            continue
        name = profile.get("name")
        if not isinstance(name, str) or not name.startswith(PROFILE_PREFIX):
            continue
        managed[name[len(PROFILE_PREFIX):]] = {
            "multiplier": profile.get("multiplier", 2),
            "flowScale": profile.get("flow_scale", 1.0),
            "performanceMode": profile.get("performance_mode", True),
        }
    return managed


def write_profile(appid, settings):
    """Create/replace this game's profile, or remove it when settings is None.

    Everything not ours -- global keys, the user's own profiles, upstream's samples -- is read
    back and written out again untouched.
    """
    config = load()
    profiles = [p for p in (config.get("profile") or []) if isinstance(p, dict)]
    name = profile_name(appid)
    kept = [p for p in profiles if p.get("name") != name]

    if settings is not None:
        multiplier = int(settings.get("multiplier", 2))
        flow = float(settings.get("flowScale", 1.0))
        kept.append({
            "name": name,
            "multiplier": max(MULTIPLIER_MIN, min(MULTIPLIER_MAX, multiplier)),
            "flow_scale": max(FLOW_MIN, min(FLOW_MAX, flow)),
            # Performance mode is not a preference on this hardware, it is the only mode that
            # fits a frame budget on any of our three GPUs -- measured, see issue #81. It is
            # written explicitly rather than left to upstream's default (false).
            "performance_mode": bool(settings.get("performanceMode", True)),
            # Selected by LSFGVK_PROFILE, so nothing to match on.
            "active_in": [],
        })

    config["profile"] = kept
    if not kept:
        # A config with NO profiles is invalid: the reader demands an array OF TABLES, and an
        # empty array does not satisfy that -- so writing one would hand the layer a file it
        # refuses. Removing the file is the honest alternative; the layer recreates its own
        # default the next time it loads without one.
        try:
            CONFIG_PATH.unlink()
        except OSError:
            pass
        return {}
    _atomic_write(CONFIG_PATH, _render(config))
    return read_profiles()
