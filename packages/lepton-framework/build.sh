#!/usr/bin/env bash
# Build the tools the shared Android uses to make its own framework fix (see framework.pin):
# smali/baksmali converted to dex, so they run under the guest's ART instead of a JVM.
#
#   packages/lepton-framework/build.sh     # host side, docker for the JRE d8 needs
#
# Output, staged by rootfs/lib-assemble-storage.sh into /usr/lib/novadeck/android-framework/:
#
#   work/lepton-framework/out/smali.dex.jar      org.jf.smali.Main
#   work/lepton-framework/out/baksmali.dex.jar   org.jf.baksmali.Main
#   work/lepton-framework/out/api                the guest SDK the fix targets
#
# (restore-services.py, repack-jar.py and compile-odex.sh are staged straight from this directory.)
# SELF-CACHING like the other payload packages (.inputs.sha256 over the committed inputs).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PKGDIR="$ROOT/packages/lepton-framework"
PIN="$PKGDIR/framework.pin"
WORKDIR="$ROOT/work/lepton-framework"
TOOLS="$WORKDIR/tools"
OUT="$WORKDIR/out"
MARKER="$WORKDIR/.inputs.sha256"

pin_field() { sed -n "s/^$1:[[:space:]]*//p" "$PIN" | head -1; }
JRE="$(pin_field jre_image)"; API="$(pin_field api)"
: "${JRE:?framework.pin: missing jre_image}"
[[ "$API" =~ ^[0-9]+$ ]] || { echo "ERROR: framework.pin: api must be a number" >&2; exit 1; }

HASH="$(cat "$PKGDIR/build.sh" "$PIN" | sha256sum | cut -d' ' -f1)"
if [ "$(cat "$MARKER" 2>/dev/null)" = "$HASH" ] && [ -s "$OUT/smali.dex.jar" ] && [ -s "$OUT/baksmali.dex.jar" ]; then
  echo "[novadeck] lepton-framework: cached (inputs unchanged)" >&2
  exit 0
fi

fetch_tool() {
  local name="$1" url sha
  url="$(pin_field "${name}_url")"; sha="$(pin_field "${name}_sha256")"
  : "${url:?framework.pin: missing ${name}_url}"; : "${sha:?framework.pin: missing ${name}_sha256}"
  mkdir -p "$TOOLS"
  if ! { [ -s "$TOOLS/$name.jar" ] && echo "$sha  $TOOLS/$name.jar" | sha256sum -c --quiet - 2>/dev/null; }; then
    echo "[novadeck] lepton-framework: fetching $name" >&2
    curl -fL --retry 3 -o "$TOOLS/$name.jar.part" "$url"
    echo "$sha  $TOOLS/$name.jar.part" | sha256sum -c --quiet - \
      || { echo "ERROR: lepton-framework: sha256 mismatch for $name.jar" >&2; rm -f "$TOOLS/$name.jar.part"; exit 1; }
    mv "$TOOLS/$name.jar.part" "$TOOLS/$name.jar"
  fi
}
fetch_tool r8
fetch_tool smali
fetch_tool baksmali

rm -rf "$OUT" "$MARKER"
mkdir -p "$OUT"
for j in smali baksmali; do
  echo "[novadeck] lepton-framework: d8 $j.jar (min-api $API)" >&2
  docker run --rm -u "$(id -u):$(id -g)" -v "$TOOLS":/tools:ro -v "$OUT":/out "$JRE" \
    java -cp /tools/r8.jar com.android.tools.r8.D8 --release --min-api "$API" \
      --output "/out/$j.dex.jar" "/tools/$j.jar"
  unzip -l "$OUT/$j.dex.jar" classes.dex >/dev/null \
    || { echo "ERROR: lepton-framework: d8 produced no classes.dex for $j" >&2; exit 1; }
done
echo "$API" >"$OUT/api"

printf '%s\n' "$HASH" >"$MARKER"
echo "[novadeck] lepton-framework: smali/baksmali dex for SDK $API -> $OUT" >&2
