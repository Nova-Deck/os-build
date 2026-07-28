#!/usr/bin/env bash
# Offline test for images/rauc/verify-signing.sh — the RAUC signing self-test.
#
#   docker run --rm -v "$PWD":/src -w /src novadeck-build images/test-verify-signing.sh
#   make test-signing
#
# WHY A TEST FOR A TEST. verify-signing.sh is a check, and the failure mode of a check is not
# "it breaks" — it is "it stays green while asserting nothing". TODO.md called that out as worse
# than having no check at all, and the file had two ways to get there: it carried a hand-copy of
# the release cert's extensions (drift → passing for a profile we do not ship), and nothing
# confirmed those extensions ever reached the throwaway cert (an empty profile mints an EKU-less
# cert, which RAUC's DEFAULT smimesign purpose happily accepts). Both are now closed —
# images/rauc/release.ext is read by ci/gen-signing-ca.sh and verify-signing.sh alike, and the
# minted profile is asserted — and this file is what keeps them closed.
#
# SO EVERY CASE HERE IS A NEGATIVE. It feeds verify-signing.sh a deliberately broken config or
# profile and requires it to go RED, plus one green case against the shipped files. A self-test
# that cannot be made to fail is indistinguishable from one that always passes, and the difference
# only shows up on hardware, at `rauc install`, on a board with no serial console.
#
# It runs the SHIPPED verify-signing.sh through its documented seams (CONF as argv[1], RELEASE_EXT,
# KEYRING, PKIDIR). Nothing is stubbed: real openssl, real rauc, real bundles. Needs the build
# container for rauc, which is why this one is not in `make test` with the other three suites.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VS="$ROOT/images/rauc/verify-signing.sh"
CONF="$ROOT/fs-overlay/etc/rauc/system.conf"
EXT="$ROOT/images/rauc/release.ext"
CA="$ROOT/ci/gen-signing-ca.sh"
[ -f "$VS" ] || { echo "no verify-signing.sh: $VS" >&2; exit 1; }
command -v rauc >/dev/null 2>&1 || { echo "rauc not found — run inside novadeck-build" >&2; exit 1; }

PASS=0; FAIL=0; CASE=""; SB=""; OUT=""; RC=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }

t() { CASE="$1"; SB="$(mktemp -d)"; }
done_() { rm -rf "$SB"; }

# Run the SHIPPED self-test. $1 is the system.conf to test; the seams default to the shipped files
# unless the case overrode them before calling.
# The PKI lives outside the repo (see the Makefile's PKIDIR block), so an ambient PKIDIR is
# honoured and out/pki is only the fallback. Without either, the keyring case announces itself as
# skipped rather than quietly passing — which is the behaviour one of the cases below asserts.
PKI="${PKIDIR:-$ROOT/out/pki}"

vs() {
  OUT=$(RELEASE_EXT="${USE_EXT:-$EXT}" KEYRING="${USE_KEYRING:-$ROOT/images/rauc/novadeck-ca.pem}" \
        PKIDIR="${USE_PKI:-$PKI}" bash "$VS" "$1" 2>&1)
  RC=$?
  USE_EXT=""; USE_KEYRING=""; USE_PKI=""
  return 0
}
USE_EXT=""; USE_KEYRING=""; USE_PKI=""

# A copy of the shipped system.conf with one line rewritten — the only honest way to test a check
# is to break exactly the thing it claims to catch, one thing at a time.
conf_without() { sed "/$1/d" "$CONF" >"$SB/system.conf"; printf '%s' "$SB/system.conf"; }
conf_sed()     { sed "$1"      "$CONF" >"$SB/system.conf"; printf '%s' "$SB/system.conf"; }

expect_rc()  { [ "$RC" = "$1" ] && ok "exit=$1" || bad "exit: expected $1, got $RC; output: $OUT"; }
expect_has() { case "$OUT" in *"$1"*) ok "says '$1'" ;; *) bad "expected '$1'; output: $OUT" ;; esac; }
expect_not() { case "$OUT" in *"$1"*) bad "must not say '$1'; output: $OUT" ;; *) ok "silent on '$1'" ;; esac; }

echo "== the shipped configuration passes =="

t "the-shipped-system-conf-is-accepted"
vs "$CONF"
expect_rc 0
expect_has "codeSigning cert accepted"
expect_has "unrelated CA rejected"
expect_has "CA:FALSE + digitalSignature + codeSigning"
done_

echo "== and every negative it claims actually bites =="

t "a-conf-without-check-purpose-fails"
# THE REGRESSION. This is the exact pairing that shipped broken: a codeSigning release cert against
# RAUC's default smimesign purpose rejects every bundle, on the device, at install time.
vs "$(conf_without '^check-purpose=')"
expect_rc 1
expect_has "was REJECTED by the shipped system.conf"
expect_has "check-purpose=codesign"
done_

t "a-conf-with-the-wrong-check-purpose-fails"
vs "$(conf_sed 's/^check-purpose=.*/check-purpose=smimesign/')"
expect_rc 1
expect_has "was REJECTED"
done_

t "a-conf-whose-bundle-format-disagrees-with-the-manifest-fails"
# system.conf and images/rauc/manifest.raucm.in each say they must agree with the other. This is
# what makes that more than a comment.
vs "$(conf_sed 's/^bundle-formats=.*/bundle-formats=plain/')"
expect_rc 1
expect_has "was REJECTED"
done_

t "an-empty-cert-profile-fails-instead-of-passing"
# The subtle one, and the reason the profile assertion exists: openssl mints a cert with NO
# extensions and reports success, and an EKU-less cert satisfies smimesign — so the old file would
# have gone green here while testing nothing at all.
: >"$SB/empty.ext"
USE_EXT="$SB/empty.ext"
vs "$CONF"
expect_rc 1
expect_has "did not apply"
expect_not "codeSigning cert accepted"
done_

t "a-profile-without-codeSigning-fails"
# Drift in the other direction: a profile that is no longer what check-purpose=codesign expects.
# The pair has to move together, so one moving alone must be caught.
printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,emailProtection\n' >"$SB/email.ext"
USE_EXT="$SB/email.ext"
vs "$CONF"
expect_rc 1
done_

t "a-missing-cert-profile-is-a-clean-failure"
USE_EXT="$SB/does-not-exist.ext"
vs "$CONF"
expect_rc 1
expect_has "no cert profile"
done_

echo "== the committed pair, and the key behind it =="

t "a-keyring-from-an-unrelated-ca-is-caught"
# The one thing the rest of the file cannot see, because it mints both ends of everything else: a
# committed keyring that did not sign the committed release cert ships a device that rejects every
# bundle we can ever sign, curable only by reflash. Both files are public, so this needs no secret
# and runs on every CI push — which is the whole reason release.cert.pem is committed.
openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 1 -keyout "$SB/other.key" \
  -out "$SB/other-ca.pem" -subj "/O=novadeck-selftest/CN=someone elses CA" \
  -addext "basicConstraints=critical,CA:TRUE,pathlen:0" >/dev/null 2>&1
USE_KEYRING="$SB/other-ca.pem"
vs "$CONF"
expect_rc 1
expect_has "is NOT the CA behind"
done_

t "a-signing-key-that-does-not-match-the-committed-cert-is-caught"
# The CI failure mode, where the key arrives through a secret store and the cert through git: a
# stale or truncated secret produces bundles no device accepts, and nothing downstream says why.
mkdir -p "$SB/pki"
openssl genrsa -out "$SB/pki/release.key.pem" 2048 >/dev/null 2>&1
USE_PKI="$SB/pki"
vs "$CONF"
expect_rc 1
expect_has "does not match"
expect_not "-----BEGIN"          # a key check must never print key material
done_

t "a-missing-signing-key-is-announced-not-silently-skipped"
# The normal CI shape: no private key, so the public half still runs and the private half says so.
USE_PKI="$SB/no-such-pki"
vs "$CONF"
expect_rc 0
expect_has "key/cert agreement NOT checked"
expect_has "committed keyring is the CA behind"
done_

t "the-real-signing-key-matches-the-committed-cert"
# Only reachable where the PKI is mounted (PKIDIR=... make test-signing). This is what would catch
# a release cert committed from a different ci/gen-signing-ca.sh run than the key CI signs with.
if [ -f "$PKI/release.key.pem" ]; then
  vs "$CONF"
  expect_rc 0
  expect_has "signing key matches"
else
  ok "no signing key here — correctly not asserted (this is the CI shape)"
fi
done_

echo "== the profile has exactly one definition =="

# Structural, in the shape test-bootctl.sh's `backend-is-complete` uses: the drift this all guards
# against was two hand-copies of three lines, so assert there is still only one copy. A future
# heredoc in either script would restore the original bug silently.
t "both-scripts-read-the-shared-profile"
grep -q 'RELEASE_EXT' "$CA" && ok "ci/gen-signing-ca.sh reads RELEASE_EXT" \
  || bad "ci/gen-signing-ca.sh no longer reads the shared profile"
grep -q 'RELEASE_EXT' "$VS" && ok "verify-signing.sh reads RELEASE_EXT" \
  || bad "verify-signing.sh no longer reads the shared profile"
for f in "$CA" "$VS"; do
  if grep -q '^extendedKeyUsage=' "$f"; then
    bad "${f#"$ROOT"/} restates extendedKeyUsage= -- that is the drift this file exists to prevent"
  else
    ok "${f#"$ROOT"/} does not restate the profile"
  fi
done
grep -q '^extendedKeyUsage=critical,codeSigning' "$EXT" \
  && ok "the profile itself still says codeSigning" || bad "images/rauc/release.ext lost its EKU"
done_

t "no-private-key-is-committed-under-images-rauc"
# .gitignore blanket-excludes *.pem with exactly two negations, both public certificates. This is
# what polices that exception: widening a rule whose job is "no key material in git" has to be
# enforced by something other than care. Scans what is actually THERE, so a third negation added
# for a file that turns out to hold a key fails here.
for f in "$ROOT"/images/rauc/*.pem; do
  [ -f "$f" ] || continue
  if grep -q 'PRIVATE KEY' "$f"; then
    bad "${f#"$ROOT"/} contains PRIVATE KEY -- it must never be committed"
  else
    ok "${f#"$ROOT"/} is public material only"
  fi
done
done_

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ] || exit 1
