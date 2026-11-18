"""Where a GOG game's cloud-save location is on the host, inside its Proton prefix.

    resolve(location, install, prefix) -> (host path, None) | (None, reason)

GOG's remote-config names each save location with its own tokens (`<?DOCUMENTS?>/Another World`)
or Windows variables (`%LocalAppData%/...`, Heroic's default when a game names none). Heroic
expands the tokens to variables and asks Wine (`winepath`) for the host path. That would start
Proton under FEX before every sync, so here the answer is read from the data Wine itself reads:
the prefix's `user.reg`. Called by the launch side, where STEAM_COMPAT_DATA_PATH names the prefix
(.claude/plans/gog-galaxy-comet.plan.md design §5).

WHERE EACH FOLDER IS comes from the prefix, not from assumptions about Proton:
  - the tokens from `User Shell Folders` (Personal, Local AppData, AppData, and the Saved Games
    and LocalLow known-folder ids), which a game's installer or winecfg may have redirected;
  - %USERPROFILE%, %APPDATA% and %LOCALAPPDATA% from `Volatile Environment`, which Wine rewrites
    on every start, so the user name is the prefix's own.
Only a prefix that does not exist yet (a first launch) uses the TABLE below. It is what both
shipped Protons create: they carry Valve's migrate_user_paths(), which moves the XP-era names to
these, and Another World's prefix on the Pocket Max matched it value for value (HW 2026-11-18).
%ProgramData% and %PUBLIC% always come from the table; they live in system.reg, which is large.

REFUSED, with a reason the game page can show (a location is never dropped silently):
  - an unknown token or variable, or the macOS-only <?APPLICATION_SUPPORT?>;
  - a location anchored nowhere (no token, variable or C:), or on another drive letter, which
    includes a registry folder pointed at Z: (the Linux root);
  - a path that leaves the prefix's drive_c or the install folder, by `..` OR through a symlink.
    A download deletes local files the cloud lacks, so a location must never reach outside them:
    winecfg can link Documents to the Linux home, where a sync of `<?DOCUMENTS?>` would delete
    the user's own files. Proton's own links (`My Documents` -> `./Documents`) stay inside.

CASE. Wine is case-insensitive and the game may have created `Another World` where GOG says
`another world`. Each level that already exists is matched in any case, so the sync uses the
game's own folder instead of creating a second one; a level that does not exist yet keeps GOG's
spelling.
"""
import os
import re

INSTALL = "\0INSTALL"  # stands for the install folder until the anchor is chosen
# GOG's tokens (Heroic save_sync.ts gogVariableMap): the default Windows path of each, and the
# `User Shell Folders` value that overrides it.
TOKENS = {
    "DOCUMENTS": "%USERPROFILE%/Documents",
    "SAVED_GAMES": "%USERPROFILE%/Saved Games",
    "APPLICATION_DATA_LOCAL": "%LOCALAPPDATA%",
    "APPLICATION_DATA_LOCAL_LOW": "%USERPROFILE%/AppData/LocalLow",
    "APPLICATION_DATA_ROAMING": "%APPDATA%",
    "INSTALL": INSTALL,
}
TOKEN_VALUES = {
    "DOCUMENTS": "Personal",
    "SAVED_GAMES": "{4C5C32FF-BB9D-43B0-B5B4-2D72E54EAAA4}",
    "APPLICATION_DATA_LOCAL": "Local AppData",
    "APPLICATION_DATA_LOCAL_LOW": "{A520A1A4-1780-4FF6-BD18-167343C5AF16}",
    "APPLICATION_DATA_ROAMING": "AppData",
}
MACOS_TOKENS = {"APPLICATION_SUPPORT"}
# Windows variables: the default of each; those in `Volatile Environment` are overridden by it.
VARIABLES = {
    "USERPROFILE": "C:/users/steamuser",
    "LOCALAPPDATA": "C:/users/steamuser/AppData/Local",
    "APPDATA": "C:/users/steamuser/AppData/Roaming",
    "PROGRAMDATA": "C:/ProgramData",
    "PUBLIC": "C:/users/Public",
}
REG_FOLDERS = "Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\User Shell Folders"
REG_ENVIRONMENT = "Volatile Environment"
_TOKEN = re.compile(r"<\?(\w+)\?>")
_VARIABLE = re.compile(r"%(\w+)%")
_DRIVE = re.compile(r"^([A-Za-z]):(.*)$")
# A Wine .reg value line: "name"="data" (REG_SZ) or "name"=str(2):"data" (REG_EXPAND_SZ).
_REG_VALUE = re.compile(r'^"((?:[^"\\]|\\.)*)"=(?:str\(2\):)?"((?:[^"\\]|\\.)*)"$')
_REG_ESCAPE = re.compile(r"\\(x[0-9a-fA-F]{1,4}|.)")


class Refused(Exception):
    pass


def _unescape(text):
    """A Wine .reg string: \\\\ and \\" are the characters, \\xHHHH a UTF-16 code unit."""
    def one(m):
        s = m.group(1)
        return chr(int(s[1:], 16)) if s[0] == "x" and len(s) > 1 else s
    return _REG_ESCAPE.sub(one, text)


def read_registry(path, keys):
    """{key casefold: {value name casefold: data}} for the string values of `keys` in a Wine .reg
    file. A missing or unreadable file is {}."""
    wanted = {k.casefold() for k in keys}
    out, current = {}, None
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.rstrip("\n")
                if line.startswith("["):
                    key = _unescape(line[1:line.rfind("]")]).casefold()
                    current = out.setdefault(key, {}) if key in wanted else None
                elif current is not None:
                    m = _REG_VALUE.match(line)
                    if m:
                        current[_unescape(m.group(1)).casefold()] = _unescape(m.group(2))
    except OSError:
        return {}
    return out


def folders(prefix):
    """(tokens, variables) for this prefix: the registry's values over the table's."""
    reg = read_registry(os.path.join(prefix, "user.reg"), [REG_FOLDERS, REG_ENVIRONMENT])
    shell = reg.get(REG_FOLDERS.casefold(), {})
    env = reg.get(REG_ENVIRONMENT.casefold(), {})
    tokens = {**TOKENS, **{t: shell[v.casefold()] for t, v in TOKEN_VALUES.items()
                           if shell.get(v.casefold())}}
    variables = {**VARIABLES, **{n: env[n.casefold()] for n in VARIABLES if env.get(n.casefold())}}
    return tokens, variables


def _expand_tokens(location, tokens):
    def token(m):
        name = m.group(1).upper()
        if name in MACOS_TOKENS:
            raise Refused(f"{name} is a macOS location")
        if name not in tokens:
            raise Refused(f"unknown GOG location token {name}")
        return tokens[name]
    return _TOKEN.sub(token, location)


def _expand_variables(location, variables):
    def variable(m):
        name = m.group(1).upper()
        if name not in variables:
            raise Refused(f"unknown Windows variable %{name}%")
        return variables[name]
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


def _inside(path, roots):
    """Is path's REAL location (every symlink resolved) inside one of roots' real locations?"""
    real = os.path.realpath(path)
    for root in roots:
        r = os.path.realpath(root)
        if real == r or real.startswith(r.rstrip(os.sep) + os.sep):
            return True
    return False


def resolve(location, install, prefix):
    """The host path of a GOG save location for this install and Proton prefix (the `pfx` dir).
    Returns (path, None), or (None, reason) when the location is refused."""
    if not isinstance(location, str) or not location.strip():
        return None, "empty location"
    tokens, variables = folders(prefix)
    try:
        path = _expand_variables(_expand_tokens(location.strip(), tokens), variables)
        root, rest = _anchor(path.replace("\\", "/"), install, prefix)
        resolved = _match_case(root, _components(rest))
    except Refused as exc:
        return None, str(exc)
    except OSError as exc:
        return None, f"location not readable ({exc.strerror})"
    if not _inside(resolved, (os.path.join(prefix, "drive_c"), install)):
        return None, "location leads outside the prefix and the install folder through a symlink"
    return resolved, None
