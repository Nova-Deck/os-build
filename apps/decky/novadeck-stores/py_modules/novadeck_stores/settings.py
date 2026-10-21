"""The panel's one preference: which drive a tile press installs to.

A tile press has no drive picker, so the choice is made once in the Quick Access panel and kept
in <store home>/settings.json — the user's file, written as the user and read with the same owner
check as every other file root reads there. Absent or unreadable means "no preference", which
installs to the home (locations.default_volume): a bad file must never block an install.
"""
import json
import os

from novadeck_stores import cli, status


def path(p):
    return os.path.join(p["NOVADECK_STORE_HOME"], "settings.json")


def read(p):
    data = status.read_user_json(path(p), int(p["NOVADECK_STORE_UID"]))
    return data if isinstance(data, dict) else {}


def install_drive(p):
    drive = read(p).get("install_drive")
    return drive if isinstance(drive, str) else None


def set_install_drive(p, drive):
    return cli.write_as_user(p, path(p), json.dumps({**read(p), "install_drive": drive}, indent=1)) == 0
