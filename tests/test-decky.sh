#!/usr/bin/env bash
# Offline checks for the Decky stack: the loader pin, the homebrew seed/sync, the units that run
# it, the FEX AppConfig, the CEF sentinel, and both first-party plugin backends.
#
#   tests/test-decky.sh
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
SYNC="$ROOT/rootfs/overlay/usr/lib/novadeck/decky-sync"
PIN="$ROOT/packages/decky-loader/prebuilt.pin"
# The two first-party plugins. novadeck-control is the settings surface (Games + Power, writes
# game-tweaks.json, drives every powerd setter); novadeck-monitor is the read-only live panel,
# split out of control's third tab. They are separate Decky plugins with separate py_modules
# trees, so every per-plugin check below runs against both.
PLUGIN="$ROOT/apps/decky/novadeck-control"
MONITOR="$ROOT/apps/decky/novadeck-monitor"
FRAMEGEN="$ROOT/apps/decky/novadeck-framegen"
UNITDIR="$ROOT/rootfs/overlay/usr/lib/systemd/system"
WANTSDIR="$ROOT/rootfs/overlay/etc/systemd/system/multi-user.target.wants"
APPCONF="$ROOT/rootfs/overlay/usr/share/fex-emu/AppConfig/PluginLoader.json"

PASS=0; FAIL=0; SKIP=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

pin_field() { sed -n "s/^$2:[[:space:]]*//p" "$1" | head -1; }

# Two checks below make CPython write a __pycache__ NEXT TO THE SOURCE, inside apps/decky/, which the
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
  if [ ! -f "$f" ]; then bad "$unit missing from rootfs/overlay"; continue; fi
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
preset="$ROOT/rootfs/overlay/usr/lib/systemd/system-preset/60-novadeck-decky.preset"
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
WATCHDOG="$ROOT/rootfs/overlay/usr/lib/novadeck/decky-inject-watchdog"
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
  bad "novadeck-decky-watchdog.service missing from rootfs/overlay"
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
# dropped and the QAM panel renders unstyled. Nothing catches it: what follows the truncation
# parses as a valid expression, so tsc and rollup both stay green and the damage only appears
# on device. Two backticks exactly -- the ones opening and closing the literal.
# BOTH plugins carry their own stylesheet (the metric/meter rules left novadeck-control with the
# Monitor tab), so both are exposed to this and both are checked.
for styles_ts in "$PLUGIN/src/styles.ts" "$MONITOR/src/styles.ts"; do
  rel="${styles_ts#"$ROOT"/}"
  if [ -f "$styles_ts" ]; then
    ticks=$(tr -cd '`' <"$styles_ts" | wc -c)
    [ "$ticks" -eq 2 ] \
      && ok "$rel holds exactly 2 backticks — the CSS template literal is not truncated" \
      || bad "$rel has $ticks backticks (want 2): a stray one silently drops every CSS rule below it"
  else
    bad "no styles.ts at $rel"
  fi
done

# --- the CEF sentinel ----------------------------------------------------------------------
# Unconditional by decision (2026-08-08): it is Decky's only injection path. The regression this
# catches is someone "cleaning up" the always-on touch back behind a debug gate.
if grep -q '^: >"${STEAM}/.cef-enable-remote-debugging"' "$ROOT/rootfs/overlay/usr/bin/novadeck-steam"; then
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
LAUNCH_ENTRY="$ROOT/rootfs/overlay/usr/lib/novadeck/game-launch"
if [ -f "$LAUNCH_LIB" ]; then
  wrapper_path=$(sed -n 's/^export const LAUNCH_WRAPPER = "\(.*\)";$/\1/p' "$LAUNCH_LIB")
  [ -n "$wrapper_path" ] \
    && ok "launchWrapper.ts declares a wrapper path ($wrapper_path)" \
    || bad "launchWrapper.ts has no LAUNCH_WRAPPER constant to check"

  # The image side: an entry point must exist at exactly that path.
  if [ -n "$wrapper_path" ] && [ -e "$ROOT/rootfs/overlay$wrapper_path" ]; then
    ok "the image ships an entry point at the path the plugin writes"
  else
    bad "no rootfs/overlay$wrapper_path — the plugin would write launch options naming nothing"
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
  ASSEMBLE="$ROOT/rootfs/assemble-rootfs.sh"
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
  # TWO baked plugins in the fake tree, matching what the image now ships: the sync takes no
  # list, it copies every directory under the plugins root, and a one-plugin fixture could not
  # tell that apart from a hardcoded name.
  mkdir -p "$share/decky-loader" "$share/decky-plugins/novadeck-control/dist" \
           "$share/decky-plugins/novadeck-monitor/dist"
  printf 'LOADER-V1' >"$share/decky-loader/PluginLoader"; chmod 0755 "$share/decky-loader/PluginLoader"
  printf 'dist-v1'   >"$share/decky-plugins/novadeck-control/dist/index.js"
  printf 'mon-v1'    >"$share/decky-plugins/novadeck-monitor/dist/index.js"
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
  # NO loader.json IS WRITTEN, and that is the assertion. We used to seed {"branch": 1} to "pin new
  # installs to the prerelease branch where the arm fixes land" — a misreading: in
  # decky_loader/updater.py branch 1 filters on tag.startswith("v"), i.e. EVERY release, so it meant
  # "newest of either kind", never "arm fixes sooner". Left unset, the loader derives the branch
  # from the version it runs (-pre -> 1, else 0), which keeps the choice in one place: the pin.
  [ ! -e "$home/settings/loader.json" ] \
    && ok "fresh seed: no loader.json is written — the loader derives its branch from the pin" \
    || bad "fresh seed: a loader.json was seeded; the branch is the loader's to decide"
  [ -f "$home/plugins/novadeck-control/dist/index.js" ] \
    && ok "fresh seed: baked plugin copied into homebrew/plugins" \
    || bad "fresh seed: plugin did not seed"
  [ -f "$home/plugins/novadeck-monitor/dist/index.js" ] \
    && ok "fresh seed: EVERY baked plugin seeds, not just the first (the sync globs, it has no list)" \
    || bad "fresh seed: the second baked plugin did not seed"

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

  # loader.json is loader-owned state and nothing here may touch it — still worth asserting now that
  # we never create it either, because "we do not write it" and "we do not overwrite it" are
  # different promises and only the second one protects a choice the user made in Decky's settings.
  printf '{\n  "branch": 0\n}\n' >"$home/settings/loader.json"
  run_sync
  grep -q '"branch": 0' "$home/settings/loader.json" \
    && ok "loader.json: the user's branch choice survives every later sync" \
    || bad "loader.json was rewritten by the sync"

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

# --- the sync does NOT chown plugins/ --------------------------------------------------------
# Decky owns that directory's ownership and re-asserts it seconds after the sync exits (upstream
# v3.2.8-pre1: main.py chowns PRIVILEGED_PATH/plugins to the effective user, gated on
# CHOWN_PLUGIN_PATH which defaults on; browser.py then chowns each plugin dir to root or the host
# user depending on its root flag). Chowning it here was dead work that made decky-sync's comment
# describe a state that does not survive boot. The fabricated-tree run above cannot catch a
# re-addition -- it runs as the invoking user, so a stray chown to self is a silent no-op -- so
# assert on the line itself.
sync_chown=$(grep -E '^chown -R' "$SYNC")
if grep -q 'plugins' <<<"$sync_chown"; then
  bad "decky-sync chowns plugins/ again — Decky undoes it every boot; the ownership is upstream's, not ours"
else
  ok "decky-sync leaves plugins/ ownership to Decky (it chowns it per plugin, by root flag)"
fi
{ grep -q 'services' <<<"$sync_chown" && grep -q 'settings' <<<"$sync_chown"; } \
  && ok "decky-sync still chowns services/ and settings/ — those the loader writes as the user" \
  || bad "decky-sync no longer chowns services/ or settings/: the loader's own writes turn into EACCES"

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
  ok "novadeck-control backend compiles (the loader would swallow a SyntaxError into a blank tab)"
else
  bad "novadeck-control backend does not compile"
fi
if python3 -m py_compile "$MONITOR/main.py" "$MONITOR"/py_modules/novadeck_monitor/*.py 2>/dev/null; then
  ok "novadeck-monitor backend compiles"
else
  bad "novadeck-monitor backend does not compile"
fi
if python3 -m py_compile "$FRAMEGEN/main.py" "$FRAMEGEN"/py_modules/novadeck_framegen/*.py 2>/dev/null; then
  ok "novadeck-framegen backend compiles"
else
  bad "novadeck-framegen backend does not compile"
fi

# COMPAT TOOLS MUST NOT REACH THE GAME PICKER. Proton, the Steam Linux Runtimes and Valve's FEX
# compat tool install as ordinary apps with their own appmanifest, so they arrive in installed_games()
# beside real titles -- and a per-game tweak on one is meaningless, because nothing launches them
# directly. Both plugins carry the same enumerator, so both are exercised against ONE fake library:
# a real game plus three tools, each of which is a tool only because its install directory holds a
# toolmanifest.vdf. That is the marker the filter uses; asserting it here is what stops someone
# "simplifying" it into an appid list that rots on the next Valve runtime.
for _p in "$PLUGIN/py_modules/novadeck_control/steam.py" "$FRAMEGEN/py_modules/novadeck_framegen/steam.py"; do
  _got="$(python3 - "$_p" <<'PY' 2>/dev/null
import sys, tempfile, pathlib, importlib.util
mod_path = pathlib.Path(sys.argv[1])
d = pathlib.Path(tempfile.mkdtemp())
apps = d / "steamapps"; (apps / "common").mkdir(parents=True)
def mk(appid, name, installdir, is_tool):
    (apps / f"appmanifest_{appid}.acf").write_text(
        '"AppState"\n{\n\t"appid"\t\t"%s"\n\t"name"\t\t"%s"\n\t"installdir"\t\t"%s"\n}\n'
        % (appid, name, installdir))
    p = apps / "common" / installdir
    p.mkdir(parents=True, exist_ok=True)
    if is_tool:
        (p / "toolmanifest.vdf").write_text('"manifest"\n{\n"require_tool_appid" "4185400"\n}\n')
mk("2737300", "A Real Game", "A Real Game", False)
mk("1391110", "Steam Linux Runtime - Soldier", "SteamLinuxRuntime_soldier", True)
mk("1580130", "Proton 9.0", "Proton 9.0", True)
mk("3127680", "FEX", "FEX", True)
# No toolmanifest.vdf and nothing else in the manifest marks these -- they are the appid exceptions.
mk("228980", "Steamworks Common Redistributables", "Steamworks Shared", False)
mk("993090", "Lossless Scaling", "Lossless Scaling", False)
spec = importlib.util.spec_from_file_location("steam_under_test", mod_path)
m = importlib.util.module_from_spec(spec)
sys.modules["steam_under_test"] = m
spec.loader.exec_module(m)
m.STEAM_APPS_DIR = apps
m.STEAM_ROOT = d
print("|".join(g["name"] for g in m.installed_games()))
PY
)"
  if [ "$_got" = "A Real Game" ]; then
    ok "$(basename "$(dirname "$(dirname "$(dirname "$_p")")")"): compat tools are filtered out of the game list"
  else
    bad "$(basename "$(dirname "$(dirname "$(dirname "$_p")")")"): game list was '${_got:-<empty>}', expected only the real game"
  fi
done

# novadeck-framegen hand-rolls a TOML writer (the stdlib reads TOML but cannot write it), and it
# rewrites a file the LAYER and the USER both also write. So the round trip is checked for real
# rather than assumed: an invalid file breaks frame generation outright, and a lossy one quietly
# discards settings the user cannot get back.
#
# This caught a real bug before it shipped. `[global]` is a TABLE, so tomllib returns it nested
# under that key -- an earlier renderer treated top-level scalars as the globals and dropped
# every one of them, including `dll` (how a user points at a Lossless Scaling install we cannot
# find) and `allow_fp16` (off is the difference between working and unusable).
if python3 - "$FRAMEGEN" <<'PYEOF'
import sys, pathlib, tempfile, tomllib
sys.path.insert(0, str(pathlib.Path(sys.argv[1]) / "py_modules"))
from novadeck_framegen import conf

conf.CONFIG_PATH = pathlib.Path(tempfile.mkdtemp()) / "conf.toml"
conf.CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
conf.CONFIG_PATH.write_text(
    '[global]\nallow_fp16 = true\ndll = "/x/lsfg-vk.dll"\n\n'
    '[[profile]]\nname = "mine"\nmultiplier = 3\n')

conf.write_profile("2737300", {"multiplier": 2, "flowScale": 0.5, "performanceMode": True})
d = tomllib.loads(conf.CONFIG_PATH.read_text())          # parses at all
assert d["global"]["allow_fp16"] is True, d              # foreign globals survive
assert d["global"]["dll"] == "/x/lsfg-vk.dll", d
names = [p["name"] for p in d["profile"]]
assert "mine" in names and "novadeck-2737300" in names, names   # foreign profile survives

conf.write_profile("111", {"multiplier": 9, "flowScale": 9.0, "performanceMode": True})
ours = [p for p in tomllib.loads(conf.CONFIG_PATH.read_text())["profile"]
        if p["name"] == "novadeck-111"][0]
assert ours["multiplier"] == 4, ours                      # clamped to upstream bounds
# flow_scale must stay a FLOAT: TOML types 1 and 1.0 differently and upstream parses a float.
assert isinstance(ours["flow_scale"], float), ours

conf.write_profile("2737300", None)
names = [p["name"] for p in tomllib.loads(conf.CONFIG_PATH.read_text())["profile"]]
assert "novadeck-2737300" not in names and "mine" in names, names   # removal is surgical

# The reader is STRICT and every violation is a hard throw that leaves the layer mapped but
# inert -- which reads as success everywhere except the session log. All four were confirmed
# against upstream's own validator, and two of them shipped to a device before being caught.
d = tomllib.loads(conf.CONFIG_PATH.read_text())
assert d.get("version") == 2, d                       # missing/wrong -> config rejected outright
assert isinstance(d.get("global"), dict), d           # missing [global] -> "Invalid global section"
assert set(d) <= {"version", "global", "profile"}, d  # any other top-level key -> "Unknown key"
assert set(d["global"]) <= {"allow_fp16", "dll", "log_level", "log_file"}, d["global"]
assert d.get("profile"), d                            # an empty profile array is NOT valid either

# Removing the LAST profile must not leave a profile-less file behind, since an empty profile
# array is exactly the invalid shape above. Absent is fine: the layer recreates its own default.
conf.CONFIG_PATH.write_text('version = 2\n\n[global]\n\n[[profile]]\nname = "novadeck-999"\nmultiplier = 2\n')
conf.write_profile("999", None)
assert not conf.CONFIG_PATH.exists(), "a profile-less config file was left behind (the reader rejects it)"
PYEOF
then
  ok "novadeck-framegen's conf.toml round-trips and matches the reader's strict schema"
else
  bad "novadeck-framegen's conf.toml writer is lossy or invalid -- it would corrupt lsfg-vk's config"
fi

# The python block prints the same `  ok  `/`  FAIL` lines; fold them into THIS script's
# counters so the summary line counts every check that was actually shown.
pyout="$(python3 - "$PLUGIN" "$MONITOR" <<'PY'
import json, sys
# Both plugins' py_modules on the path. The packages are distinct (novadeck_control,
# novadeck_monitor), so there is nothing to shadow.
sys.path.insert(0, sys.argv[1] + "/py_modules")
sys.path.insert(0, sys.argv[2] + "/py_modules")
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
root = pathlib.Path(sys.argv[1]).resolve().parents[2]   # apps/decky/novadeck-control -> repo root
base_config = root / "rootfs/overlay/usr/share/fex-emu/Config.json"
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
#
# Checked in BOTH plugins. The two _clean_env implementations are independent copies (separate
# processes, separate py_modules trees — see novadeck_monitor/powerd.py's header), which is
# exactly why one can regress while the other stays correct.
import os
from novadeck_control import power
from novadeck_monitor import powerd
for label, mod in (("novadeck-control", power), ("novadeck-monitor", powerd)):
    os.environ["LD_LIBRARY_PATH"] = "/tmp/_MEIfake"
    os.environ.pop("LD_LIBRARY_PATH_ORIG", None)
    if "LD_LIBRARY_PATH" in mod._clean_env():
        bad(f"{label}: subprocess env keeps the PyInstaller LD_LIBRARY_PATH — busctl dies on the bundled libcrypto")
    ok(f"{label}: subprocess env drops the PyInstaller LD_LIBRARY_PATH")
    os.environ["LD_LIBRARY_PATH_ORIG"] = "/real/path"
    if mod._clean_env().get("LD_LIBRARY_PATH") != "/real/path":
        bad(f"{label}: subprocess env does not restore LD_LIBRARY_PATH_ORIG when PyInstaller saved one")
    ok(f"{label}: subprocess env restores PyInstaller's saved LD_LIBRARY_PATH_ORIG")

# The monitor is READ ONLY by construction: it renders powerd, it never writes it. A setter
# arriving in its backend is the regression that turns a display into a control surface with no
# UI to gate it, so the module's public surface is pinned here.
setters = [n for n in dir(powerd) if n.startswith(("set_", "reset_"))]
if setters:
    bad(f"novadeck-monitor's powerd module grew setters: {setters} — the monitor must only read")
ok("novadeck-monitor's powerd module exposes no setters (it renders powerd, it never writes it)")

# novadeck-monitor's CPU/GPU rows classify thermal zones by their `type` prefix. Getting that
# wrong shows a dash forever rather than an error, so drive it with the REAL zone names from
# both SoCs we ship. These are the sysfs `type` strings VERBATIM, captured off an SM8650
# device 2026-08-09 -- note they KEEP the "-thermal" suffix of the DT node name, which is why
# the classifier matches on a prefix and not on an exact name. SM8650 spells the GPU zones
# `gpuss0-thermal`, SM8550 spells them `gpuss-0-thermal`, and the CPU zones are a mix of
# `cpussN-thermal` and `cpuN-middle-thermal`. Zones we must NOT count as either are in there
# too -- a hot modem or DSP is not a hot CPU.
import pathlib, tempfile
from novadeck_monitor import telemetry

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

# flags:[root] on both. novadeck-control needs it to write /etc; novadeck-monitor only reads
# (world-readable sysfs, and `deck` is in wheel, which powerd's bus policy already allows), so
# dropping it there is a live option — but it is the PROVEN path, and a wrong guess here reads
# as a blank panel with an EACCES nobody sees. Changing it is a deliberate act with its own HW
# gate, which is what this assertion makes it.
for manifest in "$PLUGIN/plugin.json" "$MONITOR/plugin.json"; do
  rel="${manifest#"$ROOT"/}"
  python3 -c "
import json, sys
m = json.load(open('$manifest'))
sys.exit(0 if m.get('flags') == ['root'] and m.get('name') else 1)
" && ok "$rel declares flags:[root] and a name" \
    || bad "$rel is missing flags:[root] (or a name)"
done

# The two plugins must not collide in the QAM: Decky keys the plugin list by plugin.json name.
if [ "$(python3 -c "
import json, pathlib
names = [json.load(open(p / 'plugin.json'))['name']
         for p in sorted(pathlib.Path('$ROOT/apps/decky').iterdir()) if (p / 'plugin.json').is_file()]
print(len(names) == len(set(names)))
")" = "True" ]; then
  ok "every plugin declares a distinct name (Decky keys its plugin list by name)"
else
  bad "two plugins declare the SAME name — Decky would load one and silently drop the other"
fi

# novadeck-framegen writes the OTHER half of game-tweaks.json from novadeck-control, so the two
# must agree on the envelope: the appid "0" refusal in particular. "0" is Valve's no-app sentinel
# and DOES occur on compat-tool probe launches; a section keyed on it would apply to Steam's own
# helper runs. Both writers reject it independently because either can be the one that creates
# the file.
grep -q 'appid == "0"' "$FRAMEGEN/py_modules/novadeck_framegen/tweaks.py" \
  && ok "novadeck-framegen refuses the appid \"0\" sentinel, as novadeck-control does" \
  || bad "novadeck-framegen does not refuse appid \"0\" — it could tune Steam's own helper runs"

# The two plugins share this file and must not share an OPT-IN. `enabled` is control's "the user
# turned on per-game tuning"; framegen borrowing it made switching frame generation on light the
# game up as tuned. Round-trip it rather than grepping: what matters is the resulting FILE.
if python3 - "$FRAMEGEN" <<'FGPY' 2>/dev/null; then
import json, pathlib, sys, tempfile
sys.path.insert(0, str(pathlib.Path(sys.argv[1]) / "py_modules"))
from novadeck_framegen import tweaks

tmp = pathlib.Path(tempfile.mkdtemp()) / "game-tweaks.json"
tweaks.TWEAKS_CONFIG = tmp

# on: our key appears, control's does NOT
tweaks.set_enabled("123", True)
game = json.loads(tmp.read_text())["games"]["123"]
assert game.get("framegen") is True, "framegen key not written"
assert "enabled" not in game, "framegen claimed control's enabled flag"

# a user's tuning must survive our off-switch
tmp.write_text(json.dumps({"games": {"123": dict(game, enabled=True, cores="big")}, "global": {}}))
tweaks.set_enabled("123", False)
game = json.loads(tmp.read_text())["games"]["123"]
assert game.get("enabled") is True and game.get("cores") == "big", "disabling framegen ate the tuning"
assert "framegen" not in game and "env" not in game, "framegen left its own keys behind"

# an entry that was ONLY ours is removed entirely rather than left as litter
tmp.write_text(json.dumps({"games": {}, "global": {}}))
tweaks.set_enabled("456", True)
tweaks.set_enabled("456", False)
assert "456" not in json.loads(tmp.read_text())["games"], "framegen-only entry left behind"
FGPY
  ok "novadeck-framegen opts in with its own key and leaves novadeck-control's tuning intact"
else
  bad "novadeck-framegen's game-tweaks round-trip is wrong -- it shares or destroys control's flag"
fi

# The per-game switch is an env TOMBSTONE, and the session default it lifts lives in a different
# file entirely. If novadeck-session stops exporting DISABLE_LSFGVK, this plugin's toggle becomes
# a no-op that still reads as "on".
grep -q 'DISABLE_LSFGVK' "$ROOT/rootfs/overlay/usr/bin/novadeck-session" \
  && ok "the session still exports DISABLE_LSFGVK (what novadeck-framegen's toggle lifts)" \
  || bad "novadeck-session no longer exports DISABLE_LSFGVK — the framegen toggle would do nothing"

# The two copies of the Steam library reader are duplicated ON PURPOSE (separate py_modules per
# plugin, and the offline suite imports from the checkout). Duplicated is fine; DRIFTED is not.
if diff -q <(sed -n '/^def _read_cstring/,$p' "$PLUGIN/py_modules/novadeck_control/steam.py") \
           <(sed -n '/^def _read_cstring/,$p' "$FRAMEGEN/py_modules/novadeck_framegen/steam.py") >/dev/null; then
  ok "the two steam.py copies agree below the docstring (duplicated, not drifted)"
else
  bad "novadeck-control and novadeck-framegen steam.py have drifted — one will list games the other cannot"
fi

# The checks above encode what the reader requires; THIS one asks the reader itself. The CLI is
# the x86_64 binary we ship, so it runs natively on an x86_64 dev box and is skipped elsewhere --
# a skip is honest here, since the assertions above still cover the same ground from our side.
# It is worth having because reading the source got this wrong twice: `version` and the mandatory
# empty [global] were both missed, and both shipped.
LSFG_CLI="$ROOT/work/lsfg-vk/out/usr/bin/lsfg-vk-cli"
# Runnability probe by OUTPUT, not exit status: a bare invocation prints usage and exits 1 on a
# machine that can run the binary, so the status says nothing. On one that cannot, the shell
# fails with ENOEXEC and there is no usage text at all. The output is captured BEFORE the test
# rather than piped into grep: this script runs under `set -o pipefail`, so the CLI's exit 1
# would fail the whole pipeline no matter what grep found.
lsfg_cli_usage="$("$LSFG_CLI" 2>&1 || true)"
if [ -x "$LSFG_CLI" ] && printf '%s' "$lsfg_cli_usage" | grep -q USAGE; then
  gen_toml="$(mktemp)"
  python3 - "$FRAMEGEN" "$gen_toml" <<'PYEOF'
import sys, pathlib
sys.path.insert(0, str(pathlib.Path(sys.argv[1]) / "py_modules"))
from novadeck_framegen import conf
conf.CONFIG_PATH = pathlib.Path(sys.argv[2])
conf.write_profile("2737300", {"multiplier": 2, "flowScale": 1.0, "performanceMode": True})
PYEOF
  if "$LSFG_CLI" validate -c "$gen_toml" 2>&1 | grep -qiE 'Unsupported configuration|Invalid .* section|Unknown key'; then
    bad "upstream's own validator REJECTS the config novadeck-framegen writes"
    "$LSFG_CLI" validate -c "$gen_toml" 2>&1 | tail -3 | sed 's/^/       /'
  else
    ok "upstream's lsfg-vk-cli accepts the config novadeck-framegen writes"
  fi
  rm -f "$gen_toml"
else
  printf '  skip %s\n' "lsfg-vk-cli not runnable here (needs x86_64 + make lsfg-vk) -- schema checked from our side only"
  SKIP=$((SKIP + 1))
fi

# --- the assembler + Makefile wiring -------------------------------------------------------
for plugin_name in novadeck-control novadeck-monitor novadeck-framegen; do
  grep -qE "^for plugin_name in ([^;]*[[:space:]])?$plugin_name([[:space:]]|;)" "$ROOT/rootfs/assemble-rootfs.sh" \
    && ok "assembler stages $plugin_name (4c-3)" \
    || bad "assembler does not stage $plugin_name"
  grep -q "$plugin_name" "$ROOT/rootfs/guard-rootfs.sh" \
    && ok "guard-rootfs asserts $plugin_name staged (assertion 9)" \
    || bad "guard-rootfs has no assertion for $plugin_name: it could ship missing, undetected"
  grep -q "$plugin_name" "$ROOT/Makefile" \
    && ok "$plugin_name is in the Makefile's plugin list (its dist is a rootfs prerequisite)" \
    || bad "$plugin_name is not named in the Makefile: its dist would never build"
done
grep -q 'decky-loader/PluginLoader' "$ROOT/rootfs/guard-rootfs.sh" \
  && ok "guard-rootfs asserts the loader (assertion 9) — image completeness is checked at build" \
  || bad "guard-rootfs has no loader assertion: an incomplete image would ship undetected"
grep -q 'test-decky.sh' "$ROOT/Makefile" \
  && ok "this suite is wired into make test (a suite nothing runs is documentation)" \
  || bad "tests/test-decky.sh is not in the Makefile test target"

rm -rf "$PYCACHE_TMP"   # no trap: one is already claimed for EXIT below, and a strand in /tmp is
                        # harmless — the thing that must never be dirtied is the tree, and the
                        # prefix has already guaranteed that whether or not this line runs.

printf '\n%s: %d passed, %d failed, %d skipped\n' "$(basename "$0")" "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
