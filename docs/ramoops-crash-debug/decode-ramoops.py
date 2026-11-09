#!/usr/bin/env python3
"""Decode a bit-decayed ramoops console against a clean reference dmesg.

The FIT's RAM loses charge across a reset: bits go 1 -> 0 (almost never 0 -> 1). So a decayed
byte g can only come from a clean byte c with g & ~c == 0. Each garbled line is scored against
every reference line on the message text (the timestamp differs per boot anyway), and printed
next to its best match. Lines with no good match are flagged: those are what a normal boot does
not print, and the reason this exists.

usage: decode-ramoops.py CONSOLE REFERENCE_DMESG [--tail N] [--all]
"""
import re
import sys

NL = 0x0A


def is_nl(b):
    return b != 0 and (b & ~NL) == 0  # 0x0a, 0x08, 0x02 (0x00 is padding/zeros)


def split_lines(raw):
    # Drop the zeroed tail: the log ends where the zeros start (allow a few stray bytes).
    end = len(raw)
    zrun = 0
    for i, b in enumerate(raw):
        zrun = zrun + 1 if b == 0 else 0
        if zrun >= 64:
            end = i - 63
            break
    raw = raw[:end]
    lines, cur = [], bytearray()
    for b in raw:
        if is_nl(b) and len(cur) >= 8:
            lines.append(bytes(cur))
            cur = bytearray()
        else:
            cur.append(b)
    if cur:
        lines.append(bytes(cur))
    return lines, end


TS = re.compile(rb"^\[[ 0-9.]+\] ?")


def ref_lines(path):
    out = []
    with open(path, "rb") as f:
        for line in f:
            line = line.rstrip(b"\n")
            m = TS.match(line)
            if m:
                out.append(line[m.end():])
    return out


def strip_ts(g):
    # "[  123.456789] " is 15 bytes; find the "] " (0x5d 0x20, possibly decayed) near there.
    for k in range(10, min(len(g), 22)):
        if (g[k] & ~0x5D) == 0 and k + 1 < len(g) and (g[k + 1] & ~0x20) == 0 and g[k] != 0:
            return g[k + 2:]
    return g[15:]


def score(g, c):
    """Fraction of positions where g could have decayed from c, with exact hits weighted up."""
    n = min(len(g), len(c))
    if n == 0:
        return 0.0
    ok = exact = 0
    for a, b in zip(g[:n], c[:n]):
        if (a & ~b) == 0:
            ok += 1
            if a == b:
                exact += 1
    # Penalise length mismatch: a decayed line keeps its length.
    lenpen = abs(len(g) - len(c)) / max(len(g), len(c))
    return (0.5 * ok + 0.5 * exact) / max(len(g), len(c)) - 0.3 * lenpen


def printable(b):
    return "".join(chr(x) if 32 <= x < 127 else "." for x in b)


def main():
    args = sys.argv[1:]
    tail = 40
    show_all = "--all" in args
    args = [a for a in args if a != "--all"]
    if "--tail" in args:
        i = args.index("--tail")
        tail = int(args[i + 1])
        del args[i:i + 2]
    console, ref = args
    raw = open(console, "rb").read()
    # pstore appends an "ECC: ..." line when it ran the ECC; drop it.
    raw = re.sub(rb"\nECC: [^\n]*\n?$", b"", raw)
    lines, end = split_lines(raw)
    refs = ref_lines(ref)
    print(f"{len(raw)} bytes, log ends at byte {end}, {len(lines)} lines; reference {len(refs)} lines")
    sel = lines if show_all else lines[-tail:]
    for g in sel:
        body = strip_ts(g)
        best, bs = None, -1.0
        for c in refs:
            if abs(len(c) - len(body)) > max(8, len(body) // 4):
                continue
            s = score(body, c)
            if s > bs:
                best, bs = c, s
        flag = "  " if bs >= 0.75 else "??" if bs >= 0.55 else "!!"
        print(f"{flag} {bs:4.2f} raw: {printable(g)[:110]}")
        if best is not None and bs >= 0.55:
            print(f"          ref: {best.decode(errors='replace')[:110]}")


if __name__ == "__main__":
    main()
