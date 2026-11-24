"""How many guests are streaming.

Sunshine's API does not say, and its log has no line that names the guest who left. Its threads do
count: one named session::video per session, for as long as it streams.
"""
import os

THREAD = "session::video"


def count(pid, proc="/proc"):
    if pid <= 0:
        return 0
    total = 0
    try:
        threads = os.listdir(f"{proc}/{pid}/task")
    except OSError:
        return 0
    for tid in threads:
        try:
            with open(f"{proc}/{pid}/task/{tid}/comm", encoding="utf-8", errors="replace") as f:
                total += f.read().strip() == THREAD
        except OSError:  # the thread ended between the two reads
            continue
    return total
