#!/usr/bin/env bash
# Offline checks for the native game page (.claude/plans/native-game-page.plan.md): Steam's own
# action button, label and click, driven by our state for a NovaDeck entry.
#
#   tests/test-store-native-page.sh
#
# WHY THIS FILE EXISTS. The button's whole behaviour is one table (src/native/status.ts): which
# EDisplayStatus Steam is shown for each of our states, and where its press goes. Two rows matter
# most. While Steam itself is launching or running the app the button must be Steam's, or Cancel
# and Resume stop working. And a press Steam must never get (a finishing install, a removed
# entry) must be swallowed, or Steam's Play runs the install stub or a half-installed game.
#
# WHAT IT CANNOT PROVE: that the button, the play-bar row and the gear menu are found on the arm64
# client, or how they look and focus. That is the hardware walkthrough in the plan.
#
# The table runs under node, which strips the TypeScript types itself (node >= 23.6). Without one
# the table is SKIPPED, not passed: like every offline suite this inherits the host PATH.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/apps/decky/novadeck-stores/src"
PASS=0 FAIL=0 SKIP=0
ok()   { printf '  ok   %s\n' "$*"; PASS=$((PASS + 1)); }
bad()  { printf '  FAIL %s\n' "$*"; FAIL=$((FAIL + 1)); }
skip() { printf '  skip %s\n' "$*"; SKIP=$((SKIP + 1)); }

echo "== the status table (src/native/status.ts)"
node_major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
if [ "$node_major" -lt 24 ]; then
  skip "no node >= 24 on PATH to run status.ts (have: ${node_major})"
else
  out="$(node --no-warnings - "$SRC/native/status.ts" <<'JS'
const { nativeAction, DisplayStatus: S } = await import(process.argv[2]);
const rows = [];
const check = (name, got, status, intent) => {
  const good = got.status === status && got.intent === intent;
  rows.push(`${good ? "  ok  " : "  FAIL"} ${name} (got ${JSON.stringify(got)})`);
};
const f = (state, blocked = false) => ({ state, blocked });

check("not known yet: Steam's own button (its Play runs the stub, which installs)",
  nativeAction(null, S.ReadyToLaunch, false), null, "none");
check("an entry ready to install shows Steam's Install, and installs",
  nativeAction(f("install"), S.ReadyToLaunch, false), S.ReadyToInstall, "install");
check("an install that cannot start shows a disabled button and swallows the press",
  nativeAction(f("install", true), S.ReadyToLaunch, false), S.InvalidPlatform, "none");
check("a running download shows Steam's Pause, and stops it",
  nativeAction(f("downloading"), S.ReadyToLaunch, false), S.Downloading, "stop");
check("a paused download shows Steam's Resume, and resumes it",
  nativeAction(f("paused"), S.ReadyToLaunch, false), S.DownloadPaused, "resume");
check("a finishing install is disabled with Steam's throbber; Play never reaches the game",
  nativeAction(f("finishing"), S.ReadyToLaunch, false), S.Installing, "none");
check("a removed entry is disabled; Play never reaches the stub",
  nativeAction(f("stale"), S.ReadyToLaunch, false), S.InvalidPlatform, "none");
check("an installed entry keeps Steam's own Play",
  nativeAction(f("installed"), S.ReadyToLaunch, false), null, "none");
check("a press being answered shows the throbber, and a second press is swallowed",
  nativeAction(f("install"), S.ReadyToLaunch, true), S.Installing, "none");
for (const [name, live] of [["launching", S.Launching], ["running", S.Running], ["terminating", S.Terminating]]) {
  check(`while Steam is ${name} the app the button is Steam's, whatever our state`,
    nativeAction(f("downloading"), live, false), null, "none");
}
console.log(rows.join("\n"));
JS
)"
  printf '%s\n' "$out"
  PASS=$((PASS + $(grep -c '^  ok ' <<<"$out" || true)))
  FAIL=$((FAIL + $(grep -c '^  FAIL' <<<"$out" || true)))
  [ -n "$out" ] || bad "status.ts did not run under node"
fi

echo "== the wiring"
grep -q 'applyNativePage()' "$SRC/index.tsx" \
  && grep -A20 'onDismount()' "$SRC/index.tsx" | grep -q 'removeNativePage' \
  && ok "the native page is applied at load and removed at dismount" \
  || bad "index.tsx does not apply AND remove the native page"
grep -q 'isNativePageActive()' "$SRC/GamePage.tsx" \
  && ok "the legacy row stands down while the native page is live, and comes back when it is not" \
  || bad "GamePage.tsx injects its row even while Steam's own button is ours"
! grep -rq '2_000_000_000\|2000000000' "$SRC/native" "$SRC/NativePage.tsx" \
  && ok "ownership is the backend's registry answer, never an appid threshold" \
  || bad "the native page gates on an appid threshold"

# The gear menu renders synchronously from cached answers, and a cache is only filled by the hook
# that reads it. HW 2026-11-19: nothing on the native page called useOnBoxtron / useDosVersions, so
# "DOSBox version…" never showed for a Boxtron title with two versions.
for hook in useOnBoxtron useDosVersions useCloudSaves; do
  grep -q "^\s*${hook}(\|= ${hook}(\|(${hook}(" "$SRC/NativePage.tsx" \
    && ok "the native page calls ${hook}, which fills the cache the gear menu reads" \
    || bad "NativePage.tsx never calls ${hook}: the gear menu's item for it can never show"
done

grep -q 'test-store-native-page.sh' "$ROOT/Makefile" \
  && ok "this suite is wired into make test (a suite nothing runs is documentation)" \
  || bad "tests/test-store-native-page.sh is not in the Makefile test target"

echo
echo "test-store-native-page.sh: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
