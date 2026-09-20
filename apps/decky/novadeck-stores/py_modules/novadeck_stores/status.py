"""Is each store connected?

Connection is read from the credential each CLI writes, not from a state file of our own. A
second record of "connected" would be one more thing to keep true: the CLI is what refreshes and
invalidates these, so it owns the answer and we only look.

Deliberately NOT parsed here: the tokens themselves. Answering "is there a credential" needs the
file to exist and to be JSON; reading the account out of it is milestone 2's later task, and the
less this module touches secrets the smaller the blast radius of a logging mistake.
"""
import json

# legendary keeps its session in user.json alongside its caches (assets.json, aliases.json);
# gogdl writes a single file whose keys are OAuth client ids.
LEGENDARY_SESSION = "user.json"


def _readable_json(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def epic_status(legendary_config_path):
    """Connected when legendary's session file parses. An empty or truncated user.json is NOT
    connected — legendary would fail on the next call and the panel should already say so."""
    import os

    data = _readable_json(os.path.join(legendary_config_path, LEGENDARY_SESSION))
    if not isinstance(data, dict) or not data:
        return {"store": "epic", "connected": False}
    return {"store": "epic", "connected": True, "account": data.get("displayName") or None}


def gog_status(gogdl_auth_path):
    """Connected when the auth file holds at least one client id with an access token."""
    data = _readable_json(gogdl_auth_path)
    if not isinstance(data, dict):
        return {"store": "gog", "connected": False}
    for creds in data.values():
        if isinstance(creds, dict) and creds.get("access_token"):
            return {"store": "gog", "connected": True, "account": None}
    return {"store": "gog", "connected": False}
