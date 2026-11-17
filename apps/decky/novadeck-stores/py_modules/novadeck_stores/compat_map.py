"""Which store entries Steam already has a compat tool mapped for, read from config.vdf.

reassert_compat (main.py) re-sends our Proton to every store entry when SteamUI comes up, because
SpecifyCompatTool lives in memory until Steam flushes config.vdf and a late set can be lost to a
crash. Done blindly, that also overwrote what the user picked in Properties -> Compatibility —
Boxtron for a GOG DOS game, Proton-GE for a title CachyOS runs badly — on every boot
(.claude/plans/boxtron-dos.plan.md, phase 2). So it now re-sets only entries with NO mapping: a
mapping on disk is either the user's choice or our own set, already flushed, and neither needs us.

Read at frontend-ready, which is right after Steam started: the file then holds everything the last
session flushed, including the user's changes (Steam writes them promptly; HW 2026-11-17, Pocket
FIT, a Properties change was on disk within the minute).

The failure mode is the OLD behaviour, on purpose: a file that cannot be read or parsed yields None
("nothing known"), and the caller re-asserts as it always did. Never an empty set that could be
mistaken for "nothing mapped" — that would be the same answer, but by accident.

Text VDF: quoted (or bare) tokens, `{`/`}` blocks, `//` comments, and `\\"`/`\\\\` escapes inside
strings. ROOT reads this file in a tree the user owns, so it goes through status.open_user_file.
"""
import os

from novadeck_stores import status

BLOCK = "compattoolmapping"


def config_vdf_path(p):
    """The store user's Steam config.vdf — home from passwd, never a /home/deck literal."""
    home = os.path.expanduser(f"~{p['NOVADECK_STORE_USER']}")
    return os.path.join(home, ".local", "share", "Steam", "config", "config.vdf")


def _tokens(text):
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c.isspace():
            i += 1
        elif text.startswith("//", i):
            nl = text.find("\n", i)
            i = n if nl < 0 else nl + 1
        elif c in "{}":
            yield c
            i += 1
        elif c == '"':
            out, i = [], i + 1
            while True:
                if i >= n:
                    raise ValueError("unterminated string")
                c = text[i]
                if c == "\\" and i + 1 < n and text[i + 1] in '"\\':
                    out.append(text[i + 1])
                    i += 2
                elif c == '"':
                    i += 1
                    break
                else:
                    out.append(c)
                    i += 1
            yield ("str", "".join(out))
        else:
            start = i
            while i < n and not text[i].isspace() and text[i] not in '{}"':
                i += 1
            yield ("str", text[start:i])


def parse(text):
    """Nested dicts from text VDF. Raises ValueError on anything malformed."""
    root, stack, key = {}, [], None
    cur = root
    for tok in _tokens(text):
        if tok == "{":
            if key is None:
                raise ValueError("block without a key")
            child = {}
            cur[key] = child
            stack.append(cur)
            cur, key = child, None
        elif tok == "}":
            if key is not None or not stack:
                raise ValueError("unbalanced close brace")
            cur = stack.pop()
        elif key is None:
            key = tok[1]
        else:
            cur[key] = tok[1]
            key = None
    if stack or key is not None:
        raise ValueError("unexpected end of file")
    return root


def _find_block(node):
    for k, v in node.items():
        if isinstance(v, dict):
            if k.casefold() == BLOCK:
                return v
            found = _find_block(v)
            if found is not None:
                return found
    return None


def mapped_from(data):
    """Unsigned appids with a non-empty tool name under CompatToolMapping. Appid 0 is Steam's
    global default, not an entry."""
    block = _find_block(data) or {}
    return {int(k) & 0xFFFFFFFF for k, v in block.items()
            if k.isdigit() and int(k) != 0 and isinstance(v, dict) and v.get("name")}


def mapped_appids(path, uid):
    """The set of mapped appids, or None when the file cannot be read or parsed."""
    f = status.open_user_file(path, uid)
    if f is None:
        return None
    try:
        with f:
            return mapped_from(parse(f.read().decode("utf-8", "replace")))
    except (OSError, ValueError):
        return None
