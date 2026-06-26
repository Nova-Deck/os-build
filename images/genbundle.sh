#!/usr/bin/env bash
# novadeck RAUC bundle generator — Phase 4.
#
# Wraps the assembled read-only root (images/assemble-rootfs.sh) into a signed RAUC
# update bundle for OTA. RAUC computes the rootfs hash/size and signs the bundle; the
# device verifies the signature against its keyring before writing the inactive slot.
#
#   RAUC_CERT=cert.pem RAUC_KEY=key.pem images/genbundle.sh [version]
#
# For local/dev builds, omit the keys to mint an ephemeral self-signed cert (NOT for
# release — production bundles must be signed with the release key, see ci/).
#
# Run inside the build image (needs rauc + openssl):
#   docker run --rm -v "$PWD":/src -w /src novadeck-build images/genbundle.sh
set -euo pipefail

VERSION="${1:-$(date -u +%Y%m%d)}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/out"
IMGDIR="$OUT/images"
ROOTFS="$IMGDIR/rootfs.img"
TEMPLATE="$ROOT/images/rauc/manifest.raucm.in"
BUNDLE="$IMGDIR/novadeck-${VERSION}.raucb"

command -v rauc >/dev/null 2>&1 || { echo "rauc not found (run inside novadeck-build)" >&2; exit 1; }
[ -f "$ROOTFS" ]   || { echo "no rootfs image: $ROOTFS (run images/assemble-rootfs.sh first)" >&2; exit 1; }
[ -f "$TEMPLATE" ] || { echo "no manifest template: $TEMPLATE" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

CERT="${RAUC_CERT:-}"; KEY="${RAUC_KEY:-}"
if [ -z "$CERT" ] || [ -z "$KEY" ]; then
  echo "[novadeck] no RAUC_CERT/RAUC_KEY — minting an ephemeral dev cert (NOT for release)"
  CERT="$work/dev-cert.pem"; KEY="$work/dev-key.pem"
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$KEY" -out "$CERT" \
    -days 7 -subj "/O=novadeck/CN=novadeck-dev" >/dev/null 2>&1
fi

# Bundle content dir: manifest (placeholders filled) + the rootfs image.
content="$work/content"; mkdir -p "$content"
sed -e "s/@VERSION@/$VERSION/g" "$TEMPLATE" >"$content/manifest.raucm"
cp "$ROOTFS" "$content/rootfs.img"

rm -f "$BUNDLE"
echo "[novadeck] bundling v$VERSION -> ${BUNDLE#"$ROOT"/}"
rauc bundle --cert="$CERT" --key="$KEY" "$content" "$BUNDLE"

echo "  ok   $(du -h "$BUNDLE" | cut -f1)  $(basename "$BUNDLE")"
echo "Verify with:  rauc info --no-verify ${BUNDLE#"$ROOT"/}"
