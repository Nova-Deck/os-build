"""Read a file the session user owns, as root.

Anything running as that user can swap the file for a link. What is read here is then SENT (the web
UI's password, to a port the user can bind), so a link to a root-only file would hand it over.
O_NOFOLLOW refuses a symlink in the last component, the owner check refuses what a swapped parent
leads to, the link count refuses a second name for someone else's file, and O_NONBLOCK lets a FIFO
open so that the regular-file check can refuse it instead of hanging.
"""
import os
import stat


def read(path, owner_uid, limit):
    """The file's bytes, or None. Never more than `limit`: a larger file is refused whole."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    except OSError:
        return None
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_uid != owner_uid or st.st_nlink != 1:
            return None
        data = os.read(fd, limit + 1)
        return data if len(data) <= limit else None
    except OSError:
        return None
    finally:
        os.close(fd)
