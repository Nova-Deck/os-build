"""The DOSBox command lines a GOG DOS game can run, for Boxtron (.claude/plans/boxtron-dos.plan.md).

GOG ships DOS games as Windows DOSBox. Their shortcut runs whatever GOG marks primary, which for
some titles is a Windows LAUNCHER choosing between several complete builds (Master of Magic:
Official Release and Community Patch). That is right under Proton, our default. When the user
picks Boxtron for the game instead, game-launch swaps the shortcut's exe for one of the game's
DOSBox command lines — Boxtron runs `dosbox.exe <args>` natively, and a launcher it cannot.

This module only DECIDES which command lines exist. It writes `<store home>/dos-targets.json` —
unsigned appid → {token, launcher_exe, variants, choice} — and
/usr/lib/novadeck/novadeck_dostarget.py (called by game-launch) does the swap. Keyed by appid
because that is all a launch knows about itself, like first-run.json. `choice` is the user's
remembered variant; a sync keeps it while that variant still exists.

A variant is {label, exe, args, cwd}:
  - the ROOT info's visible `game` tasks that run dosbox.exe, in file order;
  - the primary DOSBox task of each goggame-*.info ONE directory down (a nested build), with its
    paths relative to that directory.
Hidden tasks are skipped: GOG lists the launcher's own child processes that way, with no
arguments.

GOG's paths are matched case-insensitively with any separators (gog_paths.py says why), and a
workingDir that does not resolve — or is empty, or `.` — falls back to the exe's own directory,
which is where GOG's relative `-conf "..\\x.conf"` arguments are written from (Master of Magic's
root task proves the fallback is needed; nothing yet shows a `.` that means the install root
instead).

ROOT reads this tree, which the store user owns: info files go through status.open_user_file, and
gog_paths refuses `..` and symlinked components.
"""
import json
import os

from novadeck_stores import cli, installs, status
from novadeck_stores.gog_paths import resolve, split_windows_args  # noqa: F401 - re-exported

FILENAME = "dos-targets.json"
DOSBOX_EXE = "dosbox.exe"


def path(p):
    return os.path.join(p["NOVADECK_STORE_HOME"], FILENAME)


def _read_info(info_path, uid):
    f = status.open_user_file(info_path, uid)
    if f is None:
        return None
    try:
        with f:
            data = json.loads(f.read().decode("utf-8-sig", "replace"))
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def _dosbox_tasks(info):
    """The info's visible `game` tasks whose exe is dosbox.exe — the isPrimary one first, then
    file order. The first variant is what a launch runs when the user has chosen none."""
    tasks = info.get("playTasks")
    if not isinstance(tasks, list):
        return []
    found = [t for t in tasks
             if isinstance(t, dict) and t.get("category") == "game" and not t.get("isHidden")
             and isinstance(t.get("path"), str)
             and t["path"].replace("\\", "/").rsplit("/", 1)[-1].casefold() == DOSBOX_EXE]
    return sorted(found, key=lambda t: not t.get("isPrimary"))


def _variant(base, task, label):
    exe = resolve(base, task["path"])
    if exe is None:
        return None
    cwd = resolve(base, task.get("workingDir"), want_dir=True) or os.path.dirname(exe)
    args = task.get("arguments")
    return {"label": label, "exe": exe, "args": split_windows_args(args if isinstance(args, str) else ""),
            "cwd": cwd}


def _root_label(install, exe, task):
    """A root task's label: the top-level directory its exe lives in when that is a build of its
    own (`<build>/DOSBOX/DOSBox.exe`), else the task's name."""
    rel = os.path.relpath(exe, install).split(os.sep)
    return rel[0] if len(rel) >= 3 else (task.get("name") or os.path.basename(install))


def _nested_dirs(install):
    try:
        with os.scandir(install) as it:
            return sorted(e.path for e in it if e.is_dir(follow_symlinks=False))
    except OSError:
        return []


def _nested_infos(directory):
    try:
        with os.scandir(directory) as it:
            return sorted(e.path for e in it
                          if e.is_file(follow_symlinks=False)
                          and e.name.startswith("goggame-") and e.name.endswith(".info"))
    except OSError:
        return []


def gog_variants(install, gid, uid):
    """Every DOSBox command line a GOG install offers, root build first. [] for a game that is not
    DOSBox-based, or anything unreadable — never a raise."""
    found = []
    root = _read_info(os.path.join(install, f"goggame-{gid}.info"), uid)
    for task in _dosbox_tasks(root or {}):
        v = _variant(install, task, None)
        if v:
            found.append({**v, "label": _root_label(install, v["exe"], task)})
    nested = []
    for directory in _nested_dirs(install):
        for info_path in _nested_infos(directory):
            tasks = _dosbox_tasks(_read_info(info_path, uid) or {})
            v = _variant(directory, tasks[0], os.path.basename(directory)) if tasks else None
            if v:
                nested.append(v)
                break
    # One exe can serve several command lines (play vs. setup), so a duplicate is the same exe
    # with the same arguments — the same launch twice, not two choices.
    out, seen, seen_label = [], set(), set()
    for v in found + nested:
        key = (v["exe"], tuple(v["args"]))
        if key in seen:
            continue
        label, n = v["label"], 2
        while label in seen_label:
            label, n = f"{v['label']} ({n})", n + 1
        seen.add(key)
        seen_label.add(label)
        out.append({**v, "label": label})
    return out


def build(registry, records, uid):
    """Unsigned appid (str) → {token, launcher_exe, variants, choice: None} for every installed
    GOG Windows entry with at least one DOSBox variant."""
    out = {}
    for token, row in registry.items():
        store, _, gid = token.partition(":")
        rec = records.get(token) or {}
        if (store != "gog" or not isinstance(row, dict) or row.get("state") == "shelf"
                or row.get("platform") != "windows" or not isinstance(row.get("appid"), int)
                or not isinstance(row.get("exe"), str) or not rec.get("path")):
            continue
        try:
            variants = gog_variants(rec["path"], gid, uid)
        except (OSError, ValueError, TypeError):
            # gog_variants does not raise on anything seen so far; this is the backstop that
            # keeps one unexpected info file from costing every other game its row.
            continue
        if variants:
            out[str(row["appid"] & 0xFFFFFFFF)] = {
                "token": token, "launcher_exe": row["exe"], "variants": variants, "choice": None}
    return out


def merge_choices(built, current):
    """The built rows with each remembered `choice` carried over from `current` while its variant
    still exists. Returns new rows; neither input is changed."""
    current = current if isinstance(current, dict) else {}
    out = {}
    for key, row in built.items():
        prev = current.get(key)
        choice = prev.get("choice") if isinstance(prev, dict) else None
        labels = {v["label"] for v in row["variants"]}
        out[key] = {**row, "choice": choice if isinstance(choice, str) and choice in labels else None}
    return out


def sync(p, registry):
    """Rewrite dos-targets.json from the registry when it changed. True when the file is current."""
    uid = int(p["NOVADECK_STORE_UID"])
    current = status.read_user_json(path(p), uid)
    wanted = merge_choices(build(registry, installs.read_records(p), uid), current)
    if current == wanted or (current is None and not wanted):
        return True
    return cli.write_as_user(p, path(p), json.dumps(wanted, indent=1)) == 0
