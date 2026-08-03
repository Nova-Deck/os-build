#!/usr/bin/env bash
# novadeck OTA bundle publisher — Phase 3. Puts a signed RAUC bundle on the update server and flips
# the channel pointer at it.
#
#   ota/publish-bundle.sh out/images/novadeck-0.2.0.raucb [channel]
#
# Shaped after images/publish-card.sh — credentials from the environment only, an explicit KEEP
# retention, and verification at the PUBLIC url rather than trust in the upload — but over SSH/rsync
# rather than rclone. This is not S3: it is a rented Ubuntu box serving a directory, so the transport
# is the one that box already has, and there is no write surface exposed to the internet at all.
#
# THE SIGNATURE GATE RUNS FIRST, BEFORE A BYTE MOVES, and it has no override. A bundle is accepted
# only if it verifies against the CA that is baked into every device's keyring
# (images/rauc/novadeck-ca.pem, installed as /etc/rauc/keyring.pem by images/assemble-rootfs.sh).
# Publishing an unsigned or dev-cert bundle would not be a near miss: `make bundle` without PKIDIR
# mints an EPHEMERAL 7-day cert that is deleted with its tempdir, so the result is a ~4G download
# every device in the field throws away at the last step, over Wi-Fi, having already asked the user
# to say yes. There is deliberately no --force.
#
# THE VERIFICATION INCANTATION IS NOT OBVIOUS and the obvious one is wrong:
#
#   rauc info --conf=<system.conf> --keyring=<ca.pem> <bundle>     <- correct
#   rauc info --keyring=<ca.pem> <bundle>                          <- FALSE RED
#
# --conf is what supplies check-purpose=codesign. Without it rauc applies its default `smimesign`
# purpose, which accepts only emailProtection or no EKU at all, and rejects our codeSigning release
# cert with "unsuitable certificate purpose" — a bundle that every device would happily install.
# --keyring overrides only [keyring] path=, which names /etc/rauc/keyring.pem: an on-device absolute
# path that does not exist here. Same pair as images/rauc/verify-signing.sh and docs/RUNBOOK.md.
#
# ORDER OF OPERATIONS IS THE WHOLE DESIGN. Bytes first under a .part name, renamed into place, and
# latest.json flipped LAST. A device that checks mid-publish must see either the old release or the
# new one, never a pointer at a URL that 404s or at a file still being written.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

HOST="${NOVADECK_OTA_HOST:-updates.novadeck.cloud-ip.cc}"
USER_="${NOVADECK_OTA_USER:-ubuntu}"
SSH_KEY="${NOVADECK_OTA_SSH_KEY:-}"
DOCROOT="${NOVADECK_OTA_DOCROOT:-/srv/novadeck-ota}"
BASE_URL="${NOVADECK_OTA_URL:-https://$HOST}"
# Retention. The instance has ~94G and a bundle is ~4G, so unlike the card bucket (KEEP=1, where the
# free tier was the constraint) there is room to keep the previous releases: if a published update
# turns out bad, re-pointing latest.json at the one before it is the fastest fleet-wide fix there is,
# and it only works if those bytes are still on the server.
KEEP="${NOVADECK_OTA_KEEP:-3}"

BUNDLE="${1:-}"
CHANNEL="${2:-${NOVADECK_OTA_CHANNEL:-stable}}"

log()  { printf '[publish] %s\n' "$*" >&2; }
die()  { printf '[publish] %s\n' "$*" >&2; exit 1; }

[ -n "$BUNDLE" ] || die "usage: $0 <bundle.raucb> [channel]"
[ -f "$BUNDLE" ] || die "no such bundle: $BUNDLE"
case "$CHANNEL" in
  ''|*[!A-Za-z0-9._-]*) die "channel '$CHANNEL' has characters that do not belong in a URL path" ;;
esac
case "$KEEP" in
  ''|*[!0-9]*) die "NOVADECK_OTA_KEEP must be a whole number, got '$KEEP'" ;;
esac

BUNDLE_ABS="$(cd "$(dirname "$BUNDLE")" && pwd)/$(basename "$BUNDLE")"
NAME="$(basename "$BUNDLE_ABS")"

# --- ssh/rsync plumbing --------------------------------------------------------------------------
# BatchMode so a missing key fails immediately instead of hanging on a password prompt in CI.
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)
[ -n "$SSH_KEY" ] && SSH_OPTS+=(-i "$SSH_KEY")
remote() { ssh "${SSH_OPTS[@]}" "$USER_@$HOST" "$@"; }

# --- 1. the signature gate -----------------------------------------------------------------------
CONF_REL="fs-overlay/etc/rauc/system.conf"
KEYRING_REL="images/rauc/novadeck-ca.pem"
[ -f "$ROOT/$CONF_REL" ]    || die "no $CONF_REL — run this from the novadeck tree"
[ -f "$ROOT/$KEYRING_REL" ] || die "no $KEYRING_REL — run this from the novadeck tree"

# rauc is not a host tool here (it is version-pinned in build/Dockerfile precisely so the bundle
# WRITER and the device's installer cannot drift), so fall back to the build container.
#
# NOTE THE `-c`: novadeck-build's ENTRYPOINT is /bin/bash, so `docker run <img> rauc ...` runs
# `bash rauc ...` and bash tries to SOURCE the binary — "cannot execute binary file", which reads
# like a broken image and is not. Everything else in the repo passes it shell scripts, so this is the
# first caller that has to know.
rauc_info() { # <extra rauc args...>  — the bundle path is resolved per backend, not by the caller
  if command -v rauc >/dev/null 2>&1; then
    ( cd "$ROOT" && rauc info --conf="$CONF_REL" --keyring="$KEYRING_REL" "$@" "$BUNDLE_ABS" )
  else
    command -v docker >/dev/null 2>&1 || die "neither rauc nor docker is available; cannot verify the signature, so nothing will be published"
    # The bundle's directory is mounted read-only at /bundle so a path outside the repo still works.
    docker run --rm -v "$ROOT":/src -v "$(dirname "$BUNDLE_ABS")":/bundle:ro -w /src novadeck-build \
      -c "rauc info --conf=$CONF_REL --keyring=$KEYRING_REL $* /bundle/$NAME"
  fi
}

log "verifying $NAME against the device keyring ($KEYRING_REL, through $CONF_REL)"
if ! chain="$(rauc_info 2>&1)"; then
  printf '%s\n' "$chain" | sed 's/^/         /' >&2
  die "REFUSED: $NAME does not verify against the keyring every device carries.
  A bundle that fails here fails on the device too, after a multi-gigabyte download the user agreed
  to. If this says 'unsuitable certificate purpose' the --conf above was not applied; if it says
  'signature verification failed' the bundle was signed with a dev cert — rebuild with
  PKIDIR=\$HOME/novadeck-pki make bundle."
fi
log "ok: $(printf '%s\n' "$chain" | grep -m1 'Verified.*signature' | sed 's/^ *//')"

# --- 2. identity, read out of the bundle ----------------------------------------------------------
# Not from the caller, not from the build tree, not from the filename. Same principle as Phase 2:
# genbundle.sh reads the version out of the image it wraps, and this reads it back out of the bundle
# that image is inside. The name a release is published under can then never be one it does not
# carry. `shell` output rather than json so this needs no jq, and so [meta.novadeck] fields surface
# through the same parser if the bundle carries them.
meta="$(rauc_info --output-format=shell 2>/dev/null)" || die "could not read the bundle manifest"
mf() { printf '%s\n' "$meta" | sed -n "s/^$1='\(.*\)'$/\1/p" | tail -1; }

VERSION="$(mf RAUC_MF_VERSION)"
COMPATIBLE="$(mf RAUC_MF_COMPATIBLE)"
# Decorative, and absent from bundles built before the Phase 2 manifest gained [meta.novadeck]. The
# client identifies an update by `version` alone (genbundle.sh guarantees it is never empty and never
# the literal `dev`), so these two are for a human reading latest.json, not for the update logic.
BUILD="$(mf RAUC_META_NOVADECK_BUILD)"
GIT="$(mf RAUC_META_NOVADECK_GIT)"
MODE="$(mf RAUC_META_NOVADECK_MODE)"

[ "$COMPATIBLE" = novadeck ] || die "bundle compatible is '$COMPATIBLE', not 'novadeck' — no device would install it"

# THE SECOND GATE, and the signature does not imply it. A dev image carries Wi-Fi credentials and an
# authorized_keys, and `NOVADECK_DEV=1 PKIDIR=~/novadeck-pki make bundle` — the normal, correct way
# to build a bundle for testing on your own hardware — produces one signed with the REAL release key.
# To a signature check that is indistinguishable from a shippable release, because the signature is
# over the bytes and says nothing about their provenance. Only the mode stamp the payload carries can
# tell them apart.
#
# Empty is REFUSED, not waved through: an image assembled before this field existed cannot answer the
# question, and "cannot answer" has to mean no. Re-assemble it — the answer is a property of the
# build, so there is nothing to add after the fact.
case "$MODE" in
  release) ;;
  dev) die "REFUSED: this bundle's payload was built as a DEV image (mode=dev).
  A dev image carries Wi-Fi credentials and an authorized_keys, and it is signed with the same
  release key as a shippable one, so nothing downstream would catch this. Build without
  NOVADECK_DEV=1 — note that release builds are CI's job (see .github/workflows/image.yml)." ;;
  *) die "REFUSED: this bundle does not say how it was built (mode='${MODE:-<absent>}').
  Bundles assembled before the mode stamp existed cannot answer it, and 'cannot answer' means no.
  Re-assemble the rootfs and re-bundle; the answer is a property of the build, not metadata that
  can be added afterwards." ;;
esac
case "$VERSION" in
  ''|*[!A-Za-z0-9._+-]*) die "bundle version '$VERSION' is not usable as a filename or URL segment" ;;
esac
# The client builds the download URL from latest.json's `bundle` field and nothing else, so the file
# on the server has to be named for the version inside it. genbundle.sh already names it this way;
# this catches a hand-renamed file, which would otherwise publish a pointer at a 404.
[ "$NAME" = "novadeck-$VERSION.raucb" ] || die "filename/version mismatch: '$NAME' should be 'novadeck-$VERSION.raucb'
  The version comes from inside the bundle; renaming the file does not change it."

SIZE="$(stat -c %s "$BUNDLE_ABS")"
log "computing sha256 over $((SIZE / 1024 / 1024)) MiB"
SHA="$(sha256sum "$BUNDLE_ABS" | cut -d' ' -f1)"
log "publishing v$VERSION (mode $MODE${BUILD:+, build $BUILD}${GIT:+, git $GIT}) to $BASE_URL/$CHANNEL/"

# --- 3. upload -------------------------------------------------------------------------------------
DEST="$DOCROOT/$CHANNEL"
remote "mkdir -p '$DEST'" || die "cannot create $DEST on $HOST (is the docroot owned by $USER_? run ota/setup-server.sh)"

# Space on the SERVER, before the transfer rather than after it. The mirror of the client's own
# room_for() check, and for the same reason: finding out at the end costs the whole transfer.
avail="$(remote "df -kP '$DEST' | awk 'NR==2{print \$4}'")"
need=$(( (SIZE / 1024) + 524288 ))
[ "${avail:-0}" -ge "$need" ] || die "not enough room on $HOST: need $((need / 1024)) MiB at $DEST, have $((avail / 1024)) MiB
  Lower NOVADECK_OTA_KEEP (currently $KEEP) and re-run, or prune by hand."

# .part, then rename. rsync --partial --inplace so an interrupted 4G transfer to Frankfurt resumes
# where it stopped; the rename is within one filesystem, so it is atomic and a device can never see a
# half-written file under the final name.
log "uploading $NAME (resumable)"
rsync -e "ssh ${SSH_OPTS[*]}" --partial --inplace --progress \
  "$BUNDLE_ABS" "$USER_@$HOST:$DEST/$NAME.part" || die "upload failed; the partial file is left at $DEST/$NAME.part and will resume on the next run"
remote "mv -f '$DEST/$NAME.part' '$DEST/$NAME' && chmod 0644 '$DEST/$NAME'"

# --- 4. prove it is readable from the internet -----------------------------------------------------
# Present in the docroot and served to the world are different claims, and only the second one
# matters. A Range request settles reachability, content type and resumability in one round trip
# without pulling 4G back through this machine. Resume is not a nicety: it is what makes a ~4G
# download over first-boot Wi-Fi finish at all.
url="$BASE_URL/$CHANNEL/$NAME"
log "verifying public readability: $url"
code="$(curl -fsS -o /dev/null -w '%{http_code}' -r 0-0 --max-time 30 "$url" || true)"
case "$code" in
  206) log "ok: 206 Partial Content (public, and Range works)" ;;
  200) log "WARNING: 200 rather than 206 — public, but Range is not honoured; an interrupted download will restart from zero" ;;
  *)   die "the uploaded bundle is NOT publicly readable (HTTP ${code:-no response}) at $url
  The bytes are on the server, so this is nginx or TLS, not a failed upload. latest.json was NOT
  flipped, so the fleet still sees the previous release. Check: ssh $USER_@$HOST 'sudo nginx -t'" ;;
esac

# --- 5. flip the pointer, last ---------------------------------------------------------------------
# Everything above this line is additive and invisible to devices. This is the line that publishes.
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
# if/fi rather than `[ -n "$BUILD" ] && printf`: under `set -e` an AND-list whose test fails takes
# the whole script down, so the terse form would abort every publish of a bundle without meta.
{
  printf '{\n'
  printf '  "version": "%s",\n' "$VERSION"
  if [ -n "$BUILD" ]; then printf '  "build": "%s",\n' "$BUILD"; fi
  if [ -n "$GIT" ];   then printf '  "git": "%s",\n'   "$GIT";   fi
  printf '  "bundle": "%s",\n' "$NAME"
  printf '  "size": %s,\n' "$SIZE"
  printf '  "sha256": "%s"\n' "$SHA"
  printf '}\n'
} >"$tmp"

# Written to a temp path on the server and moved into place, for the same reason the bundle was: a
# device that fetches latest.json mid-write must not get half a JSON document. It would fail closed
# (exit 7, "malformed latest.json") rather than do anything dangerous, but a publish should not make
# the fleet briefly blind.
rsync -e "ssh ${SSH_OPTS[*]}" "$tmp" "$USER_@$HOST:$DEST/.latest.json.tmp"
remote "chmod 0644 '$DEST/.latest.json.tmp' && mv -f '$DEST/.latest.json.tmp' '$DEST/latest.json'"

# Read it back over HTTPS — the same way a device will, not over SSH. This is what catches a caching
# layer, a wrong content type, or a docroot that is not the one nginx is serving.
log "reading latest.json back over HTTPS"
served="$(curl -fsS --max-time 30 "$BASE_URL/$CHANNEL/latest.json" || true)"
[ -n "$served" ] || die "latest.json was written but does not come back from $BASE_URL/$CHANNEL/latest.json"
if ! printf '%s' "$served" | grep -q "\"bundle\": \"$NAME\""; then
  printf '%s\n' "$served" | sed 's/^/         /' >&2
  die "the served latest.json does not name $NAME — something is serving a stale or different file"
fi
log "published: $url"

# --- 6. prune --------------------------------------------------------------------------------------
# Never the one just published, and never the one latest.json names — those are the same file today,
# but they stop being the same the moment someone rolls back by hand-editing the pointer, and a prune
# that deletes the file the pointer names would take the fleet's update path down.
# Sent over stdin with a quoted heredoc rather than built as a giant escaped one-liner: the nested
# quoting of an inline `ssh "...sed 's/\"/.../'"` is where this kind of thing goes wrong silently, and
# a prune that misfires deletes releases.
if [ "$KEEP" -ge 1 ]; then
  remote "DEST='$DEST' KEEP='$KEEP' bash -s" <<'PRUNE' >&2 || log "prune failed (continuing — the publish itself succeeded)"
set -eu
cd "$DEST" 2>/dev/null || exit 0
keep=$(sed -n 's/.*"bundle": *"\([^"]*\)".*/\1/p' latest.json 2>/dev/null || true)
ls -1 novadeck-*.raucb 2>/dev/null | sort -V | head -n "-$KEEP" | while read -r old; do
  [ "$old" = "$keep" ] && continue
  echo "[publish] pruning $old"
  rm -f -- "$old"
done
PRUNE
fi

log "devices on channel '$CHANNEL' will be offered v$VERSION on their next check"
