#!/usr/bin/env bash
# Offline checks for the Decky stack: the loader pin, the homebrew seed/sync, the units that run
# it, the FEX AppConfig, the CEF sentinel, and the novadeck-control plugin backend.
#
#   images/test-decky.sh
#
# WHY THIS FILE EXISTS. Almost everything decky-shaped fails INVISIBLY on device: a loader without
# its exec bit, a unit condition on a path the image spells differently, a sync that clobbers a
# self-updated loader, a sanitizer that lets appid 0 through — each reads as "the QAM tab just
# is not there" (or worse, quietly tunes Valve's prefix helper) with nothing in the journal to
# name the culprit. Every check here is a decision the scripts make on paths and file content,
# which is exactly what a fabricated tree can exercise on the host: no root, no device, no bus.
#
# The one thing this deliberately CANNOT prove: PluginLoader (x86_64) actually running under our
# FEX build, and Decky actually injecting into our Steam client. Those are the two HW gates.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYNC="$ROOT/fs-overlay/usr/lib/novadeck/decky-sync"
PIN="$ROOT/packages/decky-loader/prebuilt.pin"
PLUGIN="$ROOT/decky/novadeck-control"
UNITDIR="$ROOT/fs-overlay/usr/lib/systemd/system"
WANTSDIR="$ROOT/fs-overlay/etc/systemd/system/multi-user.target.wants"
APPCONF="$ROOT/fs-overlay/usr/share/fex-emu/AppConfig/PluginLoader.json"

PASS=0; FAIL=0; SKIP=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

pin_field() { sed -n "s/^$2:[[:space:]]*//p" "$1" | head -1; }

# Two checks below make CPython write a __pycache__ NEXT TO THE SOURCE, inside decky/, which the
# build stages into the image: the py_compile of the plugin backend, and the block that imports
# novadeck_control to exercise sanitize_tweaks. Redirect all bytecode out of the tree.
#
# This replaces a post-hoc `find $PLUGIN -name __pycache__ -delete`, which was placed BETWEEN the
# two — so it swept the compile and never the import, and the tree kept a __pycache__ that dev
# cards then shipped (host CPython 3.14 into a 3.13 image; found on hardware 2026-08-10). A sweep
# has to be correct about ordering forever; a prefix does not. See test-perf.sh.
PYCACHE_TMP="$(mktemp -d)"
export PYTHONPYCACHEPREFIX="$PYCACHE_TMP"

# --- the pin -------------------------------------------------------------------------------
if [ -f "$PIN" ]; then
  ok "pin exists — the loader is a declared, sha256-pinned input"
  [ "$(pin_field "$PIN" mode)" = "0755" ] \
    && ok "pin mode=0755 — the placed loader is executable at rest" \
    || bad "pin mode is not 0755: plugin_loader.service would EACCES on its ExecStart"
  [ "$(pin_field "$PIN" kind)" = "file" ] \
    && ok "pin kind=file — the release asset is a bare binary, not an archive" \
    || bad "pin kind is not file: tar-extracting a bare ELF cannot work"
  [ "$(pin_field "$PIN" dest)" = "/usr/share/decky-loader/PluginLoader" ] \
    && ok "pin dest matches the path every consumer conditions on" \
    || bad "pin dest diverged from /usr/share/decky-loader/PluginLoader — units + sync + sentinel all key on it"
  sha="$(pin_field "$PIN" sha256)"
  case "$sha" in
    *[!0-9a-f]*|"") bad "pin sha256 is not a lowercase hex string" ;;
    *) [ "${#sha}" -eq 64 ] && ok "pin sha256 is well-formed" || bad "pin sha256 is ${#sha} chars, want 64" ;;
  esac
else
  bad "no prebuilt.pin at ${PIN#"$ROOT"/}"
fi

# No lock assertion either way: prebuilt rows are excluded by fetchlock AND guard-rootfs, and
# genmanifest writes the decky-loader row from the pin at the next `make relock`.

# --- the units -----------------------------------------------------------------------------
for unit in novadeck-decky-sync.service plugin_loader.service; do
  f="$UNITDIR/$unit"
  if [ ! -f "$f" ]; then bad "$unit missing from fs-overlay"; continue; fi
  grep -q '^RequiresMountsFor=/home/deck$' "$f" \
    && ok "$unit orders after the /home mount — the payload lives there" \
    || bad "$unit lacks RequiresMountsFor=/home/deck: a race with home.mount seeds into the bare root"
  [ -L "$WANTSDIR/$unit" ] \
    && ok "$unit wants-symlink present (enabled without waiting for preset-all)" \
    || bad "$unit has no multi-user.target.wants symlink: enablement rides on first-boot presets alone"
done
grep -q '^Before=plugin_loader.service$' "$UNITDIR/novadeck-decky-sync.service" 2>/dev/null \
  && ok "sync runs Before=plugin_loader.service — the loader never starts against an unseeded tree" \
  || bad "sync is not Before=plugin_loader.service: first boot races the seed against the loader"
grep -Eq '^After=.*novadeck-decky-sync\.service' "$UNITDIR/plugin_loader.service" 2>/dev/null \
  && ok "loader is After= the sync (the ordering is declared on both sides)" \
  || bad "plugin_loader.service does not order After= the sync"
grep -q '^ExecStart=/home/deck/homebrew/services/PluginLoader$' "$UNITDIR/plugin_loader.service" 2>/dev/null \
  && ok "loader execs the SEEDED copy on /home, not the read-only master" \
  || bad "loader ExecStart is not the seeded /home path — self-updates would be impossible"
preset="$ROOT/fs-overlay/usr/lib/systemd/system-preset/60-novadeck-decky.preset"
{ grep -q '^enable novadeck-decky-sync.service$' "$preset" && grep -q '^enable plugin_loader.service$' "$preset"; } 2>/dev/null \
  && ok "preset enables both units" \
  || bad "60-novadeck-decky.preset does not enable both units"

# --- the injection watchdog ----------------------------------------------------------------
# The loader running is NOT the loader working: Decky's frontend lives in Steam's CEF, injected
# over 127.0.0.1:8080, and upstream v3.2.8-pre1 drops that websocket permanently the first time
# the tab goes stale mid-connect (main.py's loader_reinjector guards get_gamepadui_tab but not
# the open_websocket on the next line). novadeck-steam's exit-42 relaunch puts a webhelper death in
# that window on every boot; whether it lands there is timing, and it has landed.
# Everything below drives the watchdog's decision loop against fake ss/systemctl —
# the loop is the whole mechanism, so an untested loop is an untested fix.
WATCHDOG="$ROOT/fs-overlay/usr/lib/novadeck/decky-inject-watchdog"
[ -x "$WATCHDOG" ] \
  && ok "decky-inject-watchdog present and executable" \
  || bad "decky-inject-watchdog missing or not executable"
wunit="$UNITDIR/novadeck-decky-watchdog.service"
if [ -f "$wunit" ]; then
  ok "novadeck-decky-watchdog.service present"
  grep -q '^ExecStart=/usr/lib/novadeck/decky-inject-watchdog$' "$wunit" \
    && ok "watchdog unit execs the watchdog" \
    || bad "watchdog unit ExecStart does not point at /usr/lib/novadeck/decky-inject-watchdog"
  grep -q '^Restart=always$' "$wunit" \
    && ok "watchdog is Restart=always — a watchdog that can die once is not one" \
    || bad "watchdog unit is not Restart=always"
else
  bad "novadeck-decky-watchdog.service missing from fs-overlay"
fi
[ -L "$WANTSDIR/novadeck-decky-watchdog.service" ] \
  && ok "watchdog wants-symlink present" \
  || bad "watchdog has no multi-user.target.wants symlink"
grep -q '^enable novadeck-decky-watchdog.service$' "$preset" 2>/dev/null \
  && ok "preset enables the watchdog" \
  || bad "60-novadeck-decky.preset does not enable the watchdog"

if [ -x "$WATCHDOG" ]; then
  WD_TMP="$(mktemp -d)"
  mkdir -p "$WD_TMP/bin" "$WD_TMP/cgroup"
  # ss speaks two dialects here and the shim answers both: -tln is "is CEF listening", -tnp is
  # "who holds an established connection to it". The pid it reports is 4242 throughout.
  cat >"$WD_TMP/bin/ss" <<'SH'
#!/bin/sh
for a in "$@"; do
  case "$a" in
    -tln) [ "${FAKE_CEF:-0}" = 1 ] && echo "LISTEN 0 10 127.0.0.1:8080 0.0.0.0:*"; exit 0 ;;
    -tnp) [ "${FAKE_CONN:-0}" = 1 ] && \
          echo '0 0 127.0.0.1:37046 127.0.0.1:8080 users:(("Decky Loader",pid=4242,fd=12))'; exit 0 ;;
  esac
done
exit 0
SH
  cat >"$WD_TMP/bin/systemctl" <<'SH'
#!/bin/sh
case "$1" in
  is-active) [ "${FAKE_ACTIVE:-1}" = 1 ] ;;
  restart)   echo "restart $2" >>"$FAKE_LOG" ;;
  *)         : ;;
esac
SH
  # Faking sleep is what makes a 15-second interval and a 15-minute backoff testable at all: the
  # naps become an assertable transcript instead of wall time.
  cat >"$WD_TMP/bin/sleep" <<'SH'
#!/bin/sh
echo "sleep $1" >>"$FAKE_LOG"
SH
  chmod 0755 "$WD_TMP/bin/ss" "$WD_TMP/bin/systemctl" "$WD_TMP/bin/sleep"

  # scenario <name> <cef> <conn> <active> <cgroup-pids> <ticks> -> transcript on stdout
  wd_run() {
    printf '%s\n' $5 >"$WD_TMP/cgroup/cgroup.procs"
    : >"$WD_TMP/log"
    PATH="$WD_TMP/bin:$PATH" \
    FAKE_CEF="$2" FAKE_CONN="$3" FAKE_ACTIVE="$4" FAKE_LOG="$WD_TMP/log" \
    NOVADECK_DECKY_LOADER_CGROUP="$WD_TMP/cgroup" \
    NOVADECK_DECKY_WATCHDOG_TICKS="$6" \
      "$WATCHDOG" 2>/dev/null || true
    cat "$WD_TMP/log"
  }
  wd_restarts() { grep -c '^restart ' <<<"$1" || true; }

  t="$(wd_run healthy 1 1 1 "843 846 4242" 5)"
  [ "$(wd_restarts "$t")" -eq 0 ] \
    && ok "watchdog: CEF up + loader connected -> never restarts (it is a watchdog, not a timer)" \
    || bad "watchdog restarts a healthy loader"

  t="$(wd_run no-cef 0 0 1 "843 846 4242" 5)"
  [ "$(wd_restarts "$t")" -eq 0 ] \
    && ok "watchdog: no debugger -> no restart (Steam being down is a state, not a fault)" \
    || bad "watchdog restarts the loader while Steam is down — it would thrash the whole boot"

  t="$(wd_run inactive 1 0 0 "843 846 4242" 5)"
  [ "$(wd_restarts "$t")" -eq 0 ] \
    && ok "watchdog: loader stopped -> left stopped (an operator debugging it keeps it stopped)" \
    || bad "watchdog restarts a deliberately stopped loader"

  t="$(wd_run dead-injection 1 0 1 "843 846 4242" 4)"
  [ "$(wd_restarts "$t")" -ge 1 ] \
    && ok "watchdog: CEF up + no connection -> restarts the loader (the bug this exists for)" \
    || bad "watchdog does NOT restart on a dead injection — the QAM tab stays gone"

  # The pid match is a substring test against ss output, so a cgroup pid that is a PREFIX of the
  # connected one must not read as healthy. 424 vs pid=4242.
  t="$(wd_run pid-prefix 1 1 1 "424" 4)"
  [ "$(wd_restarts "$t")" -ge 1 ] \
    && ok "watchdog: pid 424 does not match pid=4242 — the membership test is not a prefix test" \
    || bad "watchdog treats a prefix pid as connected: a foreign connection would mask a dead loader"

  # Backoff: settle=2 with interval 15 means a restart on every second tick, and each nap after
  # one doubles from 30s. A flat retry here would respawn a 190MB loader every 30s forever.
  t="$(wd_run backoff 1 0 1 "4242" 8)"
  naps="$(grep '^sleep ' <<<"$t" | awk '{print $2}' | tr '\n' ' ')"
  [ "$naps" = "15 30 15 60 15 120 15 240 " ] \
    && ok "watchdog: naps back off 30/60/120/240 between failed recoveries" \
    || bad "watchdog backoff transcript is '$naps', expected '15 30 15 60 15 120 15 240 '"

  t="$(wd_run backoff-ceiling 1 0 1 "4242" 80)"
  [ "$(grep -c '^sleep 900$' <<<"$t")" -ge 1 ] \
    && ok "watchdog: backoff clamps at the 900s ceiling (it keeps trying, it never gives up)" \
    || bad "watchdog backoff never reaches its 900s clamp"

  rm -rf "$WD_TMP"
fi

# --- the FEX AppConfig ---------------------------------------------------------------------
if python3 -c "import json,sys; json.load(open('$APPCONF'))" 2>/dev/null; then
  ok "AppConfig/PluginLoader.json parses — a broken file silently reverts FEX to defaults"
  python3 - "$APPCONF" <<'PY' && ok "AppConfig keeps TSO on + Multiblock off (the conservative-correctness pair)" || bad "AppConfig lost TSOEnabled=1/Multiblock=0"
import json, sys
c = json.load(open(sys.argv[1]))["Config"]
sys.exit(0 if c.get("TSOEnabled") == "1" and c.get("Multiblock") == "0" else 1)
PY
else
  bad "AppConfig/PluginLoader.json missing or invalid JSON"
fi

# --- the stylesheet is one template literal --------------------------------------------------
# A backtick anywhere inside src/styles.ts ENDS the string early, so every rule after it is
# dropped and the QAM tabs render unstyled. Nothing catches it: what follows the truncation
# parses as a valid expression, so tsc and rollup both stay green and the damage only appears
# on device. Two backticks exactly -- the ones opening and closing the literal.
styles_ts="$PLUGIN/src/styles.ts"
if [ -f "$styles_ts" ]; then
  ticks=$(tr -cd '`' <"$styles_ts" | wc -c)
  [ "$ticks" -eq 2 ] \
    && ok "styles.ts holds exactly 2 backticks — the CSS template literal is not truncated" \
    || bad "styles.ts has $ticks backticks (want 2): a stray one silently drops every CSS rule below it"
else
  bad "no styles.ts at ${styles_ts#"$ROOT"/}"
fi

# --- the CEF sentinel ----------------------------------------------------------------------
# Unconditional by decision (2026-08-08): it is Decky's only injection path. The regression this
# catches is someone "cleaning up" the always-on touch back behind a debug gate.
if grep -q '^: >"${STEAM}/.cef-enable-remote-debugging"' "$ROOT/fs-overlay/usr/bin/novadeck-steam"; then
  ok "novadeck-steam touches the CEF sentinel unconditionally (Decky's only injection path)"
else
  bad "the CEF sentinel touch is missing or re-gated: Decky polls forever and no plugin UI appears"
fi

# --- the launch-options wrapper ---------------------------------------------------------------
# The plugin writes `<wrapper> %command%` into a game's Steam launch options, which is how per-game
# FEX tuning reaches a compat tool we do NOT own — Valve's arm64 Proton, now Steam's default for
# Windows titles. Two files with no reason to be edited together have to agree on one absolute
# path: the plugin's constant, and the entry point the image ships. Drift is silent — Steam stores
# the string happily and the launch just runs unwrapped.
LAUNCH_LIB="$PLUGIN/src/lib/launchWrapper.ts"
LAUNCH_ENTRY="$ROOT/fs-overlay/usr/lib/novadeck/game-launch"
if [ -f "$LAUNCH_LIB" ]; then
  wrapper_path=$(sed -n 's/^export const LAUNCH_WRAPPER = "\(.*\)";$/\1/p' "$LAUNCH_LIB")
  [ -n "$wrapper_path" ] \
    && ok "launchWrapper.ts declares a wrapper path ($wrapper_path)" \
    || bad "launchWrapper.ts has no LAUNCH_WRAPPER constant to check"

  # The image side: an entry point must exist at exactly that path.
  if [ -n "$wrapper_path" ] && [ -e "$ROOT/fs-overlay$wrapper_path" ]; then
    ok "the image ships an entry point at the path the plugin writes"
  else
    bad "no fs-overlay$wrapper_path — the plugin would write launch options naming nothing"
  fi

  # The single entry point every tuned launch goes through, now that the in-tool shim is gone.
  # Steam stores the launch-options string happily even if it names nothing.
  if [ -f "$LAUNCH_ENTRY" ] && [ -x "$LAUNCH_ENTRY" ]; then
    ok "game-launch ships as an executable the launch options can call"
  else
    bad "game-launch is missing or not executable"
  fi

  # Absolute, because launch options run through a shell whose PATH is not ours.
  case $wrapper_path in
    /*) ok "the wrapper path is absolute (launch options get a minimal PATH)" ;;
    *)  bad "the wrapper path is relative — it would not resolve from Steam's launch shell" ;;
  esac

  # Idempotency: Steam keeps whatever string it is given, so a second wrap would nest the wrapper
  # inside itself and hand the inner one its own path as the command.
  grep -q 'if (options.includes(LAUNCH_WRAPPER)) return null;' "$LAUNCH_LIB" \
    && ok "wrapLaunchOptions is idempotent (already-wrapped options are left alone)" \
    || bad "wrapLaunchOptions has no already-wrapped guard — re-enabling a game would nest it"

  # The user's own options must survive. Steam appends bare options as ARGUMENTS to the command,
  # so they have to stay after %command% or they arrive at the wrapper instead of the game.
  grep -q 'LAUNCH_WRAPPER} ${COMMAND_TOKEN} ${trimmed}' "$LAUNCH_LIB" \
    && ok "user launch options are preserved after %command%" \
    || bad "user launch options are dropped or placed before %command%"

  # The launch options are now the ONLY way tuning reaches a game, so the two things that used to
  # do it in-tool must stay gone. Both were removed together on purpose (2026-08-18, HW-validated):
  # the shim exec'd a host path that does not exist inside SLR4, and the strip was what kept our
  # Protons out of SLR4 in the first place. Re-adding either alone produces a tool that cannot
  # launch at all -- `exec: /usr/lib/novadeck/game-launch: not found`.
  ASSEMBLE="$ROOT/images/assemble-rootfs.sh"
  grep -q 'novadeck-proton' "$ASSEMBLE" \
    && bad "assemble-rootfs.sh writes an in-tool shim again — it cannot resolve /usr inside SLR4" \
    || ok "no in-tool shim is written (tuning comes from launch options)"

  grep -qE "sed -i '/require_tool_appid/d'" "$ASSEMBLE" \
    && bad "assemble-rootfs.sh strips require_tool_appid again — that opts our Protons out of SLR4" \
    || ok "require_tool_appid is left intact (our Protons run in SLR4, like Valve's)"

  grep -q "declares no require_tool_appid" "$ASSEMBLE" \
    && ok "the assembler ASSERTS the SLR4 dependency instead (a silent drop would run bare)" \
    || bad "nothing checks require_tool_appid is still declared upstream"

  grep -q 'syncLaunchWrapper' "$PLUGIN/src/tabs/Games.tsx" \
    && ok "the Games tab syncs the wrapper with the per-game enable switch" \
    || bad "nothing in the Games tab writes launch options — the wrapper would never be applied"
else
  bad "no launchWrapper.ts at ${LAUNCH_LIB#"$ROOT"/}"
fi

# --- the sync script, driven against a fabricated tree -------------------------------------
if [ ! -x "$SYNC" ]; then
  bad "decky-sync missing or not executable"
else
  ok "decky-sync is executable in the tree (the exec bit is rootfs content)"
  T="$(mktemp -d)"
  trap 'rm -rf "$T"' EXIT
  share="$T/share"; home="$T/homebrew"
  mkdir -p "$share/decky-loader" "$share/decky-plugins/novadeck-control/dist"
  printf 'LOADER-V1' >"$share/decky-loader/PluginLoader"; chmod 0755 "$share/decky-loader/PluginLoader"
  printf 'dist-v1'   >"$share/decky-plugins/novadeck-control/dist/index.js"
  run_sync() {
    NOVADECK_DECKY_USER="$(id -un)" NOVADECK_DECKY_GROUP="$(id -gn)" \
    NOVADECK_DECKY_HOMEBREW="$home" \
    NOVADECK_DECKY_LOADER="$share/decky-loader/PluginLoader" \
    NOVADECK_DECKY_PLUGINS="$share/decky-plugins" \
    bash "$SYNC"
  }

  # fresh flash: everything seeds
  run_sync || bad "sync failed on an empty homebrew"
  [ -x "$home/services/PluginLoader" ] && [ "$(cat "$home/services/PluginLoader")" = "LOADER-V1" ] \
    && ok "fresh seed: loader lands executable in homebrew/services" \
    || bad "fresh seed: loader missing or wrong content"
  [ "$(cat "$home/settings/loader.json" 2>/dev/null)" = '{
  "branch": 1
}' ] && ok "fresh seed: loader.json pins the prerelease branch (where the arm fixes live)" \
     || bad "fresh seed: loader.json missing or not branch:1"
  [ -f "$home/plugins/novadeck-control/dist/index.js" ] \
    && ok "fresh seed: baked plugin copied into homebrew/plugins" \
    || bad "fresh seed: plugin did not seed"

  # normal boot: no-op
  before="$(stat -c %Y "$home/services/PluginLoader")"
  sleep 1; run_sync || bad "sync failed on an already-seeded tree"
  [ "$(stat -c %Y "$home/services/PluginLoader")" = "$before" ] \
    && ok "steady state: an unchanged bundle does not rewrite the loader" \
    || bad "steady state: the loader was rewritten with nothing to do"

  # pin change with an untouched install: re-seed, in EITHER direction
  printf 'LOADER-V0-ROLLBACK' >"$share/decky-loader/PluginLoader"
  run_sync || bad "sync failed on a pin change"
  [ "$(cat "$home/services/PluginLoader")" = "LOADER-V0-ROLLBACK" ] \
    && ok "pin change: re-seeds even when the change is a rollback (the pin is authoritative)" \
    || bad "pin change: the image's loader did not replace the seeded one"

  # operator self-updated via Decky: hands off
  printf 'SELF-UPDATED-V9' >"$home/services/PluginLoader"
  printf 'LOADER-V2' >"$share/decky-loader/PluginLoader"
  run_sync || bad "sync failed on a self-updated tree"
  [ "$(cat "$home/services/PluginLoader")" = "SELF-UPDATED-V9" ] \
    && ok "self-updated loader: the image keeps its hands off" \
    || bad "self-updated loader was clobbered by the image copy"

  # loader.json is loader-owned state after the first seed
  printf '{\n  "branch": 0\n}\n' >"$home/settings/loader.json"
  run_sync
  grep -q '"branch": 0' "$home/settings/loader.json" \
    && ok "loader.json: the user's branch choice survives every later sync" \
    || bad "loader.json was rewritten after the first seed"

  # baked plugins force-replace; a plugin SHRINKING must not leave stale files behind
  printf 'stale' >"$home/plugins/novadeck-control/dist/leftover.js"
  printf 'dist-v2' >"$share/decky-plugins/novadeck-control/dist/index.js"
  run_sync
  [ "$(cat "$home/plugins/novadeck-control/dist/index.js")" = "dist-v2" ] \
    && ok "baked plugin: force-replaced with the image copy every boot" \
    || bad "baked plugin content did not update"
  [ ! -e "$home/plugins/novadeck-control/dist/leftover.js" ] \
    && ok "baked plugin: a removed file does not survive as a stale leftover" \
    || bad "baked plugin: stale file survived the replace (rm-before-copy is broken)"

  # user-installed plugins are not ours to touch
  mkdir -p "$home/plugins/SomeStorePlugin"; printf 'user' >"$home/plugins/SomeStorePlugin/main.py"
  run_sync
  [ "$(cat "$home/plugins/SomeStorePlugin/main.py" 2>/dev/null)" = "user" ] \
    && ok "user-installed plugin untouched by the sync" \
    || bad "user-installed plugin was damaged by the sync"

  # no baked loader = broken image (the loader ships in EVERY build): the sync must fail LOUDLY
  # under set -e, never quietly seed a loaderless tree the boot then trusts.
  rm -rf "$T/none"; mkdir -p "$T/none"
  if NOVADECK_DECKY_USER="$(id -un)" NOVADECK_DECKY_GROUP="$(id -gn)" \
     NOVADECK_DECKY_HOMEBREW="$T/none/homebrew" \
     NOVADECK_DECKY_LOADER="$T/none/nonexistent" \
     NOVADECK_DECKY_PLUGINS="$T/none/plugins" bash "$SYNC" 2>/dev/null; then
    bad "absent loader: the sync exited 0 — a broken image would boot with a silently empty seed"
  elif [ ! -e "$T/none/homebrew/services/PluginLoader" ]; then
    ok "absent loader: the sync FAILS (a broken image is loud, not silently unseeded)"
  else
    bad "absent loader: a PluginLoader appeared out of nowhere"
  fi
fi

# --- the thunk override UI (issue #47) -------------------------------------------------------
# The tweaks-file contract lives in game-launch (tested by test-perf.sh); what CAN regress here
# is the plugin half: the backend serving the namespace, and the tab offering a tri-state.
grep -q '"fexThunks"' "$PLUGIN/main.py" \
  && ok "_build_config serves the thunk namespace alongside fexProfiles" \
  || bad "main.py does not expose fexThunks — the tab has nothing to enumerate"
grep -q 'fexThunks' "$PLUGIN/src/tabs/Games.tsx" \
  && ok "Games tab enumerates thunks from the backend-served base list" \
  || bad "Games tab has no thunk controls — the override is hand-edit-only again (issue #47)"
grep -q 'as shipped' "$PLUGIN/src/tabs/Games.tsx" \
  && ok "thunk control is tri-state — 'as shipped' is a distinct default state, not a checkbox" \
  || bad "no 'as shipped' state in the thunk control: a plain checkbox would write a value for every thunk and seize Valve's per-title curation"

# --- the plugin backend --------------------------------------------------------------------
if python3 -m py_compile "$PLUGIN/main.py" "$PLUGIN"/py_modules/novadeck_control/*.py 2>/dev/null; then
  ok "plugin backend compiles (the loader would swallow a SyntaxError into a blank tab)"
else
  bad "plugin backend does not compile"
fi

# The python block prints the same `  ok  `/`  FAIL` lines; fold them into THIS script's
# counters so the summary line counts every check that was actually shown.
pyout="$(python3 - "$PLUGIN" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[1] + "/py_modules")
from novadeck_control import tweaks

def ok(m): print(f"  ok   {m}")
def bad(m): print(f"  FAIL {m}"); sys.exit(1)

clean = tweaks.sanitize_tweaks({"global": {"nice": -5}, "games": {
    "0": {"enabled": True, "nice": -20},          # Valve's no-app sentinel
    "40800": {"enabled": True, "cores": "big"},
    "abc": {"enabled": True},                      # non-digit appid
    "123": "not-a-dict",
}})
if "0" in clean["games"]:
    bad("sanitizer accepted appid 0 — the UI could tune Valve's prefix-setup helper")
ok("sanitizer refuses appid 0 (the no-app sentinel can never grow a section)")
if "abc" in clean["games"] or "123" in clean["games"]:
    bad("sanitizer accepted a non-digit appid or a non-dict game section")
ok("sanitizer drops non-digit appids and non-dict sections")
if clean["games"].get("40800") != {"enabled": True, "cores": "big"}:
    bad("sanitizer damaged a valid game section")
ok("sanitizer passes a valid section through untouched (deep validation stays at the consumers)")
try:
    tweaks.sanitize_tweaks({"global": {"x": "y" * (300 * 1024)}})
    bad("sanitizer accepted an oversized payload")
except ValueError:
    ok("sanitizer caps the payload size")
try:
    tweaks.sanitize_tweaks(["not", "a", "dict"])
    bad("sanitizer accepted a non-dict payload")
except ValueError:
    ok("sanitizer rejects a non-dict payload")

# The thunk namespace the UI offers must be EXACTLY the shipped base config's ThunksDB —
# enumerated, never restated. A restated list drifted before (fex-profiles.json once carried an
# EGL key the base does not have; issue #47), and game-launch ignores any name outside the base,
# so a drifted UI offers dead controls.
import pathlib
root = pathlib.Path(sys.argv[1]).resolve().parents[1]
base_config = root / "fs-overlay/usr/share/fex-emu/Config.json"
shipped = list(json.load(open(base_config))["ThunksDB"])
tweaks.FEX_BASE_CONFIG = base_config
if tweaks.load_base_thunks() != shipped:
    bad("load_base_thunks does not enumerate the shipped ThunksDB — the UI namespace drifted from the base")
ok("thunk namespace: the UI enumerates exactly the base config's ThunksDB (no restated list to drift)")
tweaks.FEX_BASE_CONFIG = root / "does-not-exist.json"
if tweaks.load_base_thunks() != []:
    bad("an absent base config must yield an empty thunk list (the UI then hides the section), not raise")
ok("thunk namespace: absent base config degrades to an empty list")

# PyInstaller exports LD_LIBRARY_PATH=<bundle dir> to children; a busctl spawned with it loads
# the bundle's libcrypto and dies (HW-observed as "AvailableProfiles returned non-zero exit
# status 1" in the Power tab). The backend must strip it — or restore PyInstaller's saved _ORIG.
import os
from novadeck_control import power
os.environ["LD_LIBRARY_PATH"] = "/tmp/_MEIfake"
os.environ.pop("LD_LIBRARY_PATH_ORIG", None)
if "LD_LIBRARY_PATH" in power._clean_env():
    bad("subprocess env keeps the PyInstaller LD_LIBRARY_PATH — busctl dies on the bundled libcrypto")
ok("subprocess env drops the PyInstaller LD_LIBRARY_PATH")
os.environ["LD_LIBRARY_PATH_ORIG"] = "/real/path"
if power._clean_env().get("LD_LIBRARY_PATH") != "/real/path":
    bad("subprocess env does not restore LD_LIBRARY_PATH_ORIG when PyInstaller saved one")
ok("subprocess env restores PyInstaller's saved LD_LIBRARY_PATH_ORIG")

# The Monitor's CPU/GPU rows classify thermal zones by their `type` prefix. Getting that
# wrong shows a dash forever rather than an error, so drive it with the REAL zone names from
# both SoCs we ship. These are the sysfs `type` strings VERBATIM, captured off an SM8650
# device 2026-08-09 -- note they KEEP the "-thermal" suffix of the DT node name, which is why
# the classifier matches on a prefix and not on an exact name. SM8650 spells the GPU zones
# `gpuss0-thermal`, SM8550 spells them `gpuss-0-thermal`, and the CPU zones are a mix of
# `cpussN-thermal` and `cpuN-middle-thermal`. Zones we must NOT count as either are in there
# too -- a hot modem or DSP is not a hot CPU.
import pathlib, tempfile
from novadeck_control import telemetry

def fake_zones(zones):
    root = pathlib.Path(tempfile.mkdtemp())
    for index, (kind, millicelsius) in enumerate(zones):
        zone = root / f"thermal_zone{index}"
        zone.mkdir()
        (zone / "type").write_text(kind + "\n")
        (zone / "temp").write_text(f"{millicelsius}\n")
    telemetry.THERMAL_ROOT = root
    return telemetry._temperatures()

got = fake_zones([
    ("cpuss0-thermal", 61000), ("cpu7-middle-thermal", 67500),
    ("gpuss0-thermal", 58000), ("gpuss3-thermal", 59500),
    ("video-thermal", 90000), ("modem0-thermal", 95000),
    ("nsphvx0-thermal", 99000), ("ddr-thermal", 91000),
])
if got != {"cpuC": 67.5, "gpuC": 59.5}:
    bad(f"SM8650 zone names misclassified: {got}")
ok("thermal zones: real SM8650 `type` strings (-thermal suffix kept) classify correctly")

got = fake_zones([
    ("cpuss3-thermal", 55000), ("cpu5-top-thermal", 62100),
    ("gpuss-0-thermal", 71200), ("gpuss-7-thermal", 70000),
    ("mem-thermal", 88000), ("modem1-thermal", 97000),
])
if got != {"cpuC": 62.1, "gpuC": 71.2}:
    bad(f"SM8550 zone names misclassified: {got}")
ok("thermal zones: SM8550 names (hyphenated gpuss-N) classify the same way")

# A disabled sensor reads exactly 0; counting it as "0 °C" would be a lie, and taking a max
# over it is harmless only because every real zone is warmer.
got = fake_zones([("cpuss0-thermal", 0), ("cpu0-thermal", 48000), ("gpuss0-thermal", 0)])
if got != {"cpuC": 48.0, "gpuC": 0.0}:
    bad(f"a zone reading 0 was treated as a real measurement: {got}")
ok("thermal zones: a sensor reading 0 does not mask a live one, and absent stays 0")

if fake_zones([]) != {"cpuC": 0.0, "gpuC": 0.0}:
    bad("no thermal zones at all should report zeros, not raise")
ok("thermal zones: a device with no zones degrades to zeros")
PY
)"
printf '%s\n' "$pyout"
PASS=$((PASS + $(grep -c '^  ok ' <<<"$pyout" || true)))
if grep -q '^  FAIL' <<<"$pyout"; then FAIL=$((FAIL+1)); fi

python3 -c "
import json, sys
m = json.load(open('$PLUGIN/plugin.json'))
sys.exit(0 if m.get('flags') == ['root'] and m.get('name') else 1)
" && ok "plugin.json declares flags:[root] — without it every /etc write turns into EACCES" \
  || bad "plugin.json is missing flags:[root] (or a name)"

# --- the assembler + Makefile wiring -------------------------------------------------------
grep -q 'decky-plugins/novadeck-control' "$ROOT/images/assemble-rootfs.sh" \
  && ok "assembler stages the plugin (4c-3)" \
  || bad "assembler has no plugin staging block"
grep -q 'decky-loader/PluginLoader' "$ROOT/images/guard-rootfs.sh" \
  && ok "guard-rootfs asserts the loader (assertion 9) — image completeness is checked at build" \
  || bad "guard-rootfs has no loader assertion: an incomplete image would ship undetected"
grep -q 'test-decky.sh' "$ROOT/Makefile" \
  && ok "this suite is wired into make test (a suite nothing runs is documentation)" \
  || bad "images/test-decky.sh is not in the Makefile test target"

rm -rf "$PYCACHE_TMP"   # no trap: one is already claimed for EXIT below, and a strand in /tmp is
                        # harmless — the thing that must never be dirtied is the tree, and the
                        # prefix has already guaranteed that whether or not this line runs.

printf '\n%s: %d passed, %d failed, %d skipped\n' "$(basename "$0")" "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
