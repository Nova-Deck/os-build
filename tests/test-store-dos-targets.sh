#!/usr/bin/env bash
# Offline checks for the GOG DOS targets the store plugin records for Boxtron
# (.claude/plans/boxtron-dos.plan.md, phase 1 step 3).
#
#   tests/test-store-dos-targets.sh
#
# WHY THIS FILE EXISTS. A GOG DOS game's shortcut runs whatever GOG marks primary — for Master of
# Magic, a Windows launcher that chooses between two complete builds. When the user picks Boxtron
# for it, game-launch swaps that target for one of the game's DOSBox command lines, and THIS module
# is what says which command lines exist. GOG's metadata is messy in ways that only show on a real
# install, so the fixtures below are Master of Magic's two goggame info files VERBATIM, read off a
# Pocket FIT on 2026-11-17:
#   - the root info's visible DOSBox task names workingDir "DOSBOX", which does NOT exist relative
#     to the install root (the right cwd is the exe's own dir);
#   - the nested Community Patch info spells its exe "DOSBOX\dosbox.exe" (backslash, lower case)
#     while the file on disk is DOSBox.exe;
#   - two `isHidden` "launcher process" tasks point at the same exes with NO arguments.
#
# WHAT IT CANNOT PROVE: that Boxtron accepts the command line, or that DOSBox runs the game. Those
# are the hardware gate.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STORES_PY="$ROOT/apps/decky/novadeck-stores/py_modules"
PASS=0 FAIL=0

out="$(python3 - "$STORES_PY" <<'PY'
import json, os, pathlib, sys, tempfile
sys.path.insert(0, sys.argv[1])

def ok(m): print(f"  ok   {m}")
def bad(m): print(f"  FAIL {m}")
def check(cond, m): (ok if cond else bad)(m)

from novadeck_stores import dos_targets

# ---------------------------------------------------------------------------------------------
print("== Windows command-line splitting (CommandLineToArgvW rules)")
S = dos_targets.split_windows_args
check(S('-conf "..\\dosboxMOM.conf" -conf "..\\dosboxMOM_single.conf" -noconsole -c "exit"')
      == ["-conf", "..\\dosboxMOM.conf", "-conf", "..\\dosboxMOM_single.conf", "-noconsole", "-c", "exit"],
      "MoM's Community Patch arguments split, backslashes kept literal")
check(S('-conf "../dosboxMOM.conf" -c "exit"') == ["-conf", "../dosboxMOM.conf", "-c", "exit"],
      "forward-slash paths split the same way")
check(S('"a b" c') == ["a b", "c"], "a quoted token keeps its space")
check(S('  a   b  ') == ["a", "b"], "runs of whitespace separate, none at the ends")
check(S('') == [] and S(None) == [], "no arguments → an empty list")
check(S('a\\\\"b c"') == ['a\\b c'], "2n backslashes before a quote → n backslashes, quote toggles")
check(S('a\\"b') == ['a"b'], "2n+1 backslashes before a quote → a literal quote")
check(S('C:\\GAMES\\X') == ['C:\\GAMES\\X'], "backslashes not before a quote are literal")
check(S('"a ""b" c') == ['a "b', 'c'], '"" inside a quoted section is a literal quote')

# ---------------------------------------------------------------------------------------------
print("== Master of Magic, as installed on the Pocket FIT")
uid = os.getuid()
tmp = pathlib.Path(tempfile.mkdtemp(prefix="dos-targets."))
mom = tmp / "Games" / "GOG" / "Master of Magic"
OFF = mom / "Master of Magic Official Release"
CP = mom / "Master of Magic Community Patch"
for d in (OFF, CP):
    (d / "DOSBOX").mkdir(parents=True)
    (d / "DOSBOX" / "DOSBox.exe").write_bytes(b"MZ")
    (d / "dosboxMOM.conf").write_text("[sdl]\n")
    (d / "dosboxMOM_single.conf").write_text("[autoexec]\nmount C \"..\"\n")
(mom / "Launcher.exe").write_bytes(b"MZ")

ROOT_INFO = {
    "clientId": "49453893649235498", "gameId": "1207658855", "language": "English",
    "languages": ["en-US"], "name": "Master of Magic Classic",
    "playTasks": [
        {"category": "launcher", "isPrimary": True, "languages": ["en-US"],
         "name": "Master of Magic", "path": "Launcher.exe", "type": "FileTask"},
        {"category": "game", "isHidden": True, "languages": ["en-US"],
         "name": "Master of Magic - launcher process Master of Magic Official Release/DOSBOX/DOSBox_exe",
         "path": "Master of Magic Official Release/DOSBOX/DOSBox.exe", "type": "FileTask"},
        {"category": "game", "isHidden": True, "languages": ["en-US"],
         "name": "Master of Magic - launcher process Master of Magic Community Patch/DOSBOX/DOSBox_exe",
         "path": "Master of Magic Community Patch/DOSBOX/DOSBox.exe", "type": "FileTask"},
        {"arguments": "-conf \"../dosboxMOM.conf\" -conf \"../dosboxMOM_single.conf\" -noconsole -c \"exit\"",
         "category": "game", "languages": ["en-US"], "name": "Master of Magic",
         "path": "Master of Magic Official Release/DOSBOX/DOSBox.exe", "type": "FileTask",
         "workingDir": "DOSBOX"},
        {"category": "document", "languages": ["en-US"], "name": "Manual",
         "path": "Master of Magic Official Release/Manuals/manual.pdf", "type": "FileTask"},
        {"category": "document", "languages": ["en-US"], "name": "Spellbook",
         "path": "Master of Magic Official Release/Manuals/spellbook.pdf", "type": "FileTask"},
        {"arguments": "1207658855", "category": "tool", "languages": ["en-US"],
         "name": "Graphic Mode Setup", "path": "Master of Magic Official Release/DOSBOX/GOGDOSConfig.exe",
         "type": "FileTask", "workingDir": "DOSBOX"},
    ],
    "rootGameId": "1207658855", "version": 1,
}
CP_INFO = {
    "buildId": "52095497401376771", "clientId": "49453893649235498", "gameId": "1207658855",
    "language": "English", "languages": ["en-US"], "name": "Master of Magic",
    "playTasks": [
        {"arguments": "-conf \"..\\dosboxMOM.conf\" -conf \"..\\dosboxMOM_single.conf\" -noconsole -c \"exit\"",
         "category": "game", "isPrimary": True, "languages": ["*"], "name": "Master of Magic",
         "path": "DOSBOX\\dosbox.exe", "type": "FileTask", "workingDir": "DOSBOX"},
        {"arguments": "1207658855", "category": "tool", "languages": ["*"], "name": "Graphic Mode Setup",
         "path": "DOSBOX\\GOGDOSConfig.exe", "type": "FileTask", "workingDir": "DOSBOX"},
        {"category": "document", "languages": ["*"], "link": "http://www.gog.com/support/master_of_magic",
         "name": "Support", "type": "URLTask"},
        {"category": "document", "languages": ["*"], "name": "Manual", "path": "Manual.pdf", "type": "FileTask"},
        {"category": "document", "languages": ["*"], "name": "Spellbook", "path": "Spellbook.pdf", "type": "FileTask"},
    ],
    "rootGameId": "1207658855", "version": 1,
}
(mom / "goggame-1207658855.info").write_text(json.dumps(ROOT_INFO, indent=4))
(CP / "goggame-1207658855.info").write_text(json.dumps(CP_INFO, indent=4))

v = dos_targets.gog_variants(str(mom), "1207658855", uid)
labels = [x["label"] for x in v]
check(labels == ["Master of Magic Official Release", "Master of Magic Community Patch"],
      f"two variants, the root's visible task first, labelled by their directory ({labels})")
off = v[0] if v else {}
cp = v[1] if len(v) > 1 else {}
check(off.get("exe") == str(OFF / "DOSBOX" / "DOSBox.exe"), f"Official exe resolved ({off.get('exe')})")
check(off.get("args") == ["-conf", "../dosboxMOM.conf", "-conf", "../dosboxMOM_single.conf", "-noconsole", "-c", "exit"],
      "Official args carried, split into tokens")
check(off.get("cwd") == str(OFF / "DOSBOX"),
      f"root workingDir 'DOSBOX' does not exist under the install root → the exe's own dir ({off.get('cwd')})")
check(cp.get("exe") == str(CP / "DOSBOX" / "DOSBox.exe"),
      f"nested 'DOSBOX\\dosbox.exe' resolves to DOSBox.exe case-insensitively ({cp.get('exe')})")
check(cp.get("cwd") == str(CP / "DOSBOX"), "nested workingDir resolves against the nested info's dir")
check(cp.get("args", [None])[1:2] == ["..\\dosboxMOM.conf"], "nested args keep their Windows backslashes")
check(all(x.get("args") for x in v), "the hidden no-argument 'launcher process' tasks are not variants")

# ---------------------------------------------------------------------------------------------
print("== other shapes")
plain = tmp / "Games" / "GOG" / "Witcher"
(plain / "bin").mkdir(parents=True)
(plain / "bin" / "witcher.exe").write_bytes(b"MZ")
(plain / "goggame-1.info").write_text(json.dumps({"playTasks": [
    {"category": "game", "isPrimary": True, "path": "bin\\witcher.exe", "type": "FileTask"}]}))
check(dos_targets.gog_variants(str(plain), "1", uid) == [], "a non-DOS Windows game has no variants")

single = tmp / "Games" / "GOG" / "Doom"
(single / "DOSBOX").mkdir(parents=True)
(single / "DOSBOX" / "DOSBox.exe").write_bytes(b"MZ")
(single / "goggame-2.info").write_text(json.dumps({"playTasks": [
    {"arguments": "-conf \"..\\dosbox_doom.conf\" -noconsole -c \"exit\"", "category": "game",
     "isPrimary": True, "name": "DOOM", "path": "DOSBOX\\dosbox.exe", "workingDir": "DOSBOX"}]}))
sv = dos_targets.gog_variants(str(single), "2", uid)
check(len(sv) == 1 and sv[0]["exe"] == str(single / "DOSBOX" / "DOSBox.exe") and sv[0]["cwd"] == str(single / "DOSBOX"),
      f"a game whose primary task IS DOSBox has exactly one variant ({sv})")
check(sv and sv[0]["label"] == "DOOM", "a variant at the install root is labelled by its task name")

gone = tmp / "Games" / "GOG" / "Gone"
gone.mkdir(parents=True)
(gone / "goggame-3.info").write_text(json.dumps({"playTasks": [
    {"category": "game", "isPrimary": True, "path": "DOSBOX\\dosbox.exe", "arguments": "-c exit"}]}))
check(dos_targets.gog_variants(str(gone), "3", uid) == [], "a DOSBox task whose exe is missing is dropped")

escape = tmp / "Games" / "GOG" / "Escape"
escape.mkdir(parents=True)
(tmp / "Games" / "GOG" / "DOSBOX").mkdir(exist_ok=True)
(tmp / "Games" / "GOG" / "DOSBOX" / "dosbox.exe").write_bytes(b"MZ")
(escape / "goggame-4.info").write_text(json.dumps({"playTasks": [
    {"category": "game", "isPrimary": True, "path": "..\\DOSBOX\\dosbox.exe", "arguments": "-c exit"}]}))
check(dos_targets.gog_variants(str(escape), "4", uid) == [], "a path that climbs out of the install is refused")

link = tmp / "Games" / "GOG" / "Link"
link.mkdir(parents=True)
(link / "DOSBOX").symlink_to(tmp / "Games" / "GOG" / "DOSBOX")
(link / "goggame-5.info").write_text(json.dumps({"playTasks": [
    {"category": "game", "isPrimary": True, "path": "DOSBOX\\dosbox.exe", "arguments": "-c exit"}]}))
check(dos_targets.gog_variants(str(link), "5", uid) == [], "a symlinked path component is refused")

check(dos_targets.gog_variants(str(tmp / "nowhere"), "6", uid) == [], "no install dir → no variants, no raise")

multi = tmp / "Games" / "GOG" / "Multi"
(multi / "DOSBOX").mkdir(parents=True)
(multi / "DOSBOX" / "DOSBox.exe").write_bytes(b"MZ")
(multi / "goggame-8.info").write_text(json.dumps({"playTasks": [
    {"category": "game", "name": "Setup", "path": "DOSBOX\\DOSBox.exe", "arguments": "-c setup.exe"},
    {"category": "game", "isPrimary": True, "name": "Play", "path": "DOSBOX\\DOSBox.exe", "arguments": "-c game.exe"}]}))
mv = dos_targets.gog_variants(str(multi), "8", uid)
check([x["args"] for x in mv] == [["-c", "game.exe"], ["-c", "setup.exe"]],
      f"one exe, two command lines → two variants, the isPrimary one FIRST whatever the file order ({mv})")
check([x["label"] for x in mv] == ["Play", "Setup"], "each labelled by its task name")

nul = tmp / "Games" / "GOG" / "Nul"
nul.mkdir(parents=True)
(nul / "goggame-9.info").write_text(json.dumps({"playTasks": [
    {"category": "game", "isPrimary": True, "path": "DOS\u0000BOX\\dosbox.exe", "arguments": "-c exit"}]}))
try:
    check(dos_targets.gog_variants(str(nul), "9", uid) == [], "a NUL in a GOG path → no variant, no raise")
except Exception as exc:
    bad(f"a NUL in a GOG path raised {type(exc).__name__}")

bom = tmp / "Games" / "GOG" / "Bom"
(bom / "DOSBOX").mkdir(parents=True)
(bom / "DOSBOX" / "DOSBox.exe").write_bytes(b"MZ")
(bom / "goggame-7.info").write_bytes(b"\xef\xbb\xbf" + json.dumps({"playTasks": [
    {"category": "game", "isPrimary": True, "name": "X", "path": "DOSBOX\\DOSBox.exe", "arguments": "-c exit"}]}).encode())
check(len(dos_targets.gog_variants(str(bom), "7", uid)) == 1, "an info file with a UTF-8 BOM still parses")

# ---------------------------------------------------------------------------------------------
print("== build + choice preservation")
registry = {
    "gog:1207658855": {"appid": -123456, "title": "Master of Magic", "exe": str(mom / "Launcher.exe"),
                       "platform": "windows"},
    "gog:1": {"appid": 222, "exe": str(plain / "bin" / "witcher.exe"), "platform": "windows"},
    "gog:2": {"appid": 333, "state": "shelf"},
    "epic:x": {"appid": 444, "exe": "/x.exe", "platform": "windows"},
}
records = {"gog:1207658855": {"path": str(mom), "platform": "windows"},
           "gog:1": {"path": str(plain), "platform": "windows"},
           "gog:2": {"path": str(single), "platform": "windows"}}
built = dos_targets.build(registry, records, uid)
key = str(-123456 & 0xFFFFFFFF)
check(list(built) == [key], f"only the installed GOG DOS entry gets a row, keyed by UNSIGNED appid ({list(built)})")
row = built.get(key, {})
check(row.get("launcher_exe") == str(mom / "Launcher.exe"), "the row carries the shortcut's exe for an exact argv match")
check(row.get("token") == "gog:1207658855" and len(row.get("variants", [])) == 2 and row.get("choice") is None,
      "token, both variants, no choice yet")

kept = dos_targets.merge_choices(built, {key: {"choice": "Master of Magic Community Patch"}})
check(kept[key]["choice"] == "Master of Magic Community Patch", "a sync keeps a remembered choice that still exists")
dropped = dos_targets.merge_choices(built, {key: {"choice": "Caster of Magic"}})
check(dropped[key]["choice"] is None, "a choice naming a variant that is gone is dropped, not kept dangling")
check(built[key]["choice"] is None, "merge_choices does not mutate its input")
check(dos_targets.merge_choices(built, None) == built, "no current file → the built rows as they are")
try:
    odd = dos_targets.merge_choices(built, {key: {"choice": ["not", "a", "label"]}})
    check(odd[key]["choice"] is None, "a non-string choice is dropped, no raise")
except Exception as exc:
    bad(f"a non-string choice raised {type(exc).__name__}")
PY
)"
rc=$?
printf '%s\n' "$out"
PASS=$((PASS + $(grep -c '^  ok ' <<<"$out" || true)))
FAIL=$((FAIL + $(grep -c '^  FAIL' <<<"$out" || true)))
[ "$rc" -eq 0 ] || { echo "  FAIL the dos-targets checks crashed (exit $rc)"; FAIL=$((FAIL + 1)); }

echo
echo "dos-targets: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
