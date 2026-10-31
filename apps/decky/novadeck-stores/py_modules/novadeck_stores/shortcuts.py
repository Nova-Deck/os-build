"""Steam library entries for alien games — the template, the ownership rule, the registry, and
the verification reader.

NOTHING HERE WRITES shortcuts.vdf. Entries are created and removed through Steam's own live API
(SteamClient.Apps.AddShortcut / RemoveShortcut, reachable only from the plugin frontend), so
Steam persists its own file and the ecosystem's restart-and-rewrite pathology — the write guards,
foreign-entry merges and backups unifideck carries for its direct writes — has nothing to attach
to. This module decides WHAT the frontend writes and verifies WHAT landed.

Two rules, the first amended by milestones 6 and 7:

  - OWNERSHIP IS REGISTRY MEMBERSHIP. An entry is ours iff its appid is in our registry: we
    created every entry we will ever touch, and recorded it the moment Steam handed back the
    appid. Milestone 7 registers the whole owned library — not-installed tiles whose Exe is the
    install stub as well as installed model-B entries whose Exe is the game — so neither earlier
    proxy (the stub's basename in milestone 4, the managed-root path in milestone 6) covers both
    shapes. The managed-root test survives only as the orphan report's secondary signal: an entry
    under our game roots that no registry row claims. Tags and the token are NEVER ownership —
    foreign tools copy both (unifideck incident UD-006).

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

from novadeck_stores import cli, first_run, launch, status

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
        # lives in the registry, joined by appid. A Windows title the umu database knows is
        # prefixed with its protonfixes ids (launch.protonfix_env), which Proton reads.
        "LaunchOptions": " ".join(filter(None, [resolved.get("env"), launch.LAUNCH_OPTIONS])),
    }


# The not-installed tile's Exe (milestone 7): it requests the install and exits, never launches.
STUB = "/usr/lib/novadeck/store-launch"


def shelf_fields(store, gid, title):
    """The fields a NOT-INSTALLED tile is created with: Exe = the install stub, LaunchOptions =
    exactly the token (the stub's argv[1] contract). No compat tool — the stub is native, and
    nothing launched through it needs Proton or SLR."""
    token = f"{store}:{gid}"
    if not TOKEN.fullmatch(token):
        raise ValueError(f"unsafe game id for a shortcut: {token}")
    return {"AppName": title, "Exe": f'"{STUB}"', "StartDir": f'"{os.path.dirname(STUB)}"',
            "LaunchOptions": token}


def shelf_payload(req, store, gid, title):
    fields = shelf_fields(store, gid, title)
    return {"op": "add", "req": req, "name": fields["AppName"],
            "exe": fields["Exe"].strip('"'), "dir": fields["StartDir"].strip('"'),
            "options": fields["LaunchOptions"]}


def is_shelf(row):
    """A registry row for a tile that is not installed yet. Rows written before milestone 7 have
    no state and are installed entries."""
    return isinstance(row, dict) and row.get("state") == "shelf"


def _u32(appid):
    """Shortcut appids compared as Steam's file stores them: unsigned 32-bit. A signed int from
    the live API and the unsigned one in shortcuts.vdf name the same entry."""
    return appid & 0xFFFFFFFF if isinstance(appid, int) and not isinstance(appid, bool) else None


def registry_appids(registry):
    """The set of (unsigned) appids our registry claims — each row's live appid AND any `retired`
    ones: an entry replaced at the install transition whose removal Steam has not yet confirmed
    is still ours to retry."""
    out = set()
    for row in registry.values():
        if not isinstance(row, dict):
            continue
        retired = row.get("retired") if isinstance(row.get("retired"), list) else []
        out |= {a for a in (_u32(x) for x in [row.get("appid"), *retired]) if a is not None}
    return out


def is_ours(entry, appids):
    """THE ownership test (milestone 7): the entry's appid is one our registry recorded. `appids`
    is registry_appids(registry). Exe, tags and options play no part."""
    appid = _u32(entry.get("appid"))
    return appid is not None and appid in appids


def _under_roots(entry, roots):
    exe = entry.get("Exe") if isinstance(entry.get("Exe"), str) else entry.get("exe", "")
    return launch.under_managed_root(exe, roots)


def add_payload(req, store, gid, title, resolved):
    """The event payload the frontend bridge executes for an add. The API takes UNQUOTED paths
    (Steam quotes its own file), so the quotes come back off."""
    fields = entry_fields(store, gid, title, resolved)
    return {"op": "add", "req": req, "name": fields["AppName"],
            "exe": fields["Exe"].strip('"'), "dir": fields["StartDir"].strip('"'),
            "options": fields["LaunchOptions"]}


def remove_payload(req, appid, moved_to=None):
    """`moved_to` names the entry that replaces this one (an install transition). Steam sends an
    open page of a removed app to the library home, so the bridge moves that page to the
    replacement BEFORE removing — the page cannot follow on its own (HW 2026-10-22)."""
    return {"op": "remove", "req": req, "appid": int(appid),
            **({"moved_to": int(moved_to)} if moved_to is not None else {})}


def edit_payload(req, appid, payload):
    """Change an existing entry IN PLACE into what `payload` (an add_payload or shelf_payload)
    would create. The install transitions use this, not remove + re-add: the appid survives, and
    with it Steam's play time, last played, art, collections and an open game page. Probed on the
    arm64 client 2026-10-22: SetShortcutExe & co. keep the appid, reach shortcuts.vdf within the
    second, and survive a Steam restart."""
    # Exe QUOTED: AddShortcut re-quotes the Exe it stores (milestone 4), SetShortcutExe stores
    # exactly what it is given (the probe), and a GOG install folder has spaces in it. StartDir
    # stays unquoted, as AddShortcut leaves it.
    return {"op": "edit", "req": req, "appid": int(appid), "name": payload["name"],
            "exe": f'"{payload["exe"]}"', "dir": payload["dir"], "options": payload["options"]}


def compat_payload(req, appid, tool):
    """Set a compat tool on a shortcut (Windows → our Proton), or clear it with tool "" (Steam logs
    "Unmapping AppID", HW 2026-10-22). Steam keys CompatToolMapping by the UNSIGNED appid; the
    frontend bridge does the >>> 0."""
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
    ok = cli.write_as_user(p, registry_path(p), json.dumps(rows, indent=1)) == 0
    if ok:
        # Every change to which appid is which game passes here, so the first-run steps keyed
        # by appid follow it. Best effort: the registry is what was asked for, and a stale
        # steps file only means a support installer waits for the next registry write.
        try:
            first_run.sync(p, rows)
        except Exception:  # noqa: BLE001 - must not turn a written registry into a failure
            pass
    return ok


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


def _file_entries(vdf_bytes):
    """Every entry dict in the given shortcuts.vdf bytes. Raises on bytes that do not parse — the
    caller must treat that as 'unknown', never as 'none'."""
    root, _ = _read_binary_vdf_object(vdf_bytes)
    shortcuts_obj = root.get("shortcuts", {})
    if not isinstance(shortcuts_obj, dict):
        raise ValueError("no shortcuts object in the file")
    return [(key, entry) for key, entry in shortcuts_obj.items() if isinstance(entry, dict)]


def _summary(key, entry):
    return {"key": key, "appid": entry.get("appid"), "AppName": entry.get("AppName")}


def our_entries(vdf_bytes, registry):
    """Every entry in the file whose appid the registry claims. Raises on unparseable bytes."""
    appids = registry_appids(registry)
    return [_summary(key, entry) for key, entry in _file_entries(vdf_bytes)
            if is_ours(entry, appids)]


def orphan_report(vdf_bytes, registry, roots):
    """Join the file against the registry BY APPID. REPORT ONLY — nothing here deletes.

      healthy                 its appid is in the registry (ours)
      orphan_unregistered     Exe under a managed game root, but no registry row claims its
                              appid — the secondary signal: something we probably made and lost
                              track of, which we still never touch
      registry_without_entry  a registry row whose appid has no entry in the file
    """
    entries = _file_entries(vdf_bytes)
    appid_to_token = {}
    for token, row in registry.items():
        if isinstance(row, dict):
            retired = row.get("retired") if isinstance(row.get("retired"), list) else []
            appid_to_token.update({_u32(a): token for a in retired if _u32(a) is not None})
    appid_to_token.update({_u32(row["appid"]): token for token, row in registry.items()
                           if isinstance(row, dict) and _u32(row.get("appid")) is not None})
    file_appids = {_u32(entry.get("appid")) for _, entry in entries}
    return {
        "healthy": [{**_summary(key, entry), "token": appid_to_token[_u32(entry.get("appid"))]}
                    for key, entry in entries if _u32(entry.get("appid")) in appid_to_token],
        "orphan_unregistered": [_summary(key, entry) for key, entry in entries
                                if _u32(entry.get("appid")) not in appid_to_token
                                and _under_roots(entry, roots)],
        "registry_without_entry": [
            {"token": token, "appid": row["appid"]} for token, row in registry.items()
            if isinstance(row, dict) and _u32(row.get("appid")) is not None
            and _u32(row["appid"]) not in file_appids],
    }
