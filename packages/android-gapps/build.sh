#!/usr/bin/env bash
# Fetch and verify the Google Play payload for the shared Android container (see payload.pin).
#
#   packages/android-gapps/build.sh     # host side, no container: downloads + sha256 + unzip
#
# Output is a guest-rootfs overlay tree, staged by rootfs/lib-assemble-storage.sh:
#
#   work/android-gapps/out/system/product/priv-app/{Phonesky,PrebuiltGmsCore}/...
#   work/android-gapps/out/system/system_ext/priv-app/GoogleServicesFramework/...
#   work/android-gapps/out/system/{product,system_ext}/etc/{permissions,sysconfig}/...
#   work/android-gapps/out/system/product/app/SimpleKeyboard/SimpleKeyboard.apk
#
# SELF-CACHING, the same shape as the other payload packages: .inputs.sha256 records the digest of
# the committed inputs, and a matching marker with every artifact present is a no-op. Downloads are
# kept in work/android-gapps/cache so a changed member list does not re-fetch 200 MB.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PKGDIR="$ROOT/packages/android-gapps"
PIN="$PKGDIR/payload.pin"
WORKDIR="$ROOT/work/android-gapps"
CACHE="$WORKDIR/cache"
OUT="$WORKDIR/out"
MARKER="$WORKDIR/.inputs.sha256"

pin_field() { sed -n "s/^$2:[[:space:]]*//p" "$1" | head -1; }
pin_list()  { sed -n "s/^$2:[[:space:]]*//p" "$1"; }

MTG11_URL="$(pin_field "$PIN" mtg11_url)";         MTG11_SHA="$(pin_field "$PIN" mtg11_sha256)"
MTG14_URL="$(pin_field "$PIN" mtg14_url)"
PHONESKY="$(pin_field "$PIN" phonesky_member)";    PHONESKY_SHA="$(pin_field "$PIN" phonesky_sha256)"
KBD_URL="$(pin_field "$PIN" keyboard_url)";        KBD_SHA="$(pin_field "$PIN" keyboard_sha256)"
KBD_DEST="$(pin_field "$PIN" keyboard_dest)"
mapfile -t MTG11_MEMBERS < <(pin_list "$PIN" mtg11_member)
: "${MTG11_URL:?payload.pin: missing mtg11_url}"; : "${MTG11_SHA:?payload.pin: missing mtg11_sha256}"
: "${MTG14_URL:?payload.pin: missing mtg14_url}"
: "${PHONESKY:?payload.pin: missing phonesky_member}"; : "${PHONESKY_SHA:?payload.pin: missing phonesky_sha256}"
: "${KBD_URL:?payload.pin: missing keyboard_url}"; : "${KBD_SHA:?payload.pin: missing keyboard_sha256}"
: "${KBD_DEST:?payload.pin: missing keyboard_dest}"
[ "${#MTG11_MEMBERS[@]}" -gt 0 ] || { echo "ERROR: payload.pin lists no mtg11_member" >&2; exit 1; }

HASH="$(cat "$PKGDIR/build.sh" "$PIN" | sha256sum | cut -d' ' -f1)"
ARTIFACTS=("${MTG11_MEMBERS[@]}" "$PHONESKY" "$KBD_DEST")

all_present() {
  local f
  for f in "${ARTIFACTS[@]}"; do [ -s "$OUT/$f" ] || return 1; done
}

if [ "$(cat "$MARKER" 2>/dev/null)" = "$HASH" ] && all_present; then
  echo "[novadeck] android-gapps: cached (inputs unchanged)" >&2
  exit 0
fi

# fetch URL SHA256 DEST: download once into the cache, verify every time.
fetch() {
  local url="$1" sha="$2" dest="$3"
  if [ -s "$dest" ] && echo "$sha  $dest" | sha256sum -c --quiet - 2>/dev/null; then
    return 0
  fi
  rm -f "$dest" "$dest.part"
  echo "[novadeck] android-gapps: fetching ${url##*/}" >&2
  curl -fL --retry 3 -o "$dest.part" "$url"
  echo "$sha  $dest.part" | sha256sum -c --quiet - \
    || { echo "ERROR: android-gapps: sha256 mismatch for ${url##*/}" >&2; rm -f "$dest.part"; exit 1; }
  mv "$dest.part" "$dest"
}

rm -rf "$OUT" "$MARKER"
mkdir -p "$CACHE" "$OUT"

fetch "$MTG11_URL" "$MTG11_SHA" "$CACHE/mtg11.zip"
for m in "${MTG11_MEMBERS[@]}"; do
  mkdir -p "$OUT/$(dirname "$m")"
  unzip -p "$CACHE/mtg11.zip" "$m" >"$OUT/$m"
  [ -s "$OUT/$m" ] || { echo "ERROR: android-gapps: $m is not in the MindTheGapps 11 zip" >&2; exit 1; }
done

# The Play Store alone, out of the MindTheGapps 14 zip, by HTTP range: zipfile seeks to the central
# directory and reads just the one member. Verified by the extracted APK's own hash below.
if ! { [ -s "$CACHE/Phonesky.apk" ] && echo "$PHONESKY_SHA  $CACHE/Phonesky.apk" | sha256sum -c --quiet - 2>/dev/null; }; then
  echo "[novadeck] android-gapps: reading ${PHONESKY##*/} out of ${MTG14_URL##*/} (HTTP range)" >&2
  python3 - "$MTG14_URL" "$PHONESKY" "$CACHE/Phonesky.apk.part" <<'PY'
import io, sys, urllib.request, zipfile
url, member, out = sys.argv[1:4]

class Remote(io.RawIOBase):
    def __init__(self, u):
        r = urllib.request.urlopen(urllib.request.Request(u, method="HEAD"))
        self.url, self.size, self.pos = r.geturl(), int(r.headers["Content-Length"]), 0
    def seekable(self): return True
    def readable(self): return True
    def tell(self): return self.pos
    def seek(self, off, whence=0):
        self.pos = off if whence == 0 else self.pos + off if whence == 1 else self.size + off
        return self.pos
    def readinto(self, b):
        if self.pos >= self.size:
            return 0
        end = min(self.size, self.pos + len(b)) - 1
        req = urllib.request.Request(self.url, headers={"Range": f"bytes={self.pos}-{end}"})
        d = urllib.request.urlopen(req).read()
        b[:len(d)] = d
        self.pos += len(d)
        return len(d)

z = zipfile.ZipFile(io.BufferedReader(Remote(url), buffer_size=1 << 20))
with open(out, "wb") as f:
    f.write(z.read(member))
PY
  echo "$PHONESKY_SHA  $CACHE/Phonesky.apk.part" | sha256sum -c --quiet - \
    || { echo "ERROR: android-gapps: sha256 mismatch for the extracted ${PHONESKY##*/}" >&2; rm -f "$CACHE/Phonesky.apk.part"; exit 1; }
  mv "$CACHE/Phonesky.apk.part" "$CACHE/Phonesky.apk"
fi
install -Dm0644 "$CACHE/Phonesky.apk" "$OUT/$PHONESKY"

fetch "$KBD_URL" "$KBD_SHA" "$CACHE/keyboard.apk"
install -Dm0644 "$CACHE/keyboard.apk" "$OUT/$KBD_DEST"

all_present || { echo "ERROR: android-gapps: payload incomplete after fetch" >&2; exit 1; }
printf '%s\n' "$HASH" >"$MARKER"
echo "[novadeck] android-gapps: ready -> $OUT ($(du -sh "$OUT" | cut -f1))" >&2
