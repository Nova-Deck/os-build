#!/usr/bin/env bash
# Offline checks for the GOG and Epic cloud-save location resolver
# (.claude/plans/gog-galaxy-comet.plan.md phase 3 step 3, design §5;
# .claude/plans/epic-cloud-saves.plan.md step 2, design §2).
#
#   tests/test-store-savepaths.sh
#
# WHY THIS FILE EXISTS. GOG names a game's save folders with its own tokens (<?DOCUMENTS?>,
# <?APPLICATION_DATA_LOCAL_LOW?>, ...) or Windows variables (%LocalAppData%), Epic with its own
# ({AppData}, {UserSavedGames}, {EpicID}, ...), and the cloud sync
# needs the host folder inside the game's Proton prefix. Heroic asks Wine (winepath); a Proton
# prefix's layout is fixed, so novadeck_savepaths.py maps them with a table instead, and these
# checks pin that table. A wrong mapping uploads the wrong folder, or downloads into one the game
# never reads; a location that escapes the prefix would let a sync delete files outside it.
#
# WHAT IT CANNOT PROVE: that a game really saves where its store says. That is the HW gate.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/rootfs/overlay/usr/lib/novadeck"

out="$(python3 - "$LIB" <<'PY'
import os, pathlib, sys, tempfile
sys.path.insert(0, sys.argv[1])

def ok(m): print(f"  ok   {m}")
def bad(m): print(f"  FAIL {m}")
def check(cond, m): (ok if cond else bad)(m)

import novadeck_savepaths as sp

tmp = pathlib.Path(tempfile.mkdtemp(prefix="savepaths."))
prefix = tmp / "compatdata" / "123" / "pfx"
user = prefix / "drive_c" / "users" / "steamuser"
install = tmp / "Games" / "GOG" / "Game"
for d in (user / "Documents" / "Another World", install, prefix / "drive_c" / "ProgramData"):
    d.mkdir(parents=True)

def resolve(location):
    return sp.resolve(location, str(install), str(prefix))

def resolves(location, expected, m):
    path, reason = resolve(location)
    check(path == str(expected) and reason is None, f"{m}: {location!r} -> {path} ({reason})")

def refused(location, word, m):
    path, reason = resolve(location)
    check(path is None and isinstance(reason, str) and word in reason, f"{m}: {location!r} ({reason})")

print("== GOG's tokens")
# Another World 20th Anniversary's real location (remote-config, HW 2026-11-18).
resolves("<?DOCUMENTS?>/Another World", user / "Documents" / "Another World", "DOCUMENTS")
resolves("<?SAVED_GAMES?>/Studio/Game", user / "Saved Games" / "Studio" / "Game", "SAVED_GAMES")
resolves("<?APPLICATION_DATA_LOCAL?>/Game", user / "AppData" / "Local" / "Game", "APPLICATION_DATA_LOCAL")
resolves("<?APPLICATION_DATA_LOCAL_LOW?>/Studio/Game", user / "AppData" / "LocalLow" / "Studio" / "Game",
         "APPLICATION_DATA_LOCAL_LOW")
resolves("<?APPLICATION_DATA_ROAMING?>\\Game\\Saves", user / "AppData" / "Roaming" / "Game" / "Saves",
         "APPLICATION_DATA_ROAMING, with Windows separators")
resolves("<?INSTALL?>/saves", install / "saves", "INSTALL is the game's install folder")
refused("<?APPLICATION_SUPPORT?>/Game", "APPLICATION_SUPPORT", "a macOS-only token is refused, by name")
refused("<?NOT_A_TOKEN?>/x", "NOT_A_TOKEN", "an unknown token is refused, by name")

print("== Windows variables")
# Heroic's default for a game whose remote-config names no location (save_sync.ts).
resolves("%LocalAppData%/GOG.com/Galaxy/Applications/4984/Storage/Shared/Files",
         user / "AppData" / "Local" / "GOG.com" / "Galaxy" / "Applications" / "4984" / "Storage" / "Shared" / "Files",
         "%LocalAppData% in any case")
resolves("%APPDATA%\\..\\LocalLow\\Game", user / "AppData" / "LocalLow" / "Game",
         "%APPDATA%\\..\\LocalLow (Heroic's own spelling of LocalLow)")
resolves("%USERPROFILE%/Saved Games/Game", user / "Saved Games" / "Game", "%USERPROFILE%")
resolves("%ProgramData%/Studio", prefix / "drive_c" / "ProgramData" / "Studio", "%ProgramData%")
refused("%WINDIR%/x", "WINDIR", "an unknown variable is refused, by name")

print("== drive letters and anchoring")
resolves("C:\\ProgramData\\Studio", prefix / "drive_c" / "ProgramData" / "Studio", "C: is the prefix's drive_c")
refused("D:/Saves", "D:", "another drive letter is refused")
refused("Saves/slot1", "anchored", "a location with no token, variable or drive is refused")
refused("", "empty", "an empty location is refused")

print("== containment: a sync may delete what the other side lacks")
refused("<?INSTALL?>/../../../etc", "outside", "INSTALL/.. leaving the install folder is refused")
refused("<?DOCUMENTS?>/../../../../../../etc", "outside", "a token path climbing out of drive_c is refused")
resolves("<?DOCUMENTS?>/../AppData/Local/Game", user / "AppData" / "Local" / "Game",
         ".. that stays inside drive_c is fine")

print("== case: Wine is case-insensitive, Linux is not")
resolves("<?DOCUMENTS?>/another world", user / "Documents" / "Another World",
         "an existing folder is found in any case, so no second folder is created")
resolves("<?DOCUMENTS?>/NEW GAME", user / "Documents" / "NEW GAME", "a folder that does not exist yet keeps GOG's spelling")
(user / "Documents" / "Another World" / "Saves").mkdir()
resolves("<?documents?>/ANOTHER WORLD/saves", user / "Documents" / "Another World" / "Saves",
         "tokens match in any case, and every existing level is matched")
resolves("<?DOCUMENTS?>/../appdata/locallow/Game", user / "AppData" / "LocalLow" / "Game",
         "a Windows folder that does not exist yet takes Windows' spelling: Proton's prefix setup "
         "adds its own AppData/LocalLow beside a lowercase one, and the game reads that")

print("== Epic's variables (CloudSaveFolder; real values from the account, HW 2026-11-19)")
EPIC_ID = "0123456789abcdef0123456789abcdef"

def epic(location, epic_id=EPIC_ID):
    return sp.resolve_epic(location, str(install), str(prefix), epic_id)

def epic_resolves(location, expected, m, epic_id=EPIC_ID):
    path, reason = epic(location, epic_id)
    check(path == str(expected) and reason is None, f"{m}: {location!r} -> {path} ({reason})")

def epic_refused(location, word, m, epic_id=EPIC_ID):
    path, reason = epic(location, epic_id)
    check(path is None and isinstance(reason, str) and word in reason, f"{m}: {location!r} ({reason})")

epic_resolves("{UserSavedGames}/Nightdive Studios/DOOM 64/saves/",
              user / "Saved Games" / "Nightdive Studios" / "DOOM 64" / "saves", "DOOM 64: {UserSavedGames}")
epic_resolves("{UserDir}/GuacameleeSTCE_EGS/", user / "Documents" / "GuacameleeSTCE_EGS",
              "Guacamelee: {UserDir} is Documents")
epic_resolves("{AppData}/ZoneUE4/Saved/SaveGames/", user / "AppData" / "Local" / "ZoneUE4" / "Saved" / "SaveGames",
              "Mutant Year Zero: {AppData} is LOCAL AppData")
epic_resolves("{AppData}/../LocalLow/Team17 Digital Limited/Moving Out/",
              user / "AppData" / "LocalLow" / "Team17 Digital Limited" / "Moving Out",
              "Moving Out: {AppData}/../LocalLow, the most common form")
epic_resolves("{appdata}/../locallow/KojimaProductions/DeathStranding/{EpicID}/",
              user / "AppData" / "LocalLow" / "KojimaProductions" / "DeathStranding" / EPIC_ID,
              "Death Stranding: variables in any case, Windows' LocalLow, and {EpicID}")
epic_resolves("{userdir}/My Games/runic games/torchlight 2/save/",
              user / "Documents" / "My Games" / "runic games" / "torchlight 2" / "save",
              "Torchlight II: a game's own folders keep Epic's spelling")
epic_resolves("{InstallDir}/Breathedge/Saved/SaveGames/", install / "Breathedge" / "Saved" / "SaveGames",
              "Breathedge: {InstallDir}")
epic_resolves("{InstallDir}/", install, "Fallout: the whole install folder (its include list narrows it)")
epic_resolves("{UserProfile}/Game", user / "Game", "{UserProfile}")
epic_refused("{UserSavedGames}/Arkane Studios/Prey_Epic/{EpicID}/", "EpicID",
             "{EpicID} with no account id is refused", epic_id=None)
epic_refused("{AppData}/Game/{EpicID}", "EpicID",
             "an account id that is not one path component is refused", epic_id="../../../../etc")
epic_refused("{Foo}/Game", "Foo", "an unknown variable is refused, by name")
epic_refused("%APPDATA%/Game", "%", "a Windows variable is not Epic syntax (legendary leaves it unresolved)")
epic_refused("<?DOCUMENTS?>/Game", "<?", "a GOG token is not Epic syntax")
epic_refused("Saves/Game", "anchored", "a location with no variable is refused")
epic_refused("{InstallDir}/../../../etc", "outside", "{InstallDir}/.. leaving the install folder is refused")
epic_refused("", "empty", "an empty location is refused")

check(not (prefix / "user.reg").exists(),
      "every check above ran with NO user.reg: a prefix Proton has not created yet uses the table")

print("== the prefix's own registry (user.reg), what Wine itself reads")
# The shape of a real Proton user.reg (Another World's prefix, HW 2026-11-18), with redirects.
(prefix / "user.reg").write_text(
    'WINE REGISTRY Version 2\n'
    ';; All keys relative to REGISTRY\\\\User\\\\S-1-5-21-0-0-0-1000\n'
    '\n'
    '[Software\\\\Microsoft\\\\Windows\\\\CurrentVersion\\\\Explorer\\\\Shell Folders] 1795040178\n'
    '"Personal"="C:\\\\wrong\\\\place"\n'
    '\n'
    '[Software\\\\Microsoft\\\\Windows\\\\CurrentVersion\\\\Explorer\\\\User Shell Folders] 1795040178\n'
    '#time=1dd77aa6eec94d2\n'
    '"AppData"=str(2):"%USERPROFILE%\\\\AppData\\\\Roaming"\n'
    '"Local AppData"=str(2):"%USERPROFILE%\\\\AppData\\\\Local"\n'
    '"Personal"="C:\\\\users\\\\gamer\\\\My Docs \\x00e9"\n'
    '"{4C5C32FF-BB9D-43B0-B5B4-2D72E54EAAA4}"=str(2):"%USERPROFILE%\\\\Saved Games"\n'
    '"{A520A1A4-1780-4FF6-BD18-167343C5AF16}"=str(2):"Z:\\\\home\\\\deck\\\\LocalLow"\n'
    '\n'
    '[Volatile Environment] 1795040175\n'
    '"APPDATA"="C:\\\\users\\\\gamer\\\\AppData\\\\Roaming"\n'
    '"LOCALAPPDATA"="C:\\\\users\\\\gamer\\\\AppData\\\\Local"\n'
    '"USERPROFILE"="C:\\\\users\\\\gamer"\n')
gamer = prefix / "drive_c" / "users" / "gamer"
resolves("<?DOCUMENTS?>/Another World", gamer / "My Docs \u00e9" / "Another World",
         "a redirected Documents follows the registry, its \\x escape decoded")
resolves("<?SAVED_GAMES?>/Game", gamer / "Saved Games" / "Game",
         "%USERPROFILE% inside a folder value is the prefix's own user, not an assumed steamuser")
resolves("%LocalAppData%/Game", gamer / "AppData" / "Local" / "Game", "%LOCALAPPDATA% is Wine's own value")
refused("<?APPLICATION_DATA_LOCAL_LOW?>/Game", "Z:",
        "a folder the registry points at another drive (Z: is the Linux root) is refused")
epic_resolves("{UserDir}/Game", gamer / "My Docs é" / "Game", "Epic's {UserDir} follows the registry too")
epic_resolves("{AppData}/../LocalLow/Game", gamer / "AppData" / "LocalLow" / "Game",
              "Epic's {AppData}/../LocalLow from the registry's Local AppData")

print("== symlinks: containment is checked on the real path")
p2 = tmp / "compatdata" / "456" / "pfx"
u2 = p2 / "drive_c" / "users" / "steamuser"
u2.mkdir(parents=True)
home_docs = tmp / "home" / "Documents"
(home_docs / "Another World").mkdir(parents=True)
(u2 / "Documents").symlink_to(home_docs)  # winecfg's "link to the Linux home folders"
(u2 / "AppData" / "Roaming").mkdir(parents=True)
(u2 / "Application Data").symlink_to("./AppData/Roaming")  # what Proton itself creates
for loc, m in (("<?DOCUMENTS?>/Another World", "a save folder under a Documents linked to the Linux home"),
               ("<?DOCUMENTS?>", "that Documents itself")):
    path, reason = sp.resolve(loc, str(install), str(p2))
    check(path is None and reason and "outside" in reason, f"{m} is refused: a download deletes there ({reason})")
path, reason = sp.resolve("%USERPROFILE%/Application Data/Game", str(install), str(p2))
check(path == str(u2 / "Application Data" / "Game") and reason is None,
      f"a symlink that stays inside the prefix (Proton's own) is fine ({path}, {reason})")
PY
)"
rc=$?
printf '%s\n' "$out"
PASS=$(grep -c '^  ok ' <<<"$out" || true)
FAIL=$(grep -c '^  FAIL' <<<"$out" || true)
[ "$rc" -eq 0 ] || { echo "  FAIL the save-path checks crashed (exit $rc) — every check after the crash never ran"; FAIL=$((FAIL + 1)); }

echo
echo "savepaths: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
