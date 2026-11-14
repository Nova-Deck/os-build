#!/usr/bin/env bash
# Offline check for the gamescope display profile that supplies our panels' HDR capability.
#
#   tests/test-display-profile.sh
#
# WHY THIS EXISTS. Our panels carry no EDID, so this Lua file is the ONLY place gamescope learns
# that a panel is wide-gamut, gamma-2.2 HDR, and how bright it gets. Every way it can be wrong is
# quiet:
#
#   * Match too narrowly and HDR silently never engages — the toggle is there, nothing happens.
#   * Match too WIDELY and a dual-screen board's small secondary panel (Thor, Thor Lite, Pocket DS —
#     all of which declare a peak, and on all of which BOTH panels are internal and EDID-less) gets
#     told it is a wide-gamut HDR panel at the primary's peak. "gamescope only scans out
#     --prefer-output" is the happy path, not a guarantee: connector selection falls back when the
#     preferred name is missing, and this project has already lit the wrong panel exactly that way.
#   * Register an hdr block with a missing or unparseable peak and every HDR title is mastered
#     against a fabricated number.
#
# None of that shows up as an error. So the real shipped file is loaded here against a stub
# gamescope table and its matches() is driven directly.
#
# Runs on the host with no root and no device.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE="$ROOT/rootfs/overlay/usr/share/gamescope/scripts/10-novadeck/novadeck.internal-amoled.lua"

PASS=0; FAIL=0; SKIP=0
ok()   { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }
check() { [[ $2 == "$3" ]] && ok "$1" || bad "$1 (want '$3', got '$2')"; }

[[ -f $PROFILE ]] || { echo "display profile is missing: $PROFILE" >&2; exit 1; }

# The image does not ship a lua interpreter and neither does every dev box; this suite proves the
# profile's LOGIC, so a missing interpreter is a skip, not a failure. It must not silently pass.
LUA=""
for c in lua5.4 lua5.3 lua luajit; do command -v "$c" >/dev/null 2>&1 && { LUA=$c; break; }; done
if [[ -z $LUA ]]; then
    # Only the profile's own logic needs the interpreter: the session/client/conf checks further
    # down still run, so a host without Lua cannot turn the whole suite green by skipping it.
    printf '  SKIP no lua interpreter on PATH — cannot exercise the profile\n'
    SKIP=$((SKIP + 1))
else

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Stub only what the profile touches, so the file under test is the real one.
cat > "$TMP/drive.lua" <<'LUA'
gamescope = { config = { known_displays = {} }, eotf = { gamma22 = "gamma22" } }
dofile(arg[1])
local p = gamescope.config.known_displays.novadeck_internal_amoled
if p == nil then print("NOPROFILE") ; os.exit(0) end
print("NITS " .. tostring(p.hdr.max_content_light_level))
print("FALL " .. tostring(p.hdr.max_frame_average_luminance))
print("SUPPORTED " .. tostring(p.hdr.supported))
print("EOTF " .. tostring(p.hdr.eotf))
-- device_id, internal, has_edid, connector
for line in io.lines(arg[2]) do
    local id, internal, edid, conn = line:match("^(.-),(.-),(.-),(.*)$")
    print(p.matches{
        device_id = id,
        internal  = internal == "1",
        has_edid  = edid == "1",
        connector = conn,
    })
end
LUA

cases="$TMP/cases"
cat > "$cases" <<'EOF'
ayn-thor-lite,1,0,DSI-1
ayn-thor-lite,1,0,DSI-2
ayn-thor-lite,0,1,HDMI-A-1
ayn-thor-lite,1,1,DSI-1
,1,0,DSI-1
EOF

run() { # $1=nits $2=primary -> prints NITS/... then one verdict per case line
    NOVADECK_PANEL_HDR_NITS="$1" NOVADECK_PRIMARY_CONNECTOR="$2" \
        "$LUA" "$TMP/drive.lua" "$PROFILE" "$cases" 2>&1
}

# --- an HDR board with a named primary connector -------------------------------------------------
out=$(run 650 DSI-1)
mapfile -t L <<<"$out"
check "peak comes from the environment, not the file"   "${L[0]}" "NITS 650"
check "frame-average tracks the same peak"              "${L[1]}" "FALL 650"
check "profile claims HDR support"                      "${L[2]}" "SUPPORTED true"
check "transfer function is gamma 2.2, not PQ"          "${L[3]}" "EOTF gamma22"
check "primary panel matches"                           "${L[4]}" "6000"
check "DUAL-SCREEN: secondary panel does NOT match"     "${L[5]}" "-1"
check "external output does not match"                  "${L[6]}" "-1"
check "a panel with a real EDID is left to its EDID"    "${L[7]}" "-1"
check "a board that named no device id does not match"  "${L[8]}" "-1"

# --- the peak is per-board, and really is read per-run -------------------------------------------
out=$(run 800 DSI-1); mapfile -t L <<<"$out"
check "a different board's peak is picked up unchanged" "${L[0]}" "NITS 800"

# --- SDR boards, and junk, must register NO profile at all ---------------------------------------
# A profile with a fabricated peak is worse than no profile: HDR would engage against a made-up
# number instead of staying off.
check "no peak declared -> no profile"      "$(run ''    DSI-1 | head -1)" "NOPROFILE"
check "peak of 0 -> no profile"             "$(run 0     DSI-1 | head -1)" "NOPROFILE"
check "unparseable peak -> no profile"      "$(run abc   DSI-1 | head -1)" "NOPROFILE"
check "trailing junk in peak -> no profile" "$(run 650x  DSI-1 | head -1)" "NOPROFILE"

# --- a board that lets gamescope auto-pick its connector ------------------------------------------
# Nothing to compare against, so any internal EDID-less panel is accepted. Documented fallback: no
# board that declares a peak currently leaves the connector empty, and refusing to match would turn
# HDR off entirely for one that did.
out=$(run 650 ''); mapfile -t L <<<"$out"
check "auto-pick board still matches its panel" "${L[4]}" "6000"

fi # LUA

# --- the rest of the HDR chain: session, client, device confs --------------------------------------
# The profile is only reached if the session hands it its inputs, and HDR must never come back as a
# forced composite. These need no interpreter, so they run even where Lua is missing above. The
# connector export is checked too: without it the profile's dual-screen guard silently turns off.
SESSION="$ROOT/rootfs/overlay/usr/bin/novadeck-session"
STEAMSH="$ROOT/rootfs/overlay/usr/bin/novadeck-steam"
DEVENV="$ROOT/rootfs/overlay/usr/lib/novadeck/device-env"
DEVICES="$ROOT/rootfs/overlay/usr/lib/novadeck/devices"

# --hdr-itm-enable performs no tone mapping in gamescope 3.17.0 and only forces a full composite on
# every frame; --hdr-enabled would force HDR output on at startup instead of leaving it to Steam.
if grep -v '^[[:space:]]*#' "$SESSION" | grep -qE -- '--hdr-'; then
    bad "novadeck-session passes gamescope no --hdr-* flag"
else
    ok "novadeck-session passes gamescope no --hdr-* flag"
fi

# Run the session's HDR block as it ships, extracted by its first and last lines.
block=$(sed -n '/^: "\${NOVADECK_PANEL_HDR_NITS:=0}"/,/^fi$/p' "$SESSION")
if [[ -z $block ]]; then
    bad "novadeck-session's HDR block was found"
else
    hdr_env() { # $1=nits -> prints the exported device id (or NONE) and whether the peak is exported
        # The device-env facts are eval'd, not exported, in the real session: set them as plain
        # shell variables so only the block's own exports can reach the environment.
        env -i /bin/sh -c "NOVADECK_DEVICE_ID=ayn-odin-3 NOVADECK_PRIMARY_CONNECTOR=DSI-1
            ${1:+NOVADECK_PANEL_HDR_NITS=$1}
            $block"'
            printf "%s %s %s %s\n" "$(env | sed -n "s/^GAMESCOPE_INTERNAL_DEVICE_ID=//p" | grep . || echo NONE)" "$(env | grep -c "^NOVADECK_PANEL_HDR_NITS=")" "$(env | sed -n "s/^NOVADECK_PRIMARY_CONNECTOR=//p" | grep . || echo NONE)" "$(env | sed -n "s/^STEAM_GAMESCOPE_HDR_SUPPORTED=//p" | grep . || echo NONE)"'
    }
    check "an HDR board exports the device id, peak, connector and Steam toggle" "$(hdr_env 650)" "ayn-odin-3 1 DSI-1 1"
    check "an SDR board exports none of them"                      "$(hdr_env 0)"   "NONE 0 NONE NONE"
    check "a board declaring nothing exports none of them"         "$(hdr_env '')"  "NONE 0 NONE NONE"
fi

grep -qxE '[[:space:]]*NOVADECK_PANEL_HDR_NITS' "$DEVENV" \
    && ok "device-env publishes NOVADECK_PANEL_HDR_NITS" \
    || bad "device-env publishes NOVADECK_PANEL_HDR_NITS"
# novadeck-steam re-reads the device registry, so a gate there would reset a session.conf peak to
# the board's default and hide the toggle the session just turned on.
if grep -v '^[[:space:]]*#' "$STEAMSH" | grep -qE 'STEAM_GAMESCOPE_HDR_SUPPORTED|NOVADECK_PANEL_HDR_NITS'; then
    bad "novadeck-steam leaves the HDR toggle to the session"
else
    ok "novadeck-steam leaves the HDR toggle to the session"
fi

# A peak on a board without per-plane colour pipelines (kernel 0399) composites every HDR frame,
# which costs it direct scanout. Completeness check, not a runtime gate.
for conf in "$DEVICES"/*.conf; do
    nits=$(sed -n 's/^NOVADECK_PANEL_HDR_NITS=//p' "$conf" | tail -1)
    [[ -n $nits && $nits != 0 ]] || continue
    soc=$(sed -n 's/^NOVADECK_SOC_CLASS=//p' "$conf" | tail -1)
    case $soc in
        SM8550|SM8650|SM8750) ok "$(basename "$conf") declares a peak on $soc, which has plane LUTs" ;;
        *) bad "$(basename "$conf") declares a peak on '$soc', which has no plane LUTs" ;;
    esac
done

printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[[ $FAIL -eq 0 ]]
