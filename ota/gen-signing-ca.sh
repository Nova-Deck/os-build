#!/usr/bin/env bash
# novadeck RAUC signing CA — Phase 4b.
#
# Mints the two-level PKI that signs OTA bundles:
#
#   root CA  (ca.cert.pem / ca.key.pem)          20y, offline, signs nothing but certs
#     └── release cert (release.cert.pem/.key)    ~2y, signs bundles, lives in CI
#
# A two-level CA rather than one self-signed key so the SIGNING key can be rotated -- or
# revoked -- without reflashing every device. The device trusts the CA certificate, not the
# signing certificate: `rauc install` verifies the bundle's signature chains up to the keyring,
# so a new release cert signed by the same CA is accepted by hardware already in the field.
# A single self-signed key would make key rotation a reflash, which on this device means a
# screwdriver and an SD card reader.
#
# WHAT ENTERS THE REPO: exactly one file, ota/rauc/novadeck-ca.pem -- the CA CERTIFICATE,
# which is public by construction (it is shipped on every device as /etc/rauc/keyring.pem).
# Every private key stays under $PKIDIR, which defaults inside out/ precisely because
# .gitignore already excludes /out/ wholesale. Nothing here should ever need `git add -f`.
#
#   ota/gen-signing-ca.sh                 # mint into out/pki/, install the keyring
#   PKIDIR=~/novadeck-pki ota/gen-signing-ca.sh
#
# Then sign a bundle with:
#   RAUC_CERT=out/pki/release.cert.pem RAUC_KEY=out/pki/release.key.pem make bundle
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKIDIR="${PKIDIR:-$ROOT/out/pki}"
KEYRING="$ROOT/ota/rauc/novadeck-ca.pem"
RELEASE_EXT="$ROOT/ota/rauc/release.ext"   # shared with ota/rauc/verify-signing.sh

CA_DAYS="${CA_DAYS:-7300}"        # 20 years: the device's trust root, replaced only by reflash
REL_DAYS="${REL_DAYS:-800}"       # ~2 years: rotated under the CA without touching devices
ORG="${ORG:-novadeck}"

command -v openssl >/dev/null 2>&1 || { echo "openssl not found" >&2; exit 1; }
# An absent or empty profile does not fail openssl loudly enough: it mints a cert with NO
# extensions, i.e. no CA:FALSE and no EKU, which is the one outcome this file exists to prevent.
[ -s "$RELEASE_EXT" ] || { echo "missing or empty cert profile: $RELEASE_EXT" >&2; exit 1; }

mkdir -p "$PKIDIR"
cd "$PKIDIR"

# Never silently regenerate a CA. Devices in the field trust the certificate derived from this
# key; replacing it makes every one of them reject every future bundle, with no error message
# that points back here. Deleting it has to be a deliberate act.
if [ -e ca.key.pem ]; then
  echo "refusing to overwrite an existing CA: $PKIDIR/ca.key.pem" >&2
  echo "  devices already trust the certificate derived from this key. To mint a NEW CA," >&2
  echo "  move the directory aside first:  mv $PKIDIR $PKIDIR.old" >&2
  exit 1
fi

# Private key material must never land anywhere git might pick it up. $PKIDIR is settable, so
# assert rather than assume: everything under $ROOT other than out/ is a tracked source tree.
case "$PKIDIR/" in
  "$ROOT"/out/*) ;;
  "$ROOT"/*)
    echo "refusing to write private keys inside the repo: $PKIDIR" >&2
    echo "  use out/pki (gitignored) or a path outside $ROOT" >&2
    exit 1 ;;
esac

umask 077

echo "[novadeck] root CA (${CA_DAYS}d, RSA-4096)"
openssl req -x509 -newkey rsa:4096 -nodes -sha256 -days "$CA_DAYS" \
  -keyout ca.key.pem -out ca.cert.pem \
  -subj "/O=$ORG/CN=$ORG OTA root CA" \
  -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" >/dev/null 2>&1

echo "[novadeck] release signing cert (${REL_DAYS}d, RSA-4096)"
openssl req -newkey rsa:4096 -nodes -sha256 \
  -keyout release.key.pem -out release.csr.pem \
  -subj "/O=$ORG/CN=$ORG OTA release" >/dev/null 2>&1

# The cert profile lives in ota/rauc/release.ext and is read, not restated: this script MINTS
# the release cert and ota/rauc/verify-signing.sh proves the shipped system.conf accepts one, so
# a copy in either place is a profile that can drift out from under the other.
# index.txt/serial are kept so a CRL can be issued later against this same CA. `openssl ca`
# needs them to exist; creating them now avoids having to reconstruct the CA's issuance state
# at the moment you actually need to revoke something.
: >index.txt
echo 01 >serial

openssl x509 -req -in release.csr.pem -CA ca.cert.pem -CAkey ca.key.pem \
  -CAcreateserial -days "$REL_DAYS" -sha256 -extfile "$RELEASE_EXT" \
  -out release.cert.pem >/dev/null 2>&1

rm -f release.csr.pem

chmod 0600 ca.key.pem release.key.pem
chmod 0644 ca.cert.pem release.cert.pem

openssl verify -CAfile ca.cert.pem release.cert.pem >/dev/null || {
  echo "the release cert does not verify against the CA -- refusing to install the keyring" >&2
  exit 1
}

install -m0644 ca.cert.pem "$KEYRING"

fp="$(openssl x509 -in ca.cert.pem -noout -fingerprint -sha256 | cut -d= -f2)"
cat <<EOF

  ok   CA          $PKIDIR/ca.cert.pem
  ok   signing     $PKIDIR/release.cert.pem
  ok   keyring     ${KEYRING#"$ROOT"/}   (commit this -- it is the ONLY file that may be)

  CA SHA-256  $fp

  Private keys are in $PKIDIR and must stay there:
    ca.key.pem       offline. Back it up somewhere that is not this machine.
    release.key.pem  the CI secret. Sign bundles with:

      RAUC_CERT=${PKIDIR#"$ROOT"/}/release.cert.pem \\
      RAUC_KEY=${PKIDIR#"$ROOT"/}/release.key.pem make bundle
EOF
