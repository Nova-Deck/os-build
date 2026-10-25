"""The Proton prefix an entry leaves behind when its game is uninstalled (issue #136).

Steam keeps `steamapps/compatdata/<appid>` for a non-Steam entry forever: it is where the game's
saves, settings and registry live, and it is what makes a reinstall pick them up again. So an
uninstall never drops it unasked. But it is also hundreds of MB the user cannot see from the UI
(HW 2026-10-25: a 448 MB Witcher prefix and a 444 MB Mutant Year Zero prefix, one with saves,
one without, indistinguishable). This module answers "is it there, how big" for the uninstall
dialog, and removes it when the user says so.

THE PATH IS NEVER TAKEN FROM A CALLER. It is rebuilt here from the entry's appid — an int the
registry recorded when Steam created the entry — under the store user's Steam root, and re-checked
against what it must be before any rm: exactly <steam>/steamapps/compatdata/<appid>, a real
directory, no link anywhere along the path. The same discipline as installs.deletable, for the
same reason: the rm runs as the user, so this check is what keeps it to one folder.

The entry's shader cache sits beside it under the same appid and the same guard, but it holds
nothing of the user's, so every uninstall drops it unasked.
"""
import os
import stat

from novadeck_stores import cli

# A compat prefix is a few hundred MB on a card; du walks it, rm removes it.
STATUS_TIMEOUT = 60
DROP_TIMEOUT = 300


def steam_root(p):
    """The store user's Steam root — home from passwd, not hardcoded (shortcuts.vdf_paths does
    the same)."""
    return os.path.join(os.path.expanduser(f"~{p['NOVADECK_STORE_USER']}"), ".local", "share", "Steam")


def compat_dir(steam, appid, kind="compatdata"):
    """<steam>/steamapps/<kind>/<appid>, or None unless appid is a positive int. A bool is an
    int in Python and `True` would name prefix 1; a string could carry a path."""
    if isinstance(appid, bool) or not isinstance(appid, int) or appid <= 0:
        return None
    return os.path.join(steam, "steamapps", kind, str(appid))


def deletable(path, steam, kind="compatdata"):
    """path if drop() may rm -rf it, else None: exactly one numeric folder directly inside
    <steam>/steamapps/<kind>, reached through no symlink, and a real directory."""
    parent, name = os.path.split(path)
    if not name.isdigit() or parent != os.path.join(steam, "steamapps", kind):
        return None
    if os.path.realpath(path) != path:
        return None
    try:
        st = os.lstat(path)
    except OSError:
        return None
    return path if stat.S_ISDIR(st.st_mode) else None


def status(p, appid, steam=None):
    """{"exists": bool, "bytes": int} for the entry's prefix. The size is du's, run as the user:
    the tree is theirs, and a walk as root would follow whatever they planted in it."""
    steam = steam if steam is not None else steam_root(p)
    path = compat_dir(steam, appid)
    if path is None or deletable(path, steam) is None:
        return {"exists": False, "bytes": 0}
    rc, out = cli.capture(p, ["du", "-sb", "--", path], STATUS_TIMEOUT)
    size = 0
    if rc == 0:
        head = out.split("\t", 1)[0].strip()
        size = int(head) if head.isdigit() else 0
    return {"exists": True, "bytes": size}


def drop(p, appid, steam=None):
    """Remove the entry's prefix. {"dropped": True} or {"error": ...}; on any refusal nothing
    runs. A prefix that is not there is an error too: the caller offered to delete something it
    had just measured, and "done" for nothing would hide the race."""
    steam = steam if steam is not None else steam_root(p)
    path = compat_dir(steam, appid)
    if path is None:
        return {"error": "the entry has no usable appid"}
    if deletable(path, steam) is None:
        if not os.path.lexists(path):
            return {"error": "no Proton prefix on disk"}
        return {"error": "the Proton prefix is not a plain directory"}
    cli._run(p, ["rm", "-rf", "--one-file-system", "--", path], DROP_TIMEOUT)
    if os.path.lexists(path):
        return {"error": "the Proton prefix could not be removed"}
    return {"dropped": True}


def drop_shader_cache(p, appid, steam=None):
    """Remove the entry's shader cache, steamapps/shadercache/<appid>: DXVK, Fossilize and Mesa
    caches, rebuilt on the next run and nothing the user keeps. Steam deletes it with a Steam
    game but never for a non-Steam entry, and it is no part of the prefix (HW 2026-10-25: 8.8 MB
    left by Phoenix Point), so every uninstall takes it. {"dropped": bool} or {"error": ...}: a
    cache that is not there is no error, the game may never have run."""
    steam = steam if steam is not None else steam_root(p)
    path = compat_dir(steam, appid, "shadercache")
    if path is None:
        return {"error": "the entry has no usable appid"}
    if deletable(path, steam, "shadercache") is None:
        if not os.path.lexists(path):
            return {"dropped": False}
        return {"error": "the shader cache is not a plain directory"}
    cli._run(p, ["rm", "-rf", "--one-file-system", "--", path], DROP_TIMEOUT)
    if os.path.lexists(path):
        return {"error": "the shader cache could not be removed"}
    return {"dropped": True}
