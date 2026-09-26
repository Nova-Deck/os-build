"""Installing a store game: where it goes, the record of it, and the download that outlives us.

THE DOWNLOAD IS A DETACHED UNIT, not our child. A download takes hours; the QAM closes, the
plugin reloads, and neither may stop it. systemd-run starts it as the store user under one fixed
unit name, so there is one install at a time and anything can find it by name:

  * KillSignal=SIGINT. legendary's clean stop is CTRL-C ("resume it using the same command"); a
    SIGTERM kills it mid-write. gogdl treats both alike. A stop is therefore the one interruption
    both CLIs are known to resume from — the resume is simply the same install again.
  * UMask=0022. Game files are not secrets; the 0077 the credential calls use would leave a game
    tree nothing but the user can read.
  * The log is opened by `sh` running AS the user. A StandardOutput=file: would have PID 1 open it
    as root, inside a directory the user owns — a planted symlink would aim that at any file.

OUR OWN RECORD (installs.json), because gogdl keeps none and legendary does not record an install
until it finishes. It holds each game's exact path and state, and it is written BEFORE the unit
starts: a crash between the two leaves a record that resumes, never a download nobody knows of.
It is written as the user (cli.write_as_user) and read with the same owner check as the tokens.

WHAT DECIDES "installed" is the CLI's own artifact, never an exit status: legendary's
installed.json, gogdl's build manifest — which gogdl writes only after a download completes.
"""
import json
import os
import re
import stat
import subprocess

from novadeck_stores import cli, locations, status
from novadeck_stores.paths import _clean_env

UNIT = "novadeck-store-install"
INFO_TIMEOUT = 120
# The shell opens the log as the user, then becomes the CLI. "$0" is the log, "$@" the CLI argv:
# positional, so no path or id is ever parsed as shell.
_LOG_THEN_EXEC = 'exec "$@" >"$0" 2>&1'


def install_argv(store, gid, root, p):
    if store == "epic":
        # --game-folder: the folder is ours (<root>/<app name>), not the one Epic's metadata names,
        # so the path is known before legendary runs and an interrupted install can be cleaned up.
        # -y answers every prompt, and skips prerequisite installers nothing here could run.
        return ["legendary", "install", gid, "--base-path", root, "--game-folder", gid,
                "-y", "--skip-dlcs"]
    if store == "gog":
        # gogdl appends the build's own folder name to --path.
        return ["gogdl", "--auth-config-path", p["NOVADECK_GOGDL_AUTH"], "download", gid,
                "--platform", "windows", "--path", root, "--skip-dlcs"]
    raise ValueError(f"unknown store {store!r}")


def info_argv(store, gid, p):
    if store == "epic":
        return ["legendary", "info", gid, "--json"]
    if store == "gog":
        return ["gogdl", "--auth-config-path", p["NOVADECK_GOGDL_AUTH"], "info", gid,
                "--platform", "windows"]
    raise ValueError(f"unknown store {store!r}")


def parse_info(store, gid, text):
    """{disk_size, folder} from a CLI's info output, or None.

    GOG sizes the common depots ("*") and each language separately; the download takes one
    language, so the largest is counted — a free-space check that is short by a language pack
    fails at 97%.
    """
    try:
        data = json.loads(text)
        if store == "epic":
            return {"disk_size": int(data["manifest"]["disk_size"]), "folder": gid}
        sizes = data["size"]
        langs = [int(v.get("disk_size", 0)) for k, v in sizes.items() if k != "*"]
        return {"disk_size": int(sizes["*"]["disk_size"]) + max(langs, default=0),
                "folder": data["folder_name"]}
    except (ValueError, KeyError, TypeError, AttributeError):
        return None


def safe_component(name):
    """Exactly one ordinary path component. A game's folder name comes from store metadata, and
    the path built from it is what an uninstall deletes."""
    # isprintable() also refuses NUL and control characters: a newline in an id would forge a
    # line of `systemctl show` output, where the unit's description names the running game.
    return (isinstance(name, str) and name not in ("", ".", "..")
            and "/" not in name and name.isprintable())


def log_path(p):
    return os.path.join(p["NOVADECK_STORE_HOME"], "install.log")


def unit_argv(store, gid, argv, log, p):
    return cli._as_user(
        p["NOVADECK_STORE_USER"], ["sh", "-c", _LOG_THEN_EXEC, log] + argv, None,
        cli._cli_setenv(p), umask="0022", unit=UNIT,
        description=f"novadeck-stores install {store}:{gid}", props=["KillSignal=SIGINT"],
    )


def unit_state():
    """{"ActiveState": ..., "Description": ...} of the install unit ("inactive" when absent)."""
    out = subprocess.run(
        ["systemctl", "show", f"{UNIT}.service", "-p", "ActiveState", "-p", "Description"],
        stdin=subprocess.DEVNULL, capture_output=True, text=True, env=_clean_env(),
        timeout=cli.CHECK_TIMEOUT,
    ).stdout
    props = dict(line.split("=", 1) for line in out.splitlines() if "=" in line)
    props.setdefault("ActiveState", "inactive")
    return props


def busy():
    return unit_state()["ActiveState"] in ("active", "activating", "deactivating", "reloading")


def read_records(p):
    data = status.read_user_json(p["NOVADECK_STORE_INSTALLS"], int(p["NOVADECK_STORE_UID"]))
    return data if isinstance(data, dict) else {}


def write_records(p, records):
    return cli.write_as_user(p, p["NOVADECK_STORE_INSTALLS"], json.dumps(records, indent=1)) == 0


_PROGRESS = re.compile(r"= Progress: (\d+(?:\.\d+)?)")
# Progress is logged about once a second for hours; the last line is all that is wanted.
_LOG_TAIL = 64 * 1024


def progress(text):
    """The last percentage either CLI logged ('= Progress: 12.34% ...' / '= Progress: 12.34 ...')."""
    found = _PROGRESS.findall(text)
    return float(found[-1]) if found else None


def read_log_tail(p):
    f = status.open_user_file(log_path(p), int(p["NOVADECK_STORE_UID"]))
    if f is None:
        return ""
    try:
        with f:
            f.seek(max(0, os.fstat(f.fileno()).st_size - _LOG_TAIL))
            return f.read().decode("utf-8", "replace")
    except OSError:
        return ""


def completed(store, gid, p):
    """Has the CLI itself recorded this game as done?"""
    uid = int(p["NOVADECK_STORE_UID"])
    if store == "epic":
        done = status.read_user_json(os.path.join(p["LEGENDARY_CONFIG_PATH"], "installed.json"), uid)
        return isinstance(done, dict) and gid in done
    manifest = status.open_user_file(
        os.path.join(p["GOGDL_CONFIG_PATH"], "heroic_gogdl", "manifests", gid), uid)
    if manifest is None:
        return False
    manifest.close()
    return True


def install_status(p):
    """{"installs": [{store, id, title, path, state[, percent]}]}.

    state: downloading (the unit is running this game), installed (the CLI's own artifact says
    so), or interrupted (anything else — stopped, failed, a reboot; resuming is install() again).

    READ-ONLY, derived from the artifacts on every call, never written back: so it needs no lock,
    and a panel polling for progress never waits behind a long uninstall.
    """
    unit = unit_state()
    running = (unit["ActiveState"] in ("active", "activating", "deactivating")
               and unit.get("Description", "").removeprefix("novadeck-stores install "))
    out = []
    for key, rec in read_records(p).items():
        item = dict(rec)
        if key == running:
            item["state"] = "downloading"
            pct = progress(read_log_tail(p))
            if pct is not None:
                item["percent"] = pct
        elif rec.get("state") == "installed" or completed(rec["store"], rec["id"], p):
            item["state"] = "installed"
        else:
            item["state"] = "interrupted"
        out.append(item)
    return {"installs": out}


def stop():
    """Stop the running install. KillSignal=SIGINT makes this the clean, resumable stop."""
    return subprocess.run(
        ["systemctl", "stop", f"{UNIT}.service"], stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=_clean_env(),
        timeout=cli.CHECK_TIMEOUT * 12,
    ).returncode


# Removing tens of GB from a card is slow; this bounds a wedged filesystem, not a normal delete.
DELETE_TIMEOUT = 900


def _in_game_root(path, store, vols):
    """Is path exactly <mounted volume>/Games/<store>/<one ordinary component>?"""
    parent, name = os.path.split(path)
    roots = {locations.game_root(v["path"], store) for v in vols}
    return safe_component(name) and parent in roots


def deletable(path, store, vols):
    """path if an uninstall may rm -rf it, else None.

    THIS IS THE WHOLE SAFETY OF AN UNINSTALL. The path comes from our record, which anything
    running as the user can edit, and was built from a folder name store metadata chose. So it is
    re-checked here, every time, against what it must be: one folder directly inside a game root
    of a volume that is mounted NOW, and a real directory, not a link. The rm itself runs as the
    user, so even a path swapped after this check reaches nothing the user could not delete.
    """
    if not _in_game_root(path, store, vols):
        return None
    # No link ANYWHERE along the path, not just at its end: a store root swapped for a link keeps
    # the string right and lands the delete in another tree.
    if os.path.realpath(path) != path:
        return None
    try:
        st = os.lstat(path)
    except OSError:
        return None
    return path if stat.S_ISDIR(st.st_mode) else None


def uninstall(store, gid, p, vols=None):
    """Remove a game's files, the CLI's own record of it, and ours. {"uninstalled": True} or
    {"error": ...}; on any refusal nothing is deleted and the record stays."""
    key = f"{store}:{gid}"
    records = read_records(p)
    rec = records.get(key)
    if rec is None:
        return {"error": "not installed by NovaDeck"}
    unit = unit_state()
    if busy() and unit.get("Description", "").removeprefix("novadeck-stores install ") == key:
        return {"error": "stop the install first"}
    vols = vols if vols is not None else locations.user_volumes(p["NOVADECK_STORE_USER"])
    path = rec.get("path", "")
    if not _in_game_root(path, store, vols):
        # Also the answer for a card that is not inserted: its games are not forgotten.
        return {"error": "the game's folder is not on an available drive"}

    if store == "epic" and completed(store, gid, p):
        # --keep-files: legendary only drops its record. Left to itself it deletes the path in
        # ITS installed.json, which the guard below never sees; the files go through the guard.
        cli._run(p, ["legendary", "uninstall", gid, "--keep-files", "--skip-uninstaller", "-y"],
                 cli.CHECK_TIMEOUT * 6)
    if os.path.lexists(path):
        if deletable(path, store, vols) is None:
            return {"error": "the game's folder is not a plain directory"}
        cli._run(p, ["rm", "-rf", "--one-file-system", "--", path], DELETE_TIMEOUT)
    if store == "epic":
        leftover = os.path.join(p["LEGENDARY_CONFIG_PATH"], "tmp", f"{gid}.resume")
    else:
        leftover = os.path.join(p["GOGDL_CONFIG_PATH"], "heroic_gogdl", "manifests", gid)
    cli._run(p, ["rm", "-f", "--", leftover], cli.CHECK_TIMEOUT)
    if os.path.lexists(path):
        return {"error": "the game's folder could not be removed"}

    del records[key]
    if not write_records(p, records):
        return {"error": "the game was removed, but its record could not be updated"}
    return {"uninstalled": True}


def install(store, gid, title, volume_path, p, vols=None):
    """Start (or resume) an install. {"started": True, "path": ...} or {"error": ...}."""
    if store not in locations.STORE_DIRS or not safe_component(gid):
        return {"error": "unknown game"}
    vols = vols if vols is not None else locations.user_volumes(p["NOVADECK_STORE_USER"])
    vol = next((v for v in vols if v["path"] == volume_path), None)
    if vol is None:
        return {"error": "that drive is not available"}
    if busy():
        return {"error": "another game is installing"}

    rc, out = cli.capture(p, info_argv(store, gid, p), INFO_TIMEOUT)
    info = parse_info(store, gid, out) if rc == 0 else None
    if info is None:
        return {"error": "cannot read the game's size from the store"}
    if not safe_component(info["folder"]):
        return {"error": "the store names an unusable folder for this game"}

    root = locations.game_root(vol["path"], store)
    path = os.path.join(root, info["folder"])
    key = f"{store}:{gid}"
    records = read_records(p)
    resuming = records.get(key, {}).get("state") == "installing" and records[key].get("path") == path
    # A resume already has part of the game on disk, which the free figure has paid for; the
    # CLIs' own checks stay as the backstop either way.
    if not resuming and info["disk_size"] > vol["free"]:
        return {"error": f"not enough free space: needs {info['disk_size']} bytes, "
                         f"{vol['free']} free"}

    records[key] = {"store": store, "id": gid, "title": title, "path": path,
                    "state": "installing"}
    if not write_records(p, records):
        return {"error": "cannot record the install"}
    unit = unit_argv(store, gid, install_argv(store, gid, root, p), log_path(p), p)
    if cli.start_detached(unit) != 0:
        return {"error": "the download did not start"}
    return {"started": True, "path": path}
