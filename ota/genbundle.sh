#!/usr/bin/env bash
# novadeck RAUC bundle generator — Phase 4.
#
# Wraps the assembled read-only root (rootfs/assemble-rootfs.sh) into a signed RAUC
# update bundle for OTA. RAUC computes the rootfs hash/size and signs the bundle; the
# device verifies the signature against its keyring before writing the inactive slot.
#
#   RAUC_CERT=cert.pem RAUC_KEY=key.pem ota/genbundle.sh
#
# For local/dev builds, omit the keys to mint an ephemeral self-signed cert (NOT for
# release — production bundles must be signed with the release key, see ota/gen-signing-ca.sh).
#
# Run inside the build image (needs rauc + openssl):
#   docker run --rm -v "$PWD":/src -w /src novadeck-build ota/genbundle.sh
#
# THERE IS NO VERSION ARGUMENT, deliberately, and this is the second version of this script.
# The first took one and defaulted it to today's date. That made the bundle's version and the
# IMAGE's version (/etc/novadeck-release, stamped by rootfs/assemble-rootfs.sh from
# NOVADECK_VERSION) two independent strings — and the OTA client decides whether an update is
# available by comparing exactly those two. Compared across unrelated namespaces, the answer was
# meaningless: a device could be offered its own build forever, or never offered a real one.
#
# So the identity is not passed in, it is READ BACK OUT of the image being wrapped, from the
# sidecar the assembler drops beside it. The bundle cannot name a version its payload does not
# carry, because there is only one place the name comes from. Set NOVADECK_VERSION before building
# the rootfs; by the time the bytes exist, their identity is already decided.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/out"
IMGDIR="$OUT/images"
ROOTFS="$IMGDIR/rootfs.img"
RELEASE="$IMGDIR/rootfs.release"
TEMPLATE="$ROOT/ota/rauc/manifest.raucm.in"

command -v rauc >/dev/null 2>&1 || { echo "rauc not found (run inside novadeck-build)" >&2; exit 1; }
[ -f "$ROOTFS" ]   || { echo "no rootfs image: $ROOTFS (run rootfs/assemble-rootfs.sh first)" >&2; exit 1; }
[ -f "$TEMPLATE" ] || { echo "no manifest template: $TEMPLATE" >&2; exit 1; }
# An out/ tree from before the sidecar existed also lands here. Re-assembling is the fix in both
# cases, and it is the honest one: an image whose identity cannot be established must not be
# published under a name invented at bundling time — that is the bug this file was rewritten for.
[ -f "$RELEASE" ]  || {
  echo "no identity sidecar: $RELEASE" >&2
  echo "(rootfs/assemble-rootfs.sh writes it beside rootfs.img; re-run it — rm $ROOTFS && make rootfs)" >&2
  exit 1
}

field() { sed -n "s/^$1=//p" "$RELEASE" | tail -1; }
IMG_VERSION="$(field NOVADECK_VERSION)"
IMG_BUILD="$(field NOVADECK_BUILD)"
IMG_GIT="$(field NOVADECK_GIT)"
# dev|release. Read back like everything else rather than re-derived from this process's environment
# — genbundle.sh may be wrapping an image assembled by an entirely different invocation, and the
# question "was this built as a test image?" is only answerable by the bytes being wrapped. Empty on
# an image assembled before this field existed, which ota/publish-bundle.sh treats as "not release".
IMG_MODE="$(field NOVADECK_MODE)"

# The identity rule, and it MUST stay in lockstep with identity_of() in rootfs/overlay/usr/bin/
# novadeck-update: the version when the build has a real one, the build timestamp otherwise. A local
# build renders VERSION as the literal `dev`, which every dev image shares — keying on it would make
# two different dev bundles look like the same update, and duplicate detection would suppress the
# second one. Never a bare date (two builds a day collide), never a constant on a dev build.
if [ -n "$IMG_VERSION" ] && [ "$IMG_VERSION" != dev ]; then
  VERSION="$IMG_VERSION"
else
  VERSION="$IMG_BUILD"
fi
# This string becomes a filename on the server and a URL path segment the device fetches, and the
# client rejects any bundle name that is not a bare filename. Refuse to mint one it would refuse.
case "$VERSION" in
  ''|*[!A-Za-z0-9._+-]*)
    echo "the image carries no usable identity (version='$IMG_VERSION' build='$IMG_BUILD')" >&2
    echo "(a version may contain only A-Za-z0-9 . _ + - ; it names the bundle file and its URL)" >&2
    exit 1 ;;
esac

BUNDLE="$IMGDIR/novadeck-${VERSION}.raucb"

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
sed -e "s/@VERSION@/$VERSION/g" \
    -e "s/@BUILD@/$IMG_BUILD/g" \
    -e "s/@GIT@/$IMG_GIT/g" \
    -e "s/@MODE@/$IMG_MODE/g" \
    "$TEMPLATE" >"$content/manifest.raucm"
cp "$ROOTFS" "$content/rootfs.img"

rm -f "$BUNDLE"
echo "[novadeck] bundling v$VERSION (build $IMG_BUILD, git $IMG_GIT, mode ${IMG_MODE:-unknown}) -> ${BUNDLE#"$ROOT"/}"
[ "$IMG_MODE" = release ] || echo "[novadeck] NOTE: mode='${IMG_MODE:-unknown}' — installable, but ota/publish-bundle.sh will refuse to publish it"
# THE SQUASHFS BLOCK SIZE IS THE STREAMING REQUEST SIZE (#65). rauc reads the payload THROUGH the
# squashfs mount -- bundle.c:2950 mounts it on dm-verity, which sits on the nbd stream -- so squashfs
# decides how large one device read may be, and mksquashfs would otherwise default to `-b 128K`.
# One bundle serves both consumers, so both were measured on hardware against the real server
# (2026-08-26):
#
#   installer, raw_copy       32,372 requests -> 4,283;  stream 30m49s -> 14m34s
#   device OTA, adaptive      A->B fetched 59.5 MB in 182 requests, whole update 56s
#
# Overridable so the sizes can be A/B'd without editing this file. Note the single dash: an UNSET
# variable takes the default, an explicitly EMPTY one omits the flag and restores mksquashfs' own.
MKSQUASHFS_ARGS="${NOVADECK_MKSQUASHFS_ARGS--b 1M}"
bundle_args=()
if [ -n "$MKSQUASHFS_ARGS" ]; then
  bundle_args+=(--mksquashfs-args="$MKSQUASHFS_ARGS")
  echo "[novadeck] squashfs args: $MKSQUASHFS_ARGS (see #65)"
fi

rauc bundle --cert="$CERT" --key="$KEY" "${bundle_args[@]}" "$content" "$BUNDLE"

echo "  ok   $(du -h "$BUNDLE" | cut -f1)  $(basename "$BUNDLE")"
echo "Verify with:  rauc info --no-verify ${BUNDLE#"$ROOT"/}"
