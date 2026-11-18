"""Build-time check of 0001-save-sync-dry-run.patch, run by the PKGBUILD's build() in the patched tree.

`gogdl save-sync --dry-run` must classify exactly as a real sync does and change NOTHING: no
upload, download or delete, not even the local directory a real sync creates. The network calls
are stubbed, so this runs offline in the build container.

    python check-dry-run.py <patched gogdl source dir>

Exits non-zero on the first failure. Run from build() rather than check() because the overlay
build runs makepkg with --nocheck.
"""
import contextlib
import io
import json
import os
import sys
import tempfile
import types

sys.path.insert(0, sys.argv[1])
from gogdl import saves  # noqa: E402  (the path above first)

DELETED = "aadd86936a80ee8a369579c3926f1b3c"  # gogdl's md5 of a cloud file marked deleted
failures = []


def check(cond, message):
    print(f"  {'ok  ' if cond else 'FAIL'} {message}")
    if not cond:
        failures.append(message)


def manager(cloud):
    m = saves.CloudStorageManager(api_handler=None, authorization_manager=None)
    m.get_auth_ids = lambda: ("client", "secret")
    m.get_auth_token = lambda: None
    m.get_cloud_files_list = lambda: [
        saves.SyncFile(name, os.path.join(m.sync_path, name), md5=md5, update_time=when)
        for name, md5, when in cloud]

    def forbidden(*_a, **_k):
        raise AssertionError("a dry run touched a file")
    m.upload_file = m.download_file = m.delete_file = forbidden
    return m


def dry_run(path, cloud, ts):
    args = types.SimpleNamespace(path=path, dirname="__default", timestamp=str(ts), id="1",
                                 platform="windows", prefered_action=None, dry_run=True)
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        manager(cloud).sync(args, [])
    return json.loads(out.getvalue())


def local_dir(files):
    d = tempfile.mkdtemp()
    for name, mtime in files.items():
        p = os.path.join(d, name)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w") as f:
            f.write(name)
        os.utime(p, (mtime, mtime))
    return d


def snapshot(d):
    return sorted((os.path.relpath(os.path.join(r, n), d), os.stat(os.path.join(r, n)).st_mtime)
                  for r, _, names in os.walk(d) for n in names)


OLD, SYNCED, NEW = 1_600_000_000, 1_700_000_000, 1_800_000_000
iso = lambda t: __import__("datetime").datetime.fromtimestamp(t, __import__("datetime").timezone.utc).isoformat()

d = local_dir({"slot1.sav": NEW, "sub/slot2.sav": OLD})
before = snapshot(d)
r = dry_run(d, [("slot1.sav", "x", iso(OLD)), ("sub/slot2.sav", "y", iso(OLD))], SYNCED)
check(r["action"] == "upload" and r["updated_local"] == ["slot1.sav"],
      f"only local changed since the last sync: upload, naming that file ({r})")
check(r["local"] == {"files": 2, "newest": NEW} and r["cloud"]["files"] == 2,
      f"each side's file count and newest update time ({r['local']}, {r['cloud']})")
check(snapshot(d) == before, "the local files are untouched")

r = dry_run(d, [("slot1.sav", "x", iso(OLD)), ("sub/slot2.sav", "y", iso(NEW))], SYNCED)
check(r["action"] == "conflict" and r["updated_cloud"] == ["sub/slot2.sav"],
      f"both sides changed: conflict, the classification a real sync only logs ({r})")

r = dry_run(d, [("slot1.sav", "x", iso(OLD))], NEW + 1)
check(r["action"] == "none" and r["not_existing_remotely"] == ["sub/slot2.sav"],
      f"nothing newer than the timestamp: none, with the file a download would delete ({r})")

r = dry_run(d, [("slot1.sav", "x", iso(NEW)), ("gone.sav", DELETED, iso(NEW))], SYNCED)
check(r["cloud"]["files"] == 1 and "gone.sav" not in r["updated_cloud"],
      f"a cloud file marked deleted is not counted or downloaded ({r})")

r = dry_run(d, [], SYNCED)
check(r["action"] == "upload" and r["updated_local"] == ["slot1.sav", "sub/slot2.sav"],
      f"an empty cloud: upload everything, the rule a real sync applies before any flag ({r})")

missing = os.path.join(tempfile.mkdtemp(), "not-yet")
r = dry_run(missing, [("slot1.sav", "x", iso(OLD))], SYNCED)
check(r["action"] == "download" and r["local"] == {"files": 0, "newest": None},
      f"no local dir: download everything ({r})")
check(not os.path.exists(missing), "and the missing dir is NOT created, as a real sync would")

r = dry_run(missing, [], SYNCED)
check(r["action"] == "none" and r["cloud"] == {"files": 0, "newest": None}, f"both empty: none ({r})")

if failures:
    sys.exit(f"check-dry-run: {len(failures)} failed")
print("check-dry-run: all passed")
