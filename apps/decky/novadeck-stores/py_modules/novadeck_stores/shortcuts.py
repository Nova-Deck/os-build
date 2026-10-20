"""Steam library entries for alien games — the template, the ownership rule, the registry, and
the verification reader.

NOTHING HERE WRITES shortcuts.vdf. Entries are created and removed through Steam's own live API
(SteamClient.Apps.AddShortcut / RemoveShortcut, reachable only from the plugin frontend), so
Steam persists its own file and the ecosystem's restart-and-rewrite pathology — the write guards,
foreign-entry merges and backups unifideck carries for its direct writes — has nothing to attach
to. This module decides WHAT the frontend writes and verifies WHAT landed.

Two rules carried over from unifideck's scars, not its code:

  - OWNERSHIP IS THE Exe BASENAME, nothing else. Foreign tools copy tags and LaunchOptions
    verbatim (their incident UD-006 deleted users' own games by trusting tags), so is_ours() is
    the one test every destructive act must pass, and a foreign entry carrying our token is
    excluded from matching rather than adopted.

  - STEAM'S APPID IS ACCEPTED, NEVER A DURABLE KEY. AddShortcut returns it and it lands in the
    registry (shortcuts.json beside installs.json, written as the store user), because shortcut
    appids churn on every re-add. The durable key is our token, `<store>:<game_id>`.

The binary-VDF reader is copied from novadeck_control/steam.py (plugins deliberately cannot
import each other); it reads the three value types the file actually uses and RAISES on anything
else — an unreadable file must never report as an empty one, which is also why our_entries() has
no try/except.
"""
import glob
import json
import os
import re

from novadeck_stores import cli, status

STUB = "/usr/lib/novadeck/store-launch"
_STUB_BASENAME = os.path.basename(STUB)
# One grammar, two enforcers: the stub refuses argv outside it, entry_fields refuses to emit it.
# tests/test-store-shortcuts.sh drives the shipped stub with this module's output to pin the pair.
TOKEN = re.compile(r"^(epic|gog):[A-Za-z0-9][A-Za-z0-9._-]*$")


def entry_fields(store, gid, title, install_path):
    """The exact fields an entry is created with. Raises ValueError on a token the stub would
    refuse — a shortcut that can never launch must fail here, where the id came from, not on
    the device's first Play."""
    token = f"{store}:{gid}"
    if not TOKEN.fullmatch(token):
        raise ValueError(f"token would not survive the stub: {token!r}")
    return {
        "AppName": title,
        # Quoted like Steam's own UI writes them; the path is on the read-only root, identical
        # on both A/B slots, so it survives every OTA.
        "Exe": f'"{STUB}"',
        "StartDir": f'"{install_path}"' if install_path else '""',
        "LaunchOptions": token,
    }


def is_ours(entry):
    """THE ownership test. Exe basename only; quoted and lowercase-key forms included because
    both occur in real files. See the module docstring for why nothing else counts."""
    exe = entry.get("Exe") if isinstance(entry.get("Exe"), str) else entry.get("exe", "")
    if not isinstance(exe, str):
        return False
    return os.path.basename(exe.strip().strip('"')) == _STUB_BASENAME


def entry_token(entry):
    """The durable id an entry carries, or None. The token is identity, never ownership: callers
    must gate on is_ours() first, so a foreign entry carrying our token is never matched."""
    options = entry.get("LaunchOptions")
    if not isinstance(options, str):
        return None
    first = options.split(maxsplit=1)[0] if options.split() else ""
    return first if TOKEN.fullmatch(first) else None


def add_payload(req, store, gid, title, install_path):
    """The exact event payload the frontend bridge executes for an add. Built THROUGH
    entry_fields so an id that would not survive the stub raises here; the API takes unquoted
    paths (Steam quotes its own file), so the quotes come back off."""
    fields = entry_fields(store, gid, title, install_path)
    return {"op": "add", "req": req, "name": fields["AppName"],
            "exe": fields["Exe"].strip('"'), "dir": fields["StartDir"].strip('"'),
            "options": fields["LaunchOptions"]}


def remove_payload(req, appid):
    return {"op": "remove", "req": req, "appid": int(appid)}


def check_register(registry, store, gid):
    """The refusal, or None. One entry per token: a registered id must be deregistered first,
    and a stale registry row (entry lost to Steam) is deregister's business to clear, visible in
    entry_status — silently re-adding over it would mint a second appid for the same game."""
    if f"{store}:{gid}" in registry:
        return "already registered"
    return None


def registry_path(p):
    return os.path.join(p["NOVADECK_STORE_HOME"], "shortcuts.json")


def read_registry(p):
    data = status.read_user_json(registry_path(p), int(p["NOVADECK_STORE_UID"]))
    return data if isinstance(data, dict) else {}


def write_registry(p, rows):
    return cli.write_as_user(p, registry_path(p), json.dumps(rows, indent=1)) == 0


def vdf_paths(p):
    """Every shortcuts.vdf Steam keeps for the store user — their home is asked from passwd, not
    hardcoded (the suite bans /home/deck literals outside paths.py). One deck user on this image,
    but the glob tolerates more (novadeck_control/steam.py reads the same way); sorted so a
    report is stable."""
    home = os.path.expanduser(f"~{p['NOVADECK_STORE_USER']}")
    return sorted(glob.glob(os.path.join(
        home, ".local", "share", "Steam", "userdata", "*", "config", "shortcuts.vdf")))


# -- the verification reader (copied from novadeck_control/steam.py:15-40) --

def _read_cstring(data, offset):
    end = data.index(b"\0", offset)
    return data[offset:end].decode("utf-8", errors="replace"), end + 1


def _read_binary_vdf_object(data, offset=0):
    values = {}
    while offset < len(data):
        value_type = data[offset]
        offset += 1
        if value_type == 8:
            return values, offset
        key, offset = _read_cstring(data, offset)
        if value_type == 0:
            value, offset = _read_binary_vdf_object(data, offset)
        elif value_type == 1:
            value, offset = _read_cstring(data, offset)
        elif value_type == 2:
            if offset + 4 > len(data):
                raise ValueError("truncated binary VDF integer")
            value = int.from_bytes(data[offset:offset + 4], "little")
            offset += 4
        else:
            raise ValueError(f"unsupported binary VDF type {value_type}")
        values[key] = value
    raise ValueError("binary VDF object never closed")


def our_entries(vdf_bytes):
    """Every entry in the given shortcuts.vdf bytes whose Exe is ours. Raises on bytes that do
    not parse — the caller must treat that as 'unknown', never as 'none'."""
    root, _ = _read_binary_vdf_object(vdf_bytes)
    shortcuts_obj = root.get("shortcuts", {})
    if not isinstance(shortcuts_obj, dict):
        raise ValueError("no shortcuts object in the file")
    found = []
    for key, entry in shortcuts_obj.items():
        if isinstance(entry, dict) and is_ours(entry):
            found.append({"key": key, "appid": entry.get("appid"),
                          "AppName": entry.get("AppName"), "token": entry_token(entry)})
    return found


def orphan_report(vdf_bytes, registry):
    """Join the file against the registry. REPORT ONLY — nothing here, and nothing driven from
    here, deletes on its own judgment (milestone 4's contract).

      healthy                 ours, token known to the registry
      orphan_no_token         ours, but no (valid) token to identify it by
      registry_without_entry  a registry row with no owned entry carrying its token
    """
    entries = our_entries(vdf_bytes)
    healthy = [e for e in entries if e["token"] in registry]
    seen = {e["token"] for e in entries if e["token"]}
    return {
        "healthy": healthy,
        "orphan_no_token": [e for e in entries if not e["token"]],
        "registry_without_entry": [
            {"token": token, **({"appid": row["appid"]} if isinstance(row, dict) and "appid" in row else {})}
            for token, row in registry.items() if token not in seen
        ],
    }
