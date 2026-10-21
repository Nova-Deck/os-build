"""Turning an installed alien game into something Steam can launch (milestone 6).

Model B: the shortcut's Exe is the GAME binary and we set a compat tool on it, so the Steam
client composes the runtime — SLR4 + our arm64 Proton (+ its WoW64 FEX) for a Windows title,
which Steam provisions lazily — instead of this code reimplementing umu. A Linux-native title
needs NO compat tool: the baked binfmt_misc + system FEX + ArchLinux.ero guest already give it a
stable x86-64 ABI (sniper does not exist on arm64, and the native path is HW-validated bare,
docs/worklog/DONE.md:1625-1636). Both reach per-game FEX tuning through `game-launch %command%`,
the exact mechanism a Steam title uses.

So this module's whole job is: resolve the installed game's executable + platform, say which
compat tool (if any) a platform wants, and decide whether an entry's Exe lies under a game root
we manage — since milestone 7 only the orphan report's secondary signal; ownership is registry
membership (shortcuts.py).
"""
import json
import os

from novadeck_stores import locations, status

# The internal compat_tools name of our baked arm64 Proton (rootfs/lib-assemble-proton.sh rewrites
# it to this stable name). Windows titles are mapped to it; native titles get no tool.
WINDOWS_COMPAT_TOOL = "proton-cachyos-11.0-arm64"

# Per-game FEX tuning fronts every launch by the same door a Steam game uses: Steam expands
# %command% host-side to the whole chain it composed, and game-launch tunes then execs it.
LAUNCH_WRAPPER = "/usr/lib/novadeck/game-launch"
LAUNCH_OPTIONS = f"{LAUNCH_WRAPPER} %command%"


def compat_tool(platform):
    """The compat tool a platform wants, or None. Windows → our Proton (Steam builds SLR4 around
    it); native Linux → None (bare binfmt+FEX)."""
    return WINDOWS_COMPAT_TOOL if platform == "windows" else None


def _epic_target(gid, p):
    """Resolve an installed Epic game from legendary's own installed.json — a file read, owner-
    checked, no `legendary launch` invocation. legendary installs the Windows build here."""
    data = status.read_user_json(
        os.path.join(p["LEGENDARY_CONFIG_PATH"], "installed.json"), int(p["NOVADECK_STORE_UID"]))
    game = data.get(gid) if isinstance(data, dict) else None
    if not isinstance(game, dict) or not game.get("install_path") or not game.get("executable"):
        return None
    install = game["install_path"]
    return {"exe": os.path.join(install, game["executable"]), "startdir": install,
            "platform": "windows"}


def _gog_primary_exe(install, gid, uid):
    """The primary executable goggame-<id>.info names, relative to the install dir, or None."""
    f = status.open_user_file(os.path.join(install, f"goggame-{gid}.info"), uid)
    if f is None:
        return None
    try:
        with f:
            info = json.loads(f.read().decode("utf-8", "replace"))
    except (OSError, ValueError):
        return None
    tasks = info.get("playTasks") if isinstance(info, dict) else None
    if not isinstance(tasks, list):
        return None
    # GOG marks exactly one task isPrimary — the entry point, which may be a `launcher` chooser
    # (Master of Magic) or a `game` task directly. Match that signal (as Heroic does), falling
    # back to the first runnable task. `document`/`tool` tasks are never launched.
    candidates = [t for t in tasks if isinstance(t, dict) and t.get("category") in ("game", "launcher")
                  and isinstance(t.get("path"), str)]
    chosen = next((t for t in candidates if t.get("isPrimary")), None) or (
        candidates[0] if candidates else None)
    return chosen["path"] if chosen else None


def _gog_target(gid, p, record):
    """Resolve an installed GOG game. The install path and platform come from OUR install record
    (installs.json); a native-Linux build launches its install-root start.sh, a Windows build the
    primary task from goggame-<id>.info."""
    install = record.get("path")
    if not install:
        return None
    platform = record.get("platform", "windows")
    if platform == "linux":
        return {"exe": os.path.join(install, "start.sh"), "startdir": install, "platform": "linux"}
    rel = _gog_primary_exe(install, gid, int(p["NOVADECK_STORE_UID"]))
    if rel is None:
        return None
    return {"exe": os.path.join(install, rel), "startdir": install, "platform": "windows"}


def resolve_target(store, gid, p, record):
    """{exe, startdir, platform} for an installed game, or None when it cannot be resolved (not
    installed, or the store's own metadata does not name an executable)."""
    if store == "epic":
        return _epic_target(gid, p)
    if store == "gog":
        return _gog_target(gid, p, record)
    return None


def managed_roots(p, vols=None):
    """The realpath of every <volume>/Games/<store> root across the user's volumes. An entry whose
    Exe resolves under one of these is probably one we installed — the orphan report uses it to
    flag an entry no registry row claims. Foreign tools install under their own trees."""
    vols = vols if vols is not None else locations.user_volumes(p["NOVADECK_STORE_USER"])
    roots = set()
    for vol in vols:
        for store in locations.STORE_DIRS:
            roots.add(os.path.realpath(locations.game_root(vol["path"], store)))
    return roots


def under_managed_root(exe_path, roots):
    """Is exe_path, resolved, strictly inside one of the managed roots? A game's Exe always lives
    in a game folder BELOW <volume>/Games/<store>, never the root dir itself. realpath defeats a
    symlink that points the Exe out of our tree."""
    if not isinstance(exe_path, str) or not exe_path:
        return False
    real = os.path.realpath(exe_path.strip().strip('"'))
    return any(real.startswith(root + os.sep) for root in roots)
