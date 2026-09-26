"""Is each store connected?

Connection is read from the credential each CLI writes, not from a state file of our own. A
second record of "connected" would be one more thing to keep true: the CLI is what refreshes and
invalidates these, so it owns the answer and we only look.

What leaves this module is connected / account / expired and nothing else. The files hold the
tokens too, and the panel never needs them; the less this module hands on, the smaller the blast
radius of a logging mistake.

`expired` is what the file says about its own access token. It is NOT a verdict on the account:
an expired access token is exactly what a refresh renews. It means something only AFTER a refresh
ran — then it says the refresh could not renew it (see main.py refresh).
"""
import datetime
import json
import os
import stat
import time

# legendary keeps its session in user.json alongside its caches (assets.json, aliases.json);
# gogdl writes a single file whose keys are OAuth client ids.
LEGENDARY_SESSION = "user.json"


def open_user_file(path, owner_uid):
    """An open binary file, or None. Only a regular file owned by the store user is opened.

    ROOT READS THIS, inside a tree the user owns. Anything running as the user — a game — can
    swap the file, or any directory above it, for a symlink. O_NOFOLLOW refuses a link in the
    last component; the owner check refuses a swapped parent, which can only lead to a file
    someone else owns (anything the user owns, the user could read already). O_NONBLOCK lets a
    FIFO open without blocking, and the regular-file check then rejects it: a blocked read here
    would hold the store's lock (main.py) for good.
    """
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    except OSError:
        return None
    f = os.fdopen(fd, "rb")
    try:
        st = os.fstat(fd)
    except OSError:
        f.close()
        return None
    if not stat.S_ISREG(st.st_mode) or st.st_uid != owner_uid:
        f.close()
        return None
    return f


def read_user_json(path, owner_uid):
    """The file's JSON, or None, read through open_user_file."""
    f = open_user_file(path, owner_uid)
    if f is None:
        return None
    try:
        with f:
            return json.loads(f.read().decode("utf-8"))
    except (OSError, ValueError):
        return None


def _epic_expired(expires_at):
    """legendary's own test (core.py _login): expires_at is naive UTC with a trailing Z. Anything
    that does not parse is left to legendary to judge on its next login, not called expired."""
    if not isinstance(expires_at, str):
        return False
    try:
        expiry = datetime.datetime.fromisoformat(expires_at.rstrip("Z"))
    except ValueError:
        return False
    now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
    return expiry <= now


def epic_status(legendary_config_path, owner_uid):
    """Connected when legendary's session file parses. An empty or truncated user.json is NOT
    connected — legendary would fail on the next call and the panel should already say so.
    legendary deletes the file itself when Epic rejects a refresh, so a revoked session reads as
    not connected with no help from us."""
    data = read_user_json(os.path.join(legendary_config_path, LEGENDARY_SESSION), owner_uid)
    if not isinstance(data, dict) or not data:
        return {"store": "epic", "connected": False}
    return {
        "store": "epic",
        "connected": True,
        "account": data.get("displayName") or None,
        "expired": _epic_expired(data.get("expires_at")),
    }


def _gog_expired(creds):
    """gogdl's own test (auth.py is_credential_expired): loginTime + expires_in."""
    try:
        return time.time() >= float(creds["loginTime"]) + float(creds["expires_in"])
    except (KeyError, TypeError, ValueError):
        return False


def gog_status(gogdl_auth_path, owner_uid):
    """Connected when the auth file holds at least one client id with an access token. There is
    no account name: gogdl stores only a user id, and naming the account would take an API call
    with the token."""
    data = read_user_json(gogdl_auth_path, owner_uid)
    if not isinstance(data, dict):
        return {"store": "gog", "connected": False}
    for creds in data.values():
        if isinstance(creds, dict) and creds.get("access_token"):
            return {"store": "gog", "connected": True, "account": None, "expired": _gog_expired(creds)}
    return {"store": "gog", "connected": False}
