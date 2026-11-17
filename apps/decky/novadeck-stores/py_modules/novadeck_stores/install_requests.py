"""Requests the user side leaves in <store home>/requests/ for the plugin backend to take.

Two kinds share the spool, told apart by suffix:
  - `<store>:<id>.install` — the not-installed tile stub (/usr/lib/novadeck/store-launch), run as
    the user when a shelf tile's Play is pressed;
  - `<appid>.dospick` — game-launch asking which DOSBox version of a GOG title to run under
    Boxtron (novadeck_dostarget.py; dos_targets.py answers).
The FILENAME is the whole message — root never reads the file — and taking a request means
unlinking it, which is what the waiting side watches for.

The spool sits in a directory the user owns, so everything here assumes the user (or any game
running as them) arranged it: the directory is opened O_NOFOLLOW and must be a real directory the
user owns; every name is unlinked and checked RELATIVE to that descriptor, so a swapped path
cannot redirect it; a name that is not a regular user-owned file, or not a token in the grammar,
is dropped unread. A token that survives is still only a request — the caller decides against its
own registry whether it names a tile we made.
"""
import os
import re
import stat

from novadeck_stores import shortcuts

REQUEST_DIR = "requests"
SUFFIX = ".install"
PICK_SUFFIX = ".dospick"
APPID = re.compile(r"^[0-9]{1,10}$")


def spool_path(p):
    return os.path.join(p["NOVADECK_STORE_HOME"], REQUEST_DIR)


def take(p):
    """Unlink every pending install request and return the valid tokens, oldest first."""
    return take_matching(p, SUFFIX, shortcuts.TOKEN.fullmatch)


def take_dos_picks(p):
    """Unlink every pending DOSBox version question and return the appids (str), oldest first."""
    return take_matching(p, PICK_SUFFIX, APPID.fullmatch)


def take_matching(p, suffix, valid):
    """Unlink every pending request with `suffix` and return the names `valid` accepts, oldest
    first. Never raises on a missing or hostile spool: no spool is no requests."""
    uid = int(p["NOVADECK_STORE_UID"])
    try:
        fd = os.open(spool_path(p), os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    except OSError:
        return []
    try:
        st = os.fstat(fd)
        if not stat.S_ISDIR(st.st_mode) or st.st_uid != uid:
            return []
        found = []
        for name in os.listdir(fd):
            if not name.endswith(suffix):
                continue
            try:
                lst = os.stat(name, dir_fd=fd, follow_symlinks=False)
                os.unlink(name, dir_fd=fd)
            except OSError:
                continue
            token = name[:-len(suffix)]
            if stat.S_ISREG(lst.st_mode) and lst.st_uid == uid and valid(token):
                found.append((lst.st_mtime_ns, token))
        return [token for _, token in sorted(found)]
    finally:
        os.close(fd)
