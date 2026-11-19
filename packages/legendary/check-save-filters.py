"""Build-time check of 0002-save-filters-match-in-any-case.patch, run by the PKGBUILD's build().

A game's CloudIncludeList / CloudExcludeList must select the same files for an upload and for a
download's clean-up, in ANY case, as Epic's Windows client does: on Linux, legendary 0.20.43's
fnmatch was case-sensitive, so Fallout's SAVE.DAT never reached the cloud (HW 2026-11-19), and the
download read the lists unstripped, which only by accident kept it from deleting MASTER.DAT.
This runs legendary's real upload_save() and download_saves() against a copy of Fallout's Epic
install, with only the network stubbed, so it runs offline in the build container.

    python check-save-filters.py <patched legendary source dir>

Exits non-zero on the first failure. Run from build() rather than check() because the overlay
build runs makepkg with --nocheck.
"""
import json
import logging
import os
import sys
import tempfile
import types

CONFIG = tempfile.mkdtemp()
os.environ["LEGENDARY_CONFIG_PATH"] = CONFIG
sys.path.insert(0, sys.argv[1])
from legendary.core import LegendaryCore  # noqa: E402  (the path and environment above first)

failures = []
# The account's real metadata (HW 2026-11-19).
GAMES = {
    "Fallout": ("*.sav, *.dat", "critter.dat, master.dat"),
    "Fallout2": ("*.sav, *.dat", "critter.dat, master.dat, f2_res.dat, patch000.dat, worldmap.dat"),
    "Trailing": ("*.sav", "LocalData/,"),  # an empty item must not select everything
}
GAME_DATA = [f"Fallout 1 {lang}/{name}" for lang in ("English", "French", "German", "Spanish")
             for name in ("MASTER.DAT", "CRITTER.DAT")] + [
    "Fallout 1 English/falloutwHR.exe", "Fallout 1 English/fallout.cfg", "Launcher.exe"]
SAVES = ["Fallout 1 English/DATA/SAVEGAME/SLOT01/SAVE.DAT",   # the real save, uppercase
         "Fallout 1 English/DATA/SAVEGAME/SLOT01/V13ENT.SAV",
         "Fallout 1 English/DATA/SAVEGAME/SLOT01/AUTOMAP.SAV",
         "Fallout 1 English/DATA/SAVEGAME/SLOT02/save.dat"]  # and one in lowercase


def check(cond, message):
    print(f"  {'ok  ' if cond else 'FAIL'} {message}")
    if not cond:
        failures.append(message)


class Packed(logging.Handler):
    """The files an upload packs, from legendary's own 'Processing file' debug lines."""
    def __init__(self):
        super().__init__(logging.DEBUG)
        self.files = []

    def emit(self, record):
        msg = record.getMessage()
        if msg.startswith('Processing file "'):
            self.files.append(msg[len('Processing file "'):-1])


def install():
    root = tempfile.mkdtemp(prefix="fallout.")
    for rel in GAME_DATA + SAVES + ["LocalData/cache.sav"]:
        path = os.path.join(root, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(rel)
    return root


def present(root):
    return {os.path.relpath(os.path.join(d, n), root).replace(os.sep, "/")
            for d, _, names in os.walk(root) for n in names}


def core():
    with open(os.path.join(CONFIG, "config.ini"), "w") as f:
        f.write(f"[Legendary]\ndisable_auto_aliasing = true\ninstall_dir = {CONFIG}/games\n")
    os.makedirs(os.path.join(CONFIG, "metadata"), exist_ok=True)
    for app, (include, exclude) in GAMES.items():
        with open(os.path.join(CONFIG, "metadata", f"{app}.json"), "w") as f:
            json.dump({"app_name": app, "app_title": app, "metadata": {"customAttributes": {
                "CloudSaveFolder": {"type": "STRING", "value": "{InstallDir}/"},
                "CloudIncludeList": {"type": "STRING", "value": include},
                "CloudExcludeList": {"type": "STRING", "value": exclude}}}}, f)
    c = LegendaryCore()
    c.egs.user = {"account_id": "0123456789abcdef0123456789abcdef"}
    c.egs.create_game_cloud_saves = lambda app, names: {"files": {}}
    c.egs.get_user_cloud_saves = lambda app_name="", manifests=False, filenames=None: {"files": {
        f"acct/x/{app_name}/y/2026.11.19-16.00.00.manifest": {"readLink": "https://example.invalid/m"}}}
    # The manifest fetch fails, so nothing is written: what remains is what the clean-up kept.
    c.egs.unauth_session = types.SimpleNamespace(
        get=lambda url, **_: types.SimpleNamespace(status_code=404, content=b""))
    return c


def upload(c, app, root):
    handler = Packed()
    logger = logging.getLogger()
    logger.addHandler(handler)
    logger.setLevel(logging.DEBUG)
    try:
        c.upload_save(app, root)
    finally:
        logger.removeHandler(handler)
    return set(handler.files)


c = core()
for app in ("Fallout", "Fallout2"):
    print(f"== {app}: include {GAMES[app][0]!r}, exclude {GAMES[app][1]!r}")
    root = install()
    packed = upload(c, app, root)
    check(set(SAVES) <= packed,
          f"the upload packs every save, the uppercase SAVE.DAT, V13ENT.SAV and AUTOMAP.SAV too ({sorted(packed)})")
    check(not packed & set(GAME_DATA), "...and no game data: MASTER.DAT and CRITTER.DAT stay out in any case")
    c.download_saves(app, manifest_name="2026.11.19-16.00.00.manifest", save_dir=root, clean_dir=True)
    left = present(root)
    check(not left & set(SAVES), f"a download's clean-up removes every save, in any case ({sorted(left & set(SAVES))})")
    check(set(GAME_DATA) <= left,
          f"...and NEVER the game's data: every MASTER.DAT and CRITTER.DAT is still there "
          f"({sorted(set(GAME_DATA) - left)} missing)")

print("== an empty item in a list (\"LocalData/,\")")
root = install()
packed = upload(c, "Trailing", root)
check("Fallout 1 English/DATA/SAVEGAME/SLOT01/V13ENT.SAV" in packed and "LocalData/cache.sav" not in packed,
      f"is dropped: it does not exclude everything, and LocalData/ is still excluded ({sorted(packed)})")

if failures:
    sys.exit(f"check-save-filters: {len(failures)} failed")
print("check-save-filters: all passed")
