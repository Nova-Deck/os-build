#!/usr/bin/env python3
"""Count boot-time resets from the gaps between journal boots.

A reset during kernel boot never reaches journald, so it leaves no boot of its own in the journal.
It shows up as a longer gap between one boot's last entry (its shutdown) and the next boot's first
entry. That gap covers only shutdown, firmware, GRUB and early kernel, so nothing in the session
(Steam, mark-good, a slow SD card) can stretch it. On the Pocket FIT a clean reboot is 18-22 s and
each reset adds about 10 s.

usage: ssh root@<device> journalctl --list-boots -o json | count-resets.py [--since BOOT_ID]
"""
import json
import statistics
import sys

RESET_COST_S = 10.0  # one more firmware + GRUB + early-kernel pass on the FIT
FLAG_OVER_S = 5.0    # excess over the median gap that counts as a reset


def main() -> int:
    args = sys.argv[1:]
    since = args[args.index("--since") + 1].replace("-", "") if "--since" in args else None

    boots = json.load(sys.stdin)
    if since:
        ids = [b["boot_id"] for b in boots]
        if since not in ids:
            sys.exit(f"boot {since} is not in the journal")
        boots = boots[ids.index(since):]
    if len(boots) < 3:
        sys.exit("need at least 3 boots to tell a normal gap from a reset")

    gaps = [(prev["boot_id"], nxt["boot_id"],
             (nxt["first_entry"] - prev["last_entry"]) / 1e6)
            for prev, nxt in zip(boots, boots[1:])]
    median = statistics.median(g for _, _, g in gaps)

    resets = 0
    for prev, nxt, gap in gaps:
        excess = gap - median
        n = max(1, round(excess / RESET_COST_S)) if excess > FLAG_OVER_S else 0
        resets += n
        flag = f"  <- {n} reset(s)" if n else ""
        print(f"{prev[:8]} -> {nxt[:8]}  gap {gap:6.1f} s{flag}")

    print(f"{len(gaps)} reboots, median gap {median:.1f} s, {resets} reset(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
