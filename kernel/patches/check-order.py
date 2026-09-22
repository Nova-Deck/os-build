#!/usr/bin/env python3
"""Lint the patch stack's numbering and naming convention.

build.sh applies patches in lexical order, so the numbering is load-bearing: it has to
sort the way it reads, and each number has to sit in the band that says when it applies.
This guards the convention from drifting back into the state it was renumbered out of
(two naming styles, five unnumbered files applying last by accident of ASCII).

What this does NOT check is the dependency invariant -- that two patches touching a
common file keep their relative order. That one is proved by the build: kernel/build.sh
applies with --fuzz=0, so a wrong order fails hard instead of landing a hunk quietly in
the wrong place.

Usage: ./check-order.py          # exits non-zero on any violation
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
NAME = re.compile(r"^(\d{4})-[a-z0-9][a-z0-9-]*\.patch$")
ALLOWED_NON_PATCH = {"README.md", "check-order.py"}

# (low, high, band) -- inclusive, must match the table in README.md
BANDS = [
    (0, 99, "core"),
    (100, 199, "clk"),
    (200, 299, "gpu"),
    (300, 399, "dpu"),
    (400, 479, "dsi"),
    (480, 499, "drmcore"),
    (500, 599, "panel"),
    (600, 699, "backlight/leds/pwm"),
    (700, 799, "input"),
    (800, 899, "audio"),
    (900, 999, "power/misc"),
    (1000, 1099, "net/usb/pci/crypto"),
    (1100, 1199, "dts"),
]


def band_of(num):
    for low, high, name in BANDS:
        if low <= num <= high:
            return name
    return None


def main():
    entries = sorted(os.listdir(HERE))
    problems = []

    strays = [e for e in entries
              if not e.endswith(".patch") and e not in ALLOWED_NON_PATCH]
    for s in strays:
        problems.append(f"unexpected file in patches/: {s}")

    patches = [e for e in entries if e.endswith(".patch")]
    if not patches:
        sys.exit("no patches found")

    numbers = {}
    for p in patches:
        m = NAME.match(p)
        if not m:
            problems.append(
                f"name does not match NNNN-lower-case-with-hyphens.patch: {p}")
            continue
        num = int(m.group(1))
        if band_of(num) is None:
            problems.append(f"number {num:04d} falls outside every band: {p}")
        numbers.setdefault(num, []).append(p)

    for num, files in sorted(numbers.items()):
        if len(files) > 1:
            problems.append(f"duplicate number {num:04d}: {', '.join(files)}")

    # build.sh globs lexically; that must equal numeric order or the stack applies
    # in an order nobody wrote down.
    named = [p for p in patches if NAME.match(p)]
    by_lex = sorted(named)
    by_num = sorted(named, key=lambda p: int(NAME.match(p).group(1)))
    if by_lex != by_num:
        for lex, num in zip(by_lex, by_num):
            if lex != num:
                problems.append(
                    f"lexical order diverges from numeric order at {lex} "
                    f"(numeric expects {num})")
                break

    counts = {}
    for num in numbers:
        b = band_of(num)
        if b:
            counts[b] = counts.get(b, 0) + 1
    print(f"patches: {len(patches)}")
    for _, _, name in BANDS:
        if counts.get(name):
            print(f"  {counts[name]:>3}  {name}")
    print(f"PROBLEMS: {len(problems)}")
    for p in problems:
        print(f"  {p}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
