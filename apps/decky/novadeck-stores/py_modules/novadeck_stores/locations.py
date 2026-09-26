"""Where a game can go: the user's home and every mounted card, each with its free space.

The user picks a drive, never a path. The drives are the same set Settings > Storage shows: the
home, and each card udisks mounted under /run/media/<user>/<label> (storage/automount.sh), which
is owned by the user. Only a real mountpoint counts — udisks can leave an empty directory behind
a card that is gone, and a game written there would land on the root filesystem's tmpfs.

Games go to <volume>/Games/<store>/, outside Steam's own tree: Steam manages steamapps/, and a
Steam reset or a removed library should not take store games with it.
"""
import os

STORE_DIRS = {"epic": "Epic", "gog": "GOG"}


def _volume(path, label):
    st = os.statvfs(path)
    return {"path": path, "label": label, "free": st.f_bavail * st.f_frsize}


def volumes(home, media_dir, is_mount=os.path.ismount):
    """[{path, label, free}] — the home first, then each mounted card by label."""
    found = [_volume(home, "Internal")]
    try:
        names = sorted(os.listdir(media_dir))
    except OSError:
        return found
    for name in names:
        path = os.path.join(media_dir, name)
        if os.path.islink(path) or not os.path.isdir(path) or not is_mount(path):
            continue
        found.append(_volume(path, name))
    return found


def user_volumes(user):
    return volumes(f"/home/{user}", f"/run/media/{user}")


def game_root(volume, store):
    if store not in STORE_DIRS:
        raise ValueError(f"unknown store {store!r}")
    return os.path.join(volume, "Games", STORE_DIRS[store])
