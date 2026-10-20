"""Steam library entries for alien games — the template, the ownership rule, the registry, and
the verification reader.

NOTHING HERE WRITES shortcuts.vdf. Entries are created and removed through Steam's own live API
(SteamClient.Apps.AddShortcut / RemoveShortcut, reachable only from the plugin frontend), so
Steam persists its own file and the ecosystem's restart-and-rewrite pathology — the write guards,
foreign-entry merges and backups unifideck carries for its direct writes — has nothing to attach
to. This module decides WHAT the frontend writes and verifies WHAT landed.

Two rules, the first amended by milestone 6:

  - OWNERSHIP IS THE EXE PATH UNDER A MANAGED GAME ROOT. Milestone 6 made the shortcut's Exe the
    game binary (so Steam composes Proton/SLR itself), so the old Exe-basename==stub proof is
    gone; an entry is ours iff its Exe resolves under a <volume>/Games/<store> root we install to
    (launch.under_managed_root). Foreign tools install under their own trees. Tags and the token
    are NEVER ownership — foreign tools copy both (unifideck incident UD-006).

  - STEAM'S APPID IS ACCEPTED, NEVER A DURABLE KEY. AddShortcut returns it and it lands in the
    registry (shortcuts.json beside installs.json), because shortcut appids churn on re-add. The
    durable key is our token `<store>:<game_id>`; the registry maps token → {appid, exe,
    platform}, and the file is joined back to the registry BY APPID.

The binary-VDF reader is copied from novadeck_control/steam.py (plugins deliberately cannot
import each other); it RAISES on anything it cannot parse — an unreadable file must never report
as an empty one, which is why our_entries() has no try/except.
"""
import glob
import json
import os
import re

from novadeck_stores import cli, launch, status

# The gid grammar — still enforced so a bad id never becomes a registry key or a path component.
TOKEN = re.compile(r"^(epic|gog):[A-Za-z0-9][A-Za-z0-9._-]*$")


def entry_fields(store, gid, title, resolved):
    """The exact fields an entry is created with, from a resolved launch target
    ({exe, startdir, platform}). Raises ValueError on an id that could not be a safe token/path."""
    if not TOKEN.fullmatch(f"{store}:{gid}"):
        raise ValueError(f"unsafe game id for a shortcut: {store}:{gid}")
    if not resolved.get("exe"):
        raise ValueError("no executable resolved for this game")
    return {
        "AppName": title,
        # The game binary itself (model B): Steam runs it through the compat tool we set, so SLR4
        # + Proton + FEX are Steam's to compose. Quoted like Steam's own UI writes Exe paths.
        "Exe": f'"{resolved["exe"]}"',
        "StartDir": f'"{resolved.get("startdir") or os.path.dirname(resolved["exe"])}"',
        # Per-game FEX tuning by the same door a Steam game uses; the token is NOT here — identity
        # lives in the registry, joined by appid.
        "LaunchOptions": launch.LAUNCH_OPTIONS,
    }


def is_ours(entry, roots):
    """THE ownership test (milestone 6): the entry's Exe resolves under a managed game root.
    `roots` is launch.managed_roots(p). Quoted and lowercase-key forms both occur in real files."""
    exe = entry.get("Exe") if isinstance(entry.get("Exe"), str) else entry.get("exe", "")
    return launch.under_managed_root(exe, roots)


def add_payload(req, store, gid, title, resolved):
    """The event payload the frontend bridge executes for an add. The API takes UNQUOTED paths
    (Steam quotes its own file), so the quotes come back off."""
    fields = entry_fields(store, gid, title, resolved)
    return {"op": "add", "req": req, "name": fields["AppName"],
            "exe": fields["Exe"].strip('"'), "dir": fields["StartDir"].strip('"'),
            "options": fields["LaunchOptions"]}


def remove_payload(req, appid):
    return {"op": "remove", "req": req, "appid": int(appid)}


def compat_payload(req, appid, tool):
    """Set a compat tool on a shortcut (Windows → our Proton). Steam keys CompatToolMapping by the
    UNSIGNED appid; the frontend bridge does the >>> 0 and verifies the tool is installed first."""
    return {"op": "compat", "req": req, "appid": int(appid), "tool": tool}


def check_register(registry, store, gid):
    """The refusal, or None. One entry per token: a registered id must be deregistered first."""
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
    """Every shortcuts.vdf Steam keeps for the store user — home from passwd, not hardcoded (the
    suite bans /home/deck literals outside paths.py). The glob tolerates several users; sorted."""
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


def our_entries(vdf_bytes, roots):
    """Every entry in the given shortcuts.vdf bytes whose Exe is under a managed root. Raises on
    bytes that do not parse — the caller must treat that as 'unknown', never as 'none'."""
    root, _ = _read_binary_vdf_object(vdf_bytes)
    shortcuts_obj = root.get("shortcuts", {})
    if not isinstance(shortcuts_obj, dict):
        raise ValueError("no shortcuts object in the file")
    return [{"key": key, "appid": entry.get("appid"), "AppName": entry.get("AppName")}
            for key, entry in shortcuts_obj.items()
            if isinstance(entry, dict) and is_ours(entry, roots)]


def orphan_report(vdf_bytes, registry, roots):
    """Join the file against the registry BY APPID. REPORT ONLY — nothing here deletes.

      healthy                 ours (by path) and its appid is in the registry
      orphan_unregistered     ours (by path) but no registry row claims its appid
      registry_without_entry  a registry row whose appid has no owned entry in the file
    """
    entries = our_entries(vdf_bytes, roots)
    appid_to_token = {row["appid"]: token for token, row in registry.items()
                      if isinstance(row, dict) and "appid" in row}
    entry_appids = {e["appid"] for e in entries}
    return {
        "healthy": [{**e, "token": appid_to_token[e["appid"]]}
                    for e in entries if e["appid"] in appid_to_token],
        "orphan_unregistered": [e for e in entries if e["appid"] not in appid_to_token],
        "registry_without_entry": [
            {"token": token, "appid": row["appid"]} for token, row in registry.items()
            if isinstance(row, dict) and "appid" in row and row["appid"] not in entry_appids],
    }
