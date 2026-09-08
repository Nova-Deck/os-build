#!/usr/bin/env bash
# novadeck splash asset builder -> work/splash/logo.nds1
#
# Rasterises image/splash/logo.svg and flattens it to the raw NDS1 container that
# novadeck-splash loads (apps/novadeck-splash). Two steps, both host-native and both at BUILD
# time, on purpose:
#
#   logo.svg --rsvg-convert--> logo.png --image/png2nds1.py--> logo.nds1
#
# NOTHING HERE IS CROSS-COMPILED, AND THAT IS THE POINT. An earlier splash attempt cross-built an
# aarch64 SVG rasteriser to render on the device; the result needed a newer glibc than the image
# has, failed to load, and showed nothing — a failure that looks exactly like a splash that ran
# and drew a black screen. Nothing about a boot logo needs to happen on the target, so nothing
# here does.
#
# The intermediate PNG is kept rather than piped because it is the artifact to look at when the
# logo comes out wrong, and because png2nds1.py verifies every chunk CRC — which is only useful
# if there is a file to re-run it against.
#
# The logo is rendered at the LARGEST size any panel can ask for and scaled DOWN at runtime, so
# one asset stays correct across the whole device registry instead of baking a per-device size.
#
# Two consumers, which is why this is its own step rather than inlined into either:
#   image/mkinitramfs.sh     -> the copy in the initramfs (the pre-switch_root drawer)
#   rootfs/assemble-rootfs.sh -> the copy in the sealed root (the session and shutdown drawers)
#
# Run inside the build image (needs rsvg-convert + python3):
#   docker run --rm -v "$PWD":/src -w /src novadeck-build image/mksplash.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SVG="$ROOT/image/splash/logo.svg"
OUTDIR="$ROOT/work/splash"
PNG="$OUTDIR/logo.png"
NDS="$OUTDIR/logo.nds1"

# Square render box, sized so the drawer NEVER scales up: upscaling a raster logo softens it and
# the star's thin points show it first.
#
# novadeck-splash draws the logo at LOGO_NUM/LOGO_DEN of the canvas's SHORT edge (auto_logo_px()
# in apps/novadeck-splash/src/novadeck-splash.c), so the largest size it can ever ask for is that
# fraction of the largest short edge in the device registry. Rendering the full short edge, as an
# earlier iteration did, produced an 8 MB asset to draw a 480px logo.
#
# The two ends of this are kept honest from BOTH sides: the check below fails the build when the
# registry outgrows the render box, and the drawer logs an "upscaled" line that
# tests/test-splash.sh turns into a failure across every geometry in the registry. So a change to
# either the ratio or the panel line-up is caught, rather than quietly shipping a soft logo.
LOGO_NUM=360
LOGO_DEN=1080
HEADROOM_PCT=20    # covers a --logo-height override and a slightly larger future panel
RENDER_PX=576

DEVDIR="$ROOT/rootfs/overlay/usr/lib/novadeck/devices"
if [ -d "$DEVDIR" ]; then
  # The registry is the source of truth for how large this has to be. Reading it here means
  # adding a wider panel fails the BUILD rather than shipping a blurry logo nobody notices.
  widest=$(grep -h '^[[:space:]]*NOVADECK_PANEL_NATIVE_WIDTH=' "$DEVDIR"/*.conf 2>/dev/null \
           | sed 's/.*=//; s/[^0-9]//g' | sort -n | tail -1)
  if [ -n "$widest" ]; then
    need=$(( widest * LOGO_NUM / LOGO_DEN ))
    need=$(( need + need * HEADROOM_PCT / 100 ))
    if [ "$need" -gt "$RENDER_PX" ]; then
      echo "the device registry's widest short edge is ${widest}px, so the drawer can ask for" >&2
      echo "up to $(( widest * LOGO_NUM / LOGO_DEN ))px of logo; with ${HEADROOM_PCT}% headroom that needs" >&2
      echo "RENDER_PX >= ${need}, but ${0#"$ROOT"/} says ${RENDER_PX}. Raise it — otherwise the" >&2
      echo "logo is upscaled and looks soft." >&2
      exit 1
    fi
  fi
fi

[ -f "$SVG" ] || { echo "no splash source: ${SVG#"$ROOT"/}" >&2; exit 1; }
command -v rsvg-convert >/dev/null 2>&1 \
  || { echo "rsvg-convert not found (run inside novadeck-build)" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 \
  || { echo "python3 not found (run inside novadeck-build)" >&2; exit 1; }

mkdir -p "$OUTDIR"

# --background-color=none keeps the alpha channel: the drawer composites the logo over its own
# background colour, and a baked-in background would show as a square patch on the panel.
rsvg-convert --background-color=none \
             --width="$RENDER_PX" --height="$RENDER_PX" --keep-aspect-ratio \
             --output="$PNG" "$SVG"
[ -s "$PNG" ] || { echo "rsvg-convert produced an empty PNG" >&2; exit 1; }

python3 "$ROOT/image/png2nds1.py" "$PNG" "$NDS"
[ -s "$NDS" ] || { echo "png2nds1 produced an empty asset" >&2; exit 1; }

echo "[novadeck] splash: ${SVG#"$ROOT"/} -> ${NDS#"$ROOT"/} (${RENDER_PX}px, $(du -h "$NDS" | cut -f1))"
