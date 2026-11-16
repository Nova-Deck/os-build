#!/usr/bin/env python3
"""Check the locks' snapshot rows against the pinned snapshot's repo databases.

    python3 -I build/snapshot-drift.py --db core.db --db extra.db rootfs/manifest.lock installer/manifest.lock

WHY. build/snapshot.pin names a FROZEN revision, and everything downstream assumes frozen means
the bytes never move. That assumption already failed once: on 2026-11-06 Valve republished
mash-20260528.1.pvt's system.rootfs.zst in place, and regenerated its repo dbs the same day.
Nothing noticed for ten days, because every consumer is cached. lib-pins.sh returns early when
the builder image exists, CI restores the tarball from a cache keyed on build/builder.pin, and
rootfs/fetchlock.sh only meets a moved package file on a cold pacman cache. upstream-watch.yml's
deckard-drift job runs this daily, against a fresh fetch, so a moved package shows up as an issue
rather than as a release build that fails an hour in.

Every `snapshot` and `stripped` row is checked: both classes are fetched from the snapshot and
verified by the bytes (the lock header says so). `novadeck` rows pin sources and `prebuilt` rows
pin their own URLs, so the snapshot has nothing to say about either.

Exit 0: every checked row matches. Exit 1: drift, one line per finding on stdout. Exit 2: nothing
to compare (an unreadable db, a db with no packages, locks with no snapshot rows). A watcher that
cannot see must go red, not report a clean pass.
"""
import argparse
import sys
import tarfile
from collections.abc import Iterator

CHECKED = ("snapshot", "stripped")

Row = tuple[str, str, str]  # name, version, sha256


def read_db(path: str) -> dict[str, tuple[str, str]]:
    """{name: (version, sha256)} from a pacman sync db (a tarball of <pkg>/desc files)."""
    pkgs = {}
    with tarfile.open(path) as tar:
        for member in tar:
            if not member.isfile() or not member.name.endswith("/desc"):
                continue
            fields = {}
            key = None
            for line in tar.extractfile(member).read().decode().splitlines():
                if line.startswith("%") and line.endswith("%"):
                    key = line.strip("%")
                elif line and key and key not in fields:
                    fields[key] = line
            name = fields.get("NAME")
            if name:
                pkgs[name] = (fields.get("VERSION", ""), fields.get("SHA256SUM", ""))
    return pkgs


def read_lock(path: str) -> list[Row]:
    """[(name, version, sha256)] for the rows the snapshot vouches for."""
    rows = []
    with open(path) as f:
        for line in f:
            if line.startswith("#") or not line.strip():
                continue
            fields = line.split()
            if len(fields) != 5:
                raise ValueError(f"{path}: malformed row: {line.rstrip()}")
            name, version, _arch, source, sha = fields
            if source in CHECKED:
                rows.append((name, version, sha))
    return rows


def drift(snapshot: dict[str, tuple[str, str]], lock_name: str, rows: list[Row]) -> Iterator[str]:
    """One finding per row whose package is gone, re-versioned, or re-hashed."""
    for name, version, sha in rows:
        if name not in snapshot:
            yield f"GONE {lock_name} {name} {version}: not in the snapshot dbs"
            continue
        snap_version, snap_sha = snapshot[name]
        if snap_version != version:
            yield f"VERSION {lock_name} {name}: lock={version} snapshot={snap_version}"
        elif snap_sha != sha:
            yield f"SHA256 {lock_name} {name} {version}: lock={sha} snapshot={snap_sha}"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--db", action="append", required=True, help="a sync db (repeatable)")
    ap.add_argument("locks", nargs="+", help="manifest.lock files")
    args = ap.parse_args()

    snapshot = {}
    try:
        for db in args.db:
            pkgs = read_db(db)
            if not pkgs:
                print(f"no packages in {db}", file=sys.stderr)
                return 2
            snapshot.update(pkgs)
        locks = [(lock, read_lock(lock)) for lock in args.locks]
    except (OSError, tarfile.TarError, ValueError, UnicodeDecodeError) as e:
        print(f"cannot read input: {e}", file=sys.stderr)
        return 2

    checked = sum(len(rows) for _, rows in locks)
    if checked == 0:
        print("no snapshot/stripped rows in any lock", file=sys.stderr)
        return 2

    findings = [f for lock, rows in locks for f in drift(snapshot, lock, rows)]
    for finding in findings:
        print(finding)
    print(f"checked {checked} rows against {len(snapshot)} snapshot packages: "
          f"{len(findings)} drifted", file=sys.stderr)
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
