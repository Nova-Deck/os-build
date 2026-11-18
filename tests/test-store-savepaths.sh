#!/usr/bin/env bash
# Offline checks for the GOG cloud-save location resolver (.claude/plans/gog-galaxy-comet.plan.md,
# phase 3 step 3; design §5).
#
#   tests/test-store-savepaths.sh
#
# WHY THIS FILE EXISTS. GOG names a game's save folders with its own tokens (<?DOCUMENTS?>,
# <?APPLICATION_DATA_LOCAL_LOW?>, ...) or Windows variables (%LocalAppData%), and the cloud sync
# needs the host folder inside the game's Proton prefix. Heroic asks Wine (winepath); a Proton
# prefix's layout is fixed, so novadeck_savepaths.py maps them with a table instead, and these
# checks pin that table. A wrong mapping uploads the wrong folder, or downloads into one the game
# never reads; a location that escapes the prefix would let a sync delete files outside it.
#
# WHAT IT CANNOT PROVE: that a game really saves where GOG says. That is the phase 3 HW gate.
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
