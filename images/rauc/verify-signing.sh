#!/usr/bin/env bash
# novadeck RAUC signing self-test — Phase 4b pass 2.
#
#   images/rauc/verify-signing.sh [system.conf]      (default: fs-overlay/etc/rauc/system.conf)
#
# Signs a throwaway bundle and verifies it THROUGH the shipped system.conf. This exists because
# every other check in this repo confirmed the update path was present, and the update path was
# still broken: the release cert carries extendedKeyUsage=codeSigning (ci/gen-signing-ca.sh, so a
# leaked signing key cannot terminate TLS), while RAUC's DEFAULT verification purpose is smimesign,
# which accepts only emailProtection or no EKU. Both halves were individually defensible and the
# pair rejected every bundle with "unsuitable certificate purpose" -- a failure that surfaces on
# the device, at `rauc install`, on hardware with no serial console.
#
# WHAT THIS ASSERTS, and why each half is load-bearing:
#   - the cert profile ci/gen-signing-ca.sh actually mints is one the shipped [keyring] accepts
#     (check-purpose). Minted here from the SAME images/rauc/release.ext rather than by reusing
#     out/pki, so this runs in CI where the release key does not exist.
#   - that the profile actually LANDED on the throwaway cert. An empty or garbled release.ext mints
#     a cert with no extensions at all, and an EKU-less cert satisfies RAUC's default smimesign
#     purpose -- so without this the whole run goes green while asserting nothing.
#   - the bundle format genbundle.sh produces from images/rauc/manifest.raucm.in is one the shipped
#     `bundle-formats=` accepts. Both files say they must agree; nothing checked that they did.
#   - a signature from an UNRELATED CA is rejected. Without this a permissive keyring -- or a
#     verification step that silently no-ops -- would pass every assertion above.
#   - that images/rauc/novadeck-ca.pem is the CA that signed out/pki/release.cert.pem, WHEN that
#     directory exists. It is gitignored and absent in CI, so this half announces itself as skipped
#     rather than passing silently: a keyring committed from a CA whose key you no longer have is
#     a device that will reject every future bundle, and nothing else in the repo would notice.
#
# THIS IS NOT EVIDENCE ABOUT THE DEVICE. It runs the BUILD CONTAINER's rauc against the shipped
# config; the device runs its own (packages/rauc). Both are on the same fixed line today, but they
# are not the same binary, and a 1.14-on-device/1.15-in-container skew is exactly how the verity
# install bug reached hardware. Only an HW `rauc install` is evidence about the device.
#
# What proves this file's own negatives bite: images/test-verify-signing.sh, which feeds it
# deliberately broken configs and profiles and requires it to go RED for each one.
#
# Needs rauc + openssl, so it runs inside novadeck-build:
#   docker run --rm -v "$PWD":/src -w /src novadeck-build images/rauc/verify-signing.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CONF="${1:-$ROOT/fs-overlay/etc/rauc/system.conf}"
TEMPLATE="$ROOT/images/rauc/manifest.raucm.in"

# Test seams, as novadeck-bootctl and post-install.sh document their own. RELEASE_EXT is THE cert
# profile, shared with ci/gen-signing-ca.sh so neither can drift; PKIDIR matches that script's.
RELEASE_EXT="${RELEASE_EXT:-$ROOT/images/rauc/release.ext}"
KEYRING="${KEYRING:-$ROOT/images/rauc/novadeck-ca.pem}"
PKIDIR="${PKIDIR:-$ROOT/out/pki}"

command -v rauc    >/dev/null 2>&1 || { echo "rauc not found (run inside novadeck-build)" >&2; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo "openssl not found" >&2; exit 1; }
[ -f "$CONF" ]     || { echo "no system.conf: $CONF" >&2; exit 1; }
[ -f "$TEMPLATE" ] || { echo "no manifest template: $TEMPLATE" >&2; exit 1; }
[ -f "$RELEASE_EXT" ] || { echo "no cert profile: $RELEASE_EXT" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
umask 077

# Two independent CAs: one signs the bundle, the other is the keyring in the negative case. RSA-2048
# and short lifetimes because this material exists for the length of one process.
mint_ca() { # <prefix>
  openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 1 \
    -keyout "$work/$1-ca.key" -out "$work/$1-ca.pem" \
    -subj "/O=novadeck-selftest/CN=$1 CA" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" >/dev/null 2>&1
}

# The signer is minted from the SHIPPED profile, not from a copy of it. That is the whole point:
# ci/gen-signing-ca.sh mints the real release cert from this same file, so there is no pair of
# extension lists that can drift apart and leave this passing for a cert we do not ship.
mint_signer() { # <prefix>
  openssl req -newkey rsa:2048 -nodes -sha256 \
    -keyout "$work/$1.key" -out "$work/$1.csr" \
    -subj "/O=novadeck-selftest/CN=$1 release" >/dev/null 2>&1
  openssl x509 -req -in "$work/$1.csr" -CA "$work/$1-ca.pem" -CAkey "$work/$1-ca.key" \
    -CAcreateserial -days 1 -sha256 -extfile "$RELEASE_EXT" -out "$work/$1.pem" >/dev/null 2>&1
}

mint_ca trusted;  mint_signer trusted
mint_ca untrusted; mint_signer untrusted

# The profile has to have LANDED, not merely been passed. openssl x509 -req with an empty or
# unparseable -extfile mints a cert with no extensions and says nothing about it, and an EKU-less
# cert is accepted by RAUC's default smimesign purpose -- so that failure would take this entire
# self-test green while it asserted nothing. Assert the three properties by their meaning: not a
# CA, signs, and signs CODE only. Changing release.ext to something else must fail here and be
# reconciled with check-purpose= in system.conf, which is the pairing this file exists to protect.
ext="$(openssl x509 -in "$work/trusted.pem" -noout -ext basicConstraints,keyUsage,extendedKeyUsage 2>/dev/null)"
for want in "CA:FALSE" "Digital Signature" "Code Signing"; do
  case "$ext" in
    *"$want"*) ;;
    *) echo "  FAIL  the throwaway cert has no '$want' -- ${RELEASE_EXT#"$ROOT"/} did not apply" >&2
       echo "        every assertion below would then be about a cert profile we do not ship." >&2
       printf '%s\n' "${ext:-<no extensions at all>}" | sed 's/^/        /' >&2
       exit 1 ;;
  esac
done
echo "[novadeck] cert profile ${RELEASE_EXT#"$ROOT"/}: CA:FALSE + digitalSignature + codeSigning"

# A 1 MiB payload: this exercises the signing and format path, which does not care what the image
# is. Using the real 6.4G rootfs would make the check too slow to leave in the build. It must be
# INCOMPRESSIBLE -- a verity bundle wraps the payload in squashfs, and a megabyte of zeros packs
# down to exactly 4096 bytes, which rauc rejects ("squashfs size must be larger than 4096 bytes").
content="$work/content"; mkdir -p "$content"
sed -e "s/@VERSION@/0-selftest/g" "$TEMPLATE" >"$content/manifest.raucm"
dd if=/dev/urandom of="$content/rootfs.img" bs=1M count=1 status=none

# Keep rauc's stderr: bundling failures here are setup bugs in this script, and swallowing them
# makes the whole self-test exit silently with no indication of what broke.
if ! out="$(rauc bundle --cert="$work/trusted.pem" --key="$work/trusted.key" \
              "$content" "$work/selftest.raucb" 2>&1)"; then
  echo "  ERROR could not build the self-test bundle — this is a bug in $0, not in $CONF" >&2
  printf '%s\n' "$out" | sed 's/^/        /' >&2
  exit 1
fi

# --conf is what makes this a test of the SHIPPED file: check-purpose and bundle-formats are read
# from it. --keyring overrides only [keyring] path=, which names an absolute on-device location
# (/etc/rauc/keyring.pem) that does not exist here and holds the real CA when it does.
verify() { # <keyring> -> rauc's own stderr on failure
  rauc info --conf="$CONF" --keyring="$1" "$work/selftest.raucb" 2>&1
}

echo "[novadeck] rauc signing self-test against ${CONF#"$ROOT"/}"

if ! out="$(verify "$work/trusted-ca.pem")"; then
  echo "  FAIL  a bundle signed by a codeSigning cert was REJECTED by the shipped system.conf" >&2
  echo "        every OTA update would fail on the device, at install time." >&2
  echo "        if this says 'unsuitable certificate purpose', [keyring] needs check-purpose=codesign" >&2
  printf '%s\n' "$out" | sed 's/^/        /' >&2
  exit 1
fi
printf '  ok    codeSigning cert accepted  (%s)\n' \
  "$(printf '%s\n' "$out" | grep -m1 '^Bundle Format:' | tr -s ' ')"

if verify "$work/untrusted-ca.pem" >/dev/null 2>&1; then
  echo "  FAIL  a bundle signed by an UNRELATED CA was ACCEPTED — the keyring verifies nothing" >&2
  exit 1
fi
echo "  ok    unrelated CA rejected"

# The committed keyring against the local PKI. Everything above is self-consistent by construction
# — it mints both ends — so none of it can notice that images/rauc/novadeck-ca.pem came from a CA
# whose key we no longer have. That mistake ships a device which rejects every bundle we will ever
# sign, and the only cure is a reflash. Skipped loudly rather than silently in CI, where the key is
# absent by design: a check that quietly does nothing is the thing this whole file argues against.
if [ -f "$PKIDIR/release.cert.pem" ] && [ -f "$KEYRING" ]; then
  if openssl verify -CAfile "$KEYRING" "$PKIDIR/release.cert.pem" >/dev/null 2>&1; then
    echo "  ok    committed keyring signed ${PKIDIR#"$ROOT"/}/release.cert.pem"
  else
    echo "  FAIL  ${KEYRING#"$ROOT"/} is NOT the CA behind ${PKIDIR#"$ROOT"/}/release.cert.pem" >&2
    echo "        a device flashed with this keyring would reject every bundle you can sign." >&2
    echo "        re-run ci/gen-signing-ca.sh, or commit the keyring that matches your PKI." >&2
    exit 1
  fi
else
  echo "  skip  no local PKI at ${PKIDIR#"$ROOT"/} — keyring/signing-key agreement NOT checked"
fi
