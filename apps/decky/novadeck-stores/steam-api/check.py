#!/usr/bin/env python3
"""Check an unpacked steamui bundle against steam-api/tokens.

    python3 -I check.py <tokens> <steamui-dir>

One line per token: `ok`, `MISSING` or `UNCHECKED`. Exit 0 when nothing is missing, 1 when
something is, 2 when the directory holds no bundle to look at — a checker that cannot see must not
report a pass.
"""
import pathlib
import re
import sys


def code_text(root: pathlib.Path) -> str:
    # Localization tables carry UI strings as data; a marker found only there proves nothing about
    # the code the plugin searches. The zip stores Windows separators, so on Linux a nested file's
    # NAME can contain "localization" with no directory of that name — test the whole path string.
    files = [p for p in root.rglob("*.js") if p.is_file() and "localization" not in str(p)]
    if not any(p.name.endswith("sp.js") for p in files):
        return ""
    return "\n".join(p.read_text(errors="replace") for p in files)


def css_modules(code: str, finder: str) -> list[str]:
    # A CSS module compiles to a flat {Key:"hash",...} literal: no nested braces inside.
    return re.findall(r'\{[^{}]*[{,]%s:"[^"]*"[^{}]*\}' % re.escape(finder), code)


def check(kind: str, args: list[str], code: str) -> str | None:
    """None when present, a reason when missing. Raises KeyError for an unchecked kind."""
    if kind == "api":
        found = re.search(r"SteamClient\.Apps\??\.%s\b" % re.escape(args[0]), code)
        return None if found else "no SteamClient.Apps call in the bundle"
    if kind == "global":
        return None if re.search(r"window\.%s\b" % re.escape(args[0]), code) else "never assigned on window"
    if kind == "store":
        found = re.search(r"\b%s\([\w$,\s]*\)\{" % re.escape(args[0]), code)
        return None if found else "no method of that name is defined"
    if kind == "marker":
        return None if args[0] in code else "absent from the code (localization does not count)"
    if kind == "oneof":
        return None if any(a in code for a in args) else "none of the shapes is present"
    if kind == "class":
        _export, finder, key = args
        modules = css_modules(code, finder)
        if not modules:
            return f"no CSS module has the finder key {finder}"
        if not any(re.search(r'[{,]%s:"' % re.escape(key), m) for m in modules):
            return f"the {finder} module has no {key}"
        return None
    raise KeyError(kind)


def main() -> int:
    tokens, root = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
    code = code_text(root)
    if not code:
        print(f"cannot see a steamui bundle (no sp.js) under {root}")
        return 2
    missing = 0
    for line in tokens.read_text().splitlines():
        fields = line.split("#", 1)[0].split()
        if not fields or fields[0] == "decky-ui":
            continue
        kind, args = fields[0], fields[1:]
        label = f"{kind} {' '.join(args)}"
        if kind in ("native", "binding", "decky"):
            print(f"UNCHECKED {label} — {'the Decky loader' if kind == 'decky' else 'device only'}")
            continue
        reason = check(kind, args, code)
        if reason is None:
            print(f"ok        {label}")
        else:
            print(f"MISSING   {label} — {reason}")
            missing += 1
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
