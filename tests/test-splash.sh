#!/usr/bin/env bash
# Offline layout + rotation check for the boot splash drawer.
#
#   tests/test-splash.sh
#
# WHY THIS EXISTS. The splash is the one thing on this device whose failures are invisible by
# construction: it runs before there is a journal to read, on a board with no serial console
# ([[sm8650-no-uart]]), and every way it can be wrong looks the same from the outside — a black
# panel. "Logo clipped off the edge", "text rendered outside the visible area", "rotation applied
# the wrong way round" and "the binary never started" are one symptom on hardware, and finding
# out which costs a power-down, a card mount and an offline journal read.
#
# So this drives the REAL drawer through its `ppm` backend, which renders into PANEL space using
# exactly the same rotation the DRM and fbdev backends use, and asserts on the PIXELS. Every
# geometry in the device registry, every rotation, at build-host speed.
#
# WHAT IT CANNOT TELL YOU, so that a green run is not over-read: this proves the drawer's
# arithmetic, not the image's tool inventory and not one line of KMS. The DRM path — master,
# modeset, DirtyFB, the handover — is only answerable on hardware ([[offline-suite-inherits-host-path]]).
#
# Runs on the host, no root, no device. Needs a C compiler and python3.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRCDIR="$ROOT/apps/novadeck-splash"
BIN="$SRCDIR/build/novadeck-splash.host"
DEVDIR="$ROOT/rootfs/overlay/usr/lib/novadeck/devices"
ASSET="$ROOT/work/splash/logo.nds1"

PASS=0; FAIL=0
ok()  { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

command -v python3 >/dev/null 2>&1 || { echo "python3 not found" >&2; exit 1; }

# The host build is a test artifact, not a shipped one, so building it here rather than depending
# on a make target keeps this suite runnable on its own.
if ! make -C "$SRCDIR" host >"$TMP/build.log" 2>&1; then
    echo "host build failed:" >&2; cat "$TMP/build.log" >&2; exit 1
fi

# A font is needed for the text assertions. Prefer the one the image actually ships so the metrics
# under test are the metrics that will ship; fall back to any host TTF so the suite still runs on a
# checkout that has never built a rootfs.
FONT=""
for cand in "$ROOT/work/base/usr/share/fonts/noto/NotoSansMono-Medium.ttf" \
            /usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf \
            /usr/share/fonts/TTF/DejaVuSansMono.ttf; do
    [[ -f $cand ]] && { FONT=$cand; break; }
done
[[ -n $FONT ]] || { echo "no TrueType font available to test with" >&2; exit 1; }

# Likewise the logo: use the real asset when the build has produced one, otherwise synthesise a
# tiny NDS1 so the geometry assertions still mean something.
if [[ ! -f $ASSET ]]; then
    ASSET="$TMP/logo.nds1"
    python3 - "$ASSET" <<'PY'
import struct, sys
w = h = 64
px = bytearray()
for y in range(h):
    for x in range(w):
        # An opaque disc on a transparent field: enough to test placement and clipping.
        inside = (x - w / 2) ** 2 + (y - h / 2) ** 2 < (w / 2 - 2) ** 2
        px += bytes((255, 255, 255, 255)) if inside else bytes(4)
open(sys.argv[1], "wb").write(b"NDS1" + struct.pack("<II", w, h) + bytes(px))
PY
fi

# ---------------------------------------------------------------------------------------------
# Pixel probe. Reports the PPM's dimensions and the bounding box of everything that is not the
# background, which is all the assertions below need.
# ---------------------------------------------------------------------------------------------
probe() {  # probe <file> -> "w h x0 y0 x1 y1 nonbg"  (bbox is -1s when nothing was drawn)
    python3 - "$1" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read()
parts = d.split(b'\n', 3)
w, h = map(int, parts[1].split())
px = parts[3]
x0 = y0 = 1 << 30; x1 = y1 = -1; n = 0
for y in range(h):
    row = px[y * w * 3:(y + 1) * w * 3]
    for x in range(w):
        # >8 rather than >0: the logo's halo fades asymptotically, and a single unit of blue in
        # the far corner is not "drawn content" for the purpose of a clipping check.
        if row[x*3] > 8 or row[x*3+1] > 8 or row[x*3+2] > 8:
            n += 1
            if x < x0: x0 = x
            if x > x1: x1 = x
            if y < y0: y0 = y
            if y > y1: y1 = y
print(w, h, (x0 if x1 >= 0 else -1), (y0 if y1 >= 0 else -1), x1, y1, n)
PY
}

render() {  # render <out.ppm> <panel_w> <panel_h> <rotate> <status-text> [extra args...]
    local out=$1 pw=$2 ph=$3 rot=$4 text=$5; shift 5
    printf '%s\n' "$text" >"$TMP/status"
    "$BIN" --backend ppm --width "$pw" --height "$ph" --rotate "$rot" \
           --image "$ASSET" --font "$FONT" --status "$TMP/status" --out "$out" \
           "$@" >"$TMP/stderr" 2>&1
}

# ---------------------------------------------------------------------------------------------
# 1. Every panel in the device registry, every rotation
# ---------------------------------------------------------------------------------------------
# Rotation is the arithmetic most likely to be wrong and least likely to be noticed until a device
# shows a sideways logo, so it is checked against the real panel line-up rather than one size.
echo "device registry:"
geoms=()
if [[ -d $DEVDIR ]]; then
    while IFS= read -r conf; do
        w=$(sed -n 's/^[[:space:]]*NOVADECK_PANEL_NATIVE_WIDTH=["'"'"']*\([0-9]*\).*/\1/p' "$conf" | head -1)
        h=$(sed -n 's/^[[:space:]]*NOVADECK_PANEL_NATIVE_HEIGHT=["'"'"']*\([0-9]*\).*/\1/p' "$conf" | head -1)
        [[ -n $w && -n $h ]] && geoms+=("$(basename "$conf" .conf) $w $h")
    done < <(find "$DEVDIR" -name '*.conf' | sort)
fi
# A checkout with no registry must not silently pass an empty loop.
if [[ ${#geoms[@]} -eq 0 ]]; then
    bad "device registry declared no panel geometries (looked in ${DEVDIR#"$ROOT"/})"
else
    ok "found ${#geoms[@]} panel geometries in the registry"
fi

for g in "${geoms[@]}"; do
    read -r name pw ph <<<"$g"
    for rot in 0 90 180 270; do
        tag="$name ${pw}x${ph} rot=$rot"
        if ! render "$TMP/o.ppm" "$pw" "$ph" "$rot" "Starting NovaDeck"; then
            bad "$tag: drawer exited non-zero"; continue
        fi
        # The asset must never be scaled up; the drawer says so and mksplash.sh sizes for it.
        if grep -q "upscaled" "$TMP/stderr"; then
            bad "$tag: logo was upscaled — raise RENDER_PX in image/mksplash.sh"; continue
        fi
        read -r ow oh x0 y0 x1 y1 n < <(probe "$TMP/o.ppm")
        # Panel-space output is always the panel's real size, whatever the rotation.
        if [[ $ow != "$pw" || $oh != "$ph" ]]; then
            bad "$tag: rendered ${ow}x${oh}, expected ${pw}x${ph}"; continue
        fi
        if [[ $n -lt 100 ]]; then
            bad "$tag: only $n pixels drawn — the frame is effectively blank"; continue
        fi
        # Nothing may touch the outermost row/column. A logo or a status line that runs off the
        # edge is the failure mode this whole suite exists to catch, and it is invisible on a
        # device until someone photographs the panel.
        if [[ $x0 -le 0 || $y0 -le 0 || $x1 -ge $((pw - 1)) || $y1 -ge $((ph - 1)) ]]; then
            bad "$tag: content touches the panel edge (bbox ${x0},${y0}..${x1},${y1})"; continue
        fi
        ok "$tag"
    done
done

# ---------------------------------------------------------------------------------------------
# 2. Rotation actually rotates, and in the direction the panel property asks for
# ---------------------------------------------------------------------------------------------
# A rotation bug that swapped the sense of 90 and 270 would still satisfy every check above. This
# pins the direction: with the canvas in landscape and the panel portrait, rot=90 must put the
# logical TOP of the frame against the panel's RIGHT edge (DRM's RIGHT_UP), and rot=270 against
# its LEFT. Rendering a frame with no text makes the logo the only content, so the asymmetry to
# measure is the one the gap below the logo creates.
echo
echo "rotation direction:"
render "$TMP/r90.ppm" 400 800 90 "x" && read -r _ _ ax0 _ ax1 _ _ < <(probe "$TMP/r90.ppm")
render "$TMP/r270.ppm" 400 800 270 "x" && read -r _ _ bx0 _ bx1 _ _ < <(probe "$TMP/r270.ppm")
# The text sits BELOW the logo in logical space. Under rot=90 logical-down maps to panel-left, so
# the drawn content's centre of mass sits left of the panel's midline; under rot=270 it mirrors.
a_mid=$(( (ax0 + ax1) / 2 )); b_mid=$(( (bx0 + bx1) / 2 ))
if [[ $a_mid -lt 200 && $b_mid -gt 200 ]]; then
    ok "rot=90 puts logical-down on the panel's left, rot=270 on its right"
else
    bad "rotation direction is wrong or mirrored (rot90 mid=$a_mid, rot270 mid=$b_mid, want <200 and >200)"
fi

# ---------------------------------------------------------------------------------------------
# 3. Text: wrapping, the error marker, and the empty case
# ---------------------------------------------------------------------------------------------
echo
echo "status text:"

render "$TMP/long.ppm" 1920 1080 0 \
    "Installing Steam. First boot downloads and installs the Steam client, which can take several minutes on a slow connection."
read -r _ _ lx0 _ lx1 _ _ < <(probe "$TMP/long.ppm")
if [[ $lx0 -gt 0 && $lx1 -lt 1919 ]]; then
    ok "a long status line wraps inside the panel"
else
    bad "a long status line ran off the panel (x ${lx0}..${lx1})"
fi

# The '!' prefix is a marker, not content: it must colour the line red and never be drawn. Compare
# against the same text without it — a red line has far less green than a near-white one.
green_of() {
    python3 - "$1" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read(); parts = d.split(b'\n', 3)
w, h = map(int, parts[1].split()); px = parts[3]
# Sum green only over pixels that are clearly text-bright, ignoring the blue logo.
print(sum(px[i+1] for i in range(0, w*h*3, 3) if px[i] > 128))
PY
}
render "$TMP/plain.ppm" 1920 1080 0 "Steam launch failed"
render "$TMP/err.ppm"   1920 1080 0 "!Steam launch failed"
gp=$(green_of "$TMP/plain.ppm"); ge=$(green_of "$TMP/err.ppm")
if [[ $ge -lt $((gp * 3 / 4)) && $ge -gt 0 ]]; then
    ok "a '!' status line renders red (green $ge vs $gp)"
else
    bad "the '!' error marker did not change the colour (green $ge vs $gp)"
fi

# An empty status must still draw the logo — a blank panel is exactly what we are trying to avoid.
render "$TMP/empty.ppm" 1920 1080 0 ""
read -r _ _ _ _ _ _ en < <(probe "$TMP/empty.ppm")
[[ $en -gt 100 ]] && ok "an empty status still draws the logo" \
                  || bad "an empty status drew nothing at all ($en pixels)"

# ---------------------------------------------------------------------------------------------
# 4. Degraded inputs must degrade, not abort
# ---------------------------------------------------------------------------------------------
# On a device with no console, a drawer that exits because one input was missing is strictly worse
# than one that shows a partial frame: the first is a black screen, the second still says
# something. These pin that choice so a later refactor cannot quietly turn it into an exit.
echo
echo "degraded inputs:"

printf 'Preparing\n' >"$TMP/status"
"$BIN" --backend ppm --width 800 --height 600 --font "$FONT" --status "$TMP/status" \
       --image "$TMP/nonexistent.nds1" --out "$TMP/nologo.ppm" >"$TMP/e1" 2>&1
rc=$?
read -r _ _ _ _ _ _ n1 < <(probe "$TMP/nologo.ppm" 2>/dev/null || echo "0 0 -1 -1 -1 -1 0")
[[ $rc -eq 0 && $n1 -gt 0 ]] && ok "a missing logo still renders the status text" \
                             || bad "a missing logo aborted the render (rc=$rc, $n1 pixels)"

"$BIN" --backend ppm --width 800 --height 600 --image "$ASSET" --status "$TMP/status" \
       --font "$TMP/nonexistent.ttf" --out "$TMP/nofont.ppm" >"$TMP/e2" 2>&1
rc=$?
read -r _ _ _ _ _ _ n2 < <(probe "$TMP/nofont.ppm" 2>/dev/null || echo "0 0 -1 -1 -1 -1 0")
[[ $rc -eq 0 && $n2 -gt 0 ]] && ok "a missing font still renders the logo" \
                             || bad "a missing font aborted the render (rc=$rc, $n2 pixels)"

# A truncated or corrupt asset must be refused by name, not read past its end.
head -c 200 "$ASSET" >"$TMP/trunc.nds1"
"$BIN" --backend ppm --width 800 --height 600 --image "$TMP/trunc.nds1" --font "$FONT" \
       --status "$TMP/status" --out "$TMP/trunc.ppm" >"$TMP/e3" 2>&1
grep -q "bad NDS1 header" "$TMP/e3" && ok "a truncated NDS1 asset is rejected by name" \
                                    || bad "a truncated NDS1 asset was not reported ($(head -1 "$TMP/e3"))"

# An invalid rotation is a caller bug and must fail loudly rather than silently drawing upright.
"$BIN" --backend ppm --rotate 45 --out "$TMP/bad.ppm" >"$TMP/e4" 2>&1
[[ $? -ne 0 ]] && ok "an invalid --rotate is refused" || bad "--rotate 45 was accepted"

# ---------------------------------------------------------------------------------------------
# 5. The handover loop, and surviving switch_root
# ---------------------------------------------------------------------------------------------
# THIS IS THE REGRESSION TEST FOR THE BUG THAT REACHED HARDWARE. The drawer is started from the
# initramfs and keeps running across switch_root, which chroots its children and then deletes the
# old root's contents -- so the drawer is left with an empty root and every path-based open()
# fails from then on. It painted correctly, ticked forever, and never yielded the display, with
# nothing in any log to say why. The fix is to hold a dirfd on the run directory instead of
# re-resolving paths, and this proves it: the run directory is made UNREACHABLE BY PATH after the
# drawer starts, exactly as the pivot does, and the handshake must still work.
#
# The `null` backend exists for this: it runs the real control loop and presents nowhere, so the
# loop is reachable without a display.
echo
echo "handover across switch_root:"

RUN="$TMP/run/novadeck/splash"
mkdir -p "$RUN"
printf 'Starting NovaDeck\n' >"$RUN/status"

"$BIN" --backend null --width 640 --height 480 --image "$ASSET" --font "$FONT" \
       --status "$RUN/status" --takeover "$RUN/takeover" >"$TMP/null.log" 2>&1 &
drawer=$!
# Give it time to announce ownership before anything moves.
for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -s "$RUN/takeover" ]] && break; sleep 0.2; done

if [[ "$(cat "$RUN/takeover" 2>/dev/null)" == "$drawer" ]]; then
    ok "the drawer announces its own pid in the takeover file"
else
    bad "the drawer did not announce ownership (takeover='$(cat "$RUN/takeover" 2>/dev/null)', pid=$drawer)"
fi

# Simulate the pivot: the directory keeps existing and keeps its inode (as the moved /run tmpfs
# does), but the PATH the drawer was given no longer resolves to it. A path-based implementation
# reads nothing from here on; a dirfd-based one is unaffected.
mv "$TMP/run" "$TMP/run-moved"
RUN="$TMP/run-moved/novadeck/splash"
if [[ -e "$TMP/run/novadeck/splash/takeover" ]]; then
    bad "the pivot simulation did not actually break the path"
else
    ok "the run directory is no longer reachable by its original path"
fi

# Status must still flow. A regression here is the "splash says Starting NovaDeck forever" half.
printf 'Installing Steam\n' >"$RUN/status"
sleep 1
# Then the handover. A regression here is the half that black-screens the session.
printf 'sddm\n' >"$RUN/takeover"

gone=0
for _ in $(seq 1 25); do
    kill -0 "$drawer" 2>/dev/null || { gone=1; break; }
    sleep 0.2
done
if [[ $gone -eq 1 ]]; then
    ok "the drawer yields and exits after the pivot (dirfd survived)"
else
    bad "the drawer did NOT yield after the pivot -- it is re-resolving paths, not using a dirfd"
    kill "$drawer" 2>/dev/null
fi
wait "$drawer" 2>/dev/null
grep -q "yielding display to 'sddm'" "$TMP/null.log" \
    && ok "it names who it yielded to" \
    || bad "no 'yielding display' line (log: $(tr '\n' '|' <"$TMP/null.log" | head -c 200))"

# The diagnostics themselves: one write() per message, because in the initramfs stderr is
# /dev/kmsg and every write becomes a separate record. Splitting a message across three writes
# lost the text entirely on hardware.
if [[ -s "$TMP/null.log" ]] && ! grep -qE '^novadeck-splash: *$' "$TMP/null.log"; then
    ok "log lines carry their message (not split across writes)"
else
    bad "empty 'novadeck-splash:' lines -- note() is splitting one message into several writes"
fi

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
