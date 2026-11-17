"""Reading the paths and command lines GOG's goggame-<id>.info files hold, on Linux.

GOG's metadata is written for Windows and is messier than its schema (all of this is on a real
install — Master of Magic on a Pocket FIT, see tests/test-store-dos-targets.sh):
  - paths mix `/` and `\\` and get the case wrong (`DOSBOX\\dosbox.exe` for DOSBox.exe);
  - a workingDir can name a directory that does not exist where it says;
  - `arguments` is one Windows command-line string, quoted the Windows way, whose relative paths
    (`-conf "..\\x.conf"`) must keep their backslashes for the program that parses them.

Two callers: launch.py (the shortcut's exe, StartDir and arguments) and dos_targets.py (the DOSBox
command lines Boxtron can run).

ROOT reads the tree, which the store user owns: `..` components and NULs are refused, and no
symlinked component is followed.
"""
import os
import stat


def split_windows_args(line):
    """Split a Windows command line the way CommandLineToArgvW does: whitespace separates, double
    quotes group, `""` inside quotes is a literal quote, and backslashes are literal EXCEPT before
    a quote (2n of them → n plus a toggling quote; 2n+1 → n plus a literal quote). GOG's
    `..\\x.conf` must keep its backslash."""
    if not line:
        return []
    args, cur, in_token, quoted, i = [], [], False, False, 0
    while i < len(line):
        c = line[i]
        if c == "\\":
            n = 0
            while i < len(line) and line[i] == "\\":
                n += 1
                i += 1
            if i < len(line) and line[i] == '"':
                cur.append("\\" * (n // 2))
                if n % 2:
                    cur.append('"')
                    i += 1
            else:
                cur.append("\\" * n)
            in_token = True
            continue
        if c == '"' and quoted and line[i + 1:i + 2] == '"':
            cur.append('"')  # `""` inside quotes: a literal quote, still quoted
            in_token = True
            i += 2
            continue
        if c == '"':
            quoted = not quoted
            in_token = True
        elif c in " \t" and not quoted:
            if in_token:
                args.append("".join(cur))
                cur, in_token = [], False
        else:
            cur.append(c)
            in_token = True
        i += 1
    if in_token:
        args.append("".join(cur))
    return args


def shell_safe(args):
    """`args` when no token carries a control character, else []. These end up in Steam's
    LaunchOptions, which a shell runs; quoting handles everything else, but a newline or a NUL in a
    GOG argument has no legitimate use and is the one thing worth refusing outright."""
    if any(ord(ch) < 0x20 or ch == "\x7f" for a in args for ch in a):
        return []
    return args


def parts(rel):
    """A GOG relative path's components, or None when one of them climbs (`..`) or holds a NUL
    (which the os calls below reject with ValueError, not OSError)."""
    if "\0" in rel:
        return None
    found = [x for x in rel.replace("\\", "/").split("/") if x not in ("", ".")]
    return None if any(x == ".." for x in found) else found


def join(base, rel):
    """`rel` under `base` with its separators normalised, whether or not it exists — for a path the
    caller needs even when the file is not (yet) there. None for a climbing or NUL path."""
    found = parts(rel) if isinstance(rel, str) else None
    return os.path.join(base, *found) if found else None


def _child(directory, name):
    """The entry of `directory` named `name`, matched exactly first, then case-insensitively when
    exactly one entry matches. None for a missing, ambiguous or symlinked entry."""
    exact = os.path.join(directory, name)
    try:
        if not stat.S_ISLNK(os.lstat(exact).st_mode):
            return exact
        return None
    except OSError:
        pass
    try:
        with os.scandir(directory) as it:
            hits = [e for e in it if e.name.casefold() == name.casefold()]
    except OSError:
        return None
    if len(hits) != 1 or hits[0].is_symlink():
        return None
    return hits[0].path


def resolve(base, rel, want_dir=False):
    """`rel` (a GOG path, any separators, any case) under `base`, or None. The result is a regular
    file — or a directory with want_dir — reached through no symlink and no `..`."""
    found = parts(rel) if isinstance(rel, str) else None
    if not found:
        return None
    cur = base
    for name in found:
        cur = _child(cur, name)
        if cur is None:
            return None
    try:
        mode = os.lstat(cur).st_mode
    except OSError:
        return None
    return cur if (stat.S_ISDIR(mode) if want_dir else stat.S_ISREG(mode)) else None
