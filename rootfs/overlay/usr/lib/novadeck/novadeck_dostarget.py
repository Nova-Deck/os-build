"""Swap a store title's launcher for its DOSBox command line when the user picked Boxtron.

GOG ships DOS games as Windows DOSBox, and a title's shortcut runs whatever GOG marks primary —
for Master of Magic, a Windows launcher that chooses between two complete builds. That is right
under Proton, every store title's default. Boxtron (/usr/share/boxtron) is a compat tool the user
can pick instead, and it runs `dosbox.exe <args>` on native DOSBox — but it cannot run a launcher.

The novadeck-stores plugin records each GOG title's DOSBox command lines in
`<store home>/dos-targets.json` (appid → {launcher_exe, variants, choice}; its dos_targets.py says
how they are found). game-launch fronts every store launch and calls swap() just before it execs:
when Boxtron's entry point is in the argv Steam built AND the launch's exe is exactly the recorded
launcher, the launcher and everything after it are replaced with the chosen variant's exe and
arguments, and the launch moves into the variant's directory. Boxtron itself is stock.

Which variant: the row's remembered `choice`, else the first (the build GOG's root info lists).

Arguments after the launcher are DROPPED with it: they were addressed to the launcher, and the
variant carries GOG's full DOSBox command line. That holds when the recorded launcher is itself
DOSBox.exe too (a game whose primary task is DOSBox): the swap then supplies the GOG arguments the
shortcut lacks, and an extra argument a user typed into Launch Options does not survive it.

ANYTHING ELSE LEAVES THE ARGV EXACTLY AS STEAM BUILT IT — a Proton launch of the same game, a
title with no row, an argv of an unexpected shape, a file that does not parse, a variant whose
exe has gone. Like the rest of game-launch, this must never be what stops a game.
"""
import json
import os
import sys

BOXTRON_ENTRY = "/usr/share/boxtron/run-dosbox"
TARGETS_FILE = "dos-targets.json"
PROG = "game-launch"


def log(message):
    print(f"{PROG}: dos-target: {message}", file=sys.stderr, flush=True)


def _entry_index(argv):
    for i, arg in enumerate(argv):
        if isinstance(arg, str) and os.path.normpath(arg) == BOXTRON_ENTRY:
            return i
    return None


def _valid(variant):
    """The variant when it is well-formed and its exe and cwd exist — data from a file the user
    owns, about to be executed as the user."""
    if not isinstance(variant, dict):
        return None
    exe, args, cwd = variant.get("exe"), variant.get("args"), variant.get("cwd")
    if (not isinstance(exe, str) or not os.path.isabs(exe) or not os.path.isfile(exe)
            or not isinstance(args, list) or not all(isinstance(a, str) for a in args)
            or not isinstance(cwd, str) or not os.path.isabs(cwd) or not os.path.isdir(cwd)):
        return None
    return variant


def _pick(entry):
    variants = entry.get("variants")
    if not isinstance(variants, list) or not variants:
        return None
    choice = entry.get("choice")
    chosen = next((v for v in variants if isinstance(v, dict) and v.get("label") == choice), None)
    return _valid(chosen or variants[0])


def _read_table(home):
    try:
        table = json.loads((home / TARGETS_FILE).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return table if isinstance(table, dict) else None


def swap(argv, appid, home=None):
    """(argv, cwd): the argv to exec and the directory to run it in. Unchanged (argv, None) unless
    this is a Boxtron launch of a title with a recorded DOSBox target."""
    unchanged = (argv, None)
    entry_at = _entry_index(argv)
    if entry_at is None or not appid:
        return unchanged
    if home is None:
        import novadeck_firstrun  # the one declaration of where the store tree lives
        home = novadeck_firstrun.store_home()
        if home is None:
            return unchanged
    table = _read_table(home)
    entry = table.get(str(appid)) if table else None
    if not isinstance(entry, dict) or not isinstance(entry.get("launcher_exe"), str):
        return unchanged
    exe_at = next((j for j in range(entry_at + 1, len(argv)) if argv[j] == entry["launcher_exe"]), None)
    if exe_at is None:
        return unchanged
    variant = _pick(entry)
    if variant is None:
        log(f"{entry.get('token')}: no usable DOSBox variant, launching as Steam built it")
        return unchanged
    log(f"{entry.get('token')}: running {variant.get('label')!r} instead of "
        f"{os.path.basename(entry['launcher_exe'])}")
    return argv[:exe_at] + [variant["exe"], *variant["args"]], variant["cwd"]
