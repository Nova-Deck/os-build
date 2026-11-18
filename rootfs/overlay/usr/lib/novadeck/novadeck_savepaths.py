"""Where a GOG game's cloud-save location is on the host, inside its Proton prefix.

    resolve(location, install, prefix) -> (host path, None) | (None, reason)

GOG's remote-config names each save location with its own tokens (`<?DOCUMENTS?>/Another World`)
or Windows variables (`%LocalAppData%/...`, Heroic's default when a game names none). Heroic
expands the tokens to variables and asks Wine (`winepath`) for the host path. A Proton prefix's
layout is fixed (`drive_c/users/steamuser/...`), so here a table does it: testable offline, and no
Wine run before a launch. Called by the launch side, where STEAM_COMPAT_DATA_PATH names the prefix
(.claude/plans/gog-galaxy-comet.plan.md design §5).

REFUSED, with a reason the game page can show (a location is never dropped silently):
  - an unknown token or variable, or the macOS-only <?APPLICATION_SUPPORT?>;
  - a location anchored nowhere (no token, variable or C:), or on another drive letter;
  - a path whose `..` climbs out of the prefix's drive_c or the install folder. A download
    deletes local files the cloud lacks, so a location must never reach outside them.
Containment is lexical. The sync runs as the store user, so a symlink inside the prefix reaches
nothing that user could not already touch.

CASE. Wine is case-insensitive and the game may have created `Another World` where GOG says
`another world`. Each level that already exists is matched in any case, so the sync uses the
game's own folder instead of creating a second one; a level that does not exist yet keeps GOG's
spelling.
"""
import os
import re

INSTALL = "\0INSTALL"  # stands for the install folder until the anchor is chosen
# GOG's tokens (Heroic save_sync.ts gogVariableMap), expanded to Windows variables.
TOKENS = {
    "DOCUMENTS": "%USERPROFILE%/Documents",
    "SAVED_GAMES": "%USERPROFILE%/Saved Games",
    "APPLICATION_DATA_LOCAL": "%LOCALAPPDATA%",
    "APPLICATION_DATA_LOCAL_LOW": "%USERPROFILE%/AppData/LocalLow",
    "APPLICATION_DATA_ROAMING": "%APPDATA%",
    "INSTALL": INSTALL,
}
MACOS_TOKENS = {"APPLICATION_SUPPORT"}
# Windows variables, as the paths Proton's prefix gives them.
VARIABLES = {
    "USERPROFILE": "C:/users/steamuser",
    "LOCALAPPDATA": "C:/users/steamuser/AppData/Local",
    "APPDATA": "C:/users/steamuser/AppData/Roaming",
    "PROGRAMDATA": "C:/ProgramData",
    "PUBLIC": "C:/users/Public",
}
_TOKEN = re.compile(r"<\?(\w+)\?>")
_VARIABLE = re.compile(r"%(\w+)%")
_DRIVE = re.compile(r"^([A-Za-z]):(.*)$")


class Refused(Exception):
    pass


def _expand_tokens(location):
    def token(m):
        name = m.group(1).upper()
        if name in MACOS_TOKENS:
            raise Refused(f"{name} is a macOS location")
        if name not in TOKENS:
            raise Refused(f"unknown GOG location token {name}")
        return TOKENS[name]
    return _TOKEN.sub(token, location)


def _expand_variables(location):
    def variable(m):
        name = m.group(1).upper()
        if name not in VARIABLES:
            raise Refused(f"unknown Windows variable %{name}%")
        return VARIABLES[name]
    return _VARIABLE.sub(variable, location)


def _anchor(path, install, prefix):
    """(root, rest) for a path that starts at the install folder or at C:."""
    if path.startswith(INSTALL):
        return install, path[len(INSTALL):]
    drive = _DRIVE.match(path)
    if drive is None:
        raise Refused(f"location {path!r} is not anchored to a known folder")
    if drive.group(1).upper() != "C":
        raise Refused(f"drive {drive.group(1).upper()}: is not the prefix's C:")
    return os.path.join(prefix, "drive_c"), drive.group(2)


def _components(rest):
    """The path's components with `.` and `..` applied; refused if `..` leaves the root."""
    parts = []
    for part in rest.split("/"):
        if part in ("", "."):
            continue
        if part == "..":
            if not parts:
                raise Refused("location resolves outside the prefix and the install folder")
            parts.pop()
        else:
            parts.append(part)
    return parts


def _match_case(root, parts):
    """root joined with parts, each level that exists taken in its on-disk case."""
    path = root
    for i, part in enumerate(parts):
        if not os.path.isdir(path):
            return os.path.join(path, *parts[i:])
        if not os.path.lexists(os.path.join(path, part)):
            folded = part.casefold()
            same = sorted(n for n in os.listdir(path) if n.casefold() == folded)
            part = same[0] if same else part
        path = os.path.join(path, part)
    return path


def resolve(location, install, prefix):
    """The host path of a GOG save location for this install and Proton prefix (the `pfx` dir).
    Returns (path, None), or (None, reason) when the location is refused."""
    if not isinstance(location, str) or not location.strip():
        return None, "empty location"
    try:
        path = _expand_variables(_expand_tokens(location.strip())).replace("\\", "/")
        root, rest = _anchor(path, install, prefix)
        return _match_case(root, _components(rest)), None
    except Refused as exc:
        return None, str(exc)
    except OSError as exc:
        return None, f"location not readable ({exc.strerror})"
