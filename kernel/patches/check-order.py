#!/usr/bin/env python3
"""Verify a patch renumbering preserves textual dependencies.

The stack applies cumulatively, so two patches that touch a common file are
order-coupled: swapping them makes the second land on context the first was
meant to create. Everything else is free to move.

Reads the mapping table out of RENUMBER.md and asserts, for every pair of
patches sharing a file, that their relative order is unchanged.

Usage: ./check-order.py          # exits non-zero on any violation
"""
import collections
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROW = re.compile(r"^\|\s*`(\d{4})`\s*\|[^|]*\|[^|]*\|\s*`([^`]+)`\s*\|\s*`([^`]+)`\s*\|")


def load_mapping():
    """old filename -> (new number, new filename), parsed from RENUMBER.md."""
    path = os.path.join(HERE, "RENUMBER.md")
    mapping = {}
    for line in open(path, encoding="utf-8"):
        m = ROW.match(line)
        if m:
            num, old, new = m.groups()
            mapping[old] = (int(num), new)
    if not mapping:
        sys.exit(f"no mapping rows found in {path}")
    return mapping


def touched(filename):
    """Paths a patch writes to, normalising both +++ prefix conventions in use."""
    paths = set()
    with open(os.path.join(HERE, filename), errors="replace") as fh:
        for line in fh:
            if line.startswith("+++ "):
                p = line[4:].split("\t")[0].strip()
                p = re.sub(r"^b/", "", p)
                p = re.sub(r"^linux/", "", p)
                if p != "/dev/null":
                    paths.add(p)
    return paths


def main():
    on_disk = sorted(f for f in os.listdir(HERE) if f.endswith(".patch"))
    mapping = load_mapping()

    missing = set(on_disk) - set(mapping)
    extra = set(mapping) - set(on_disk)
    if missing or extra:
        for f in sorted(missing):
            print(f"  unmapped patch on disk: {f}")
        for f in sorted(extra):
            print(f"  mapping row with no patch: {f}")
        sys.exit("mapping does not match the directory")

    dupes = [n for n, c in collections.Counter(
        v[0] for v in mapping.values()).items() if c > 1]
    if dupes:
        sys.exit(f"duplicate new numbers: {sorted(dupes)}")

    old_index = {f: i for i, f in enumerate(on_disk)}
    by_file = collections.defaultdict(list)
    for f in on_disk:
        for p in touched(f):
            by_file[p].append(f)

    violations, pairs, coedited = [], 0, 0
    for path, files in by_file.items():
        if len(files) < 2:
            continue
        coedited += 1
        files.sort(key=lambda f: old_index[f])
        for i, a in enumerate(files):
            for b in files[i + 1:]:
                pairs += 1
                if mapping[a][0] > mapping[b][0]:
                    violations.append((path, a, b))

    print(f"patches: {len(on_disk)}   files touched: {len(by_file)}   "
          f"co-edited files: {coedited}")
    print(f"ordered pairs constrained: {pairs}")
    print(f"VIOLATIONS: {len(violations)}")
    for path, a, b in sorted(set(violations)):
        print(f"  {path}\n    {mapping[a][0]:>4} {a}\n    {mapping[b][0]:>4} {b}"
              "   <-- inverted")
    return 1 if violations else 0


if __name__ == "__main__":
    sys.exit(main())
