#!/usr/bin/env bash
# novadeck R2 preflight — prove the card bucket works, in seconds, with a throwaway object.
#
#   images/r2-preflight.sh
#
# WHY THIS EXISTS. Every one of the five R2 settings can be wrong in a way that only surfaces at the
# END of a release build: a token scoped to the wrong bucket, an account id typo'd into the endpoint,
# or — the quiet one — a bucket whose public access was never enabled, which uploads perfectly and
# serves 404 to everyone who clicks the link. Finding any of that after a four-hour card build is a
# bad trade against finding it in five seconds. This runs the SAME round trip publish-card.sh does
# (pinned rclone -> upload -> anonymous public read -> range request) against one small object, and
# then removes it.
#
# Needs the same environment CI has:
#   R2_ACCOUNT_ID R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_BUCKET R2_PUBLIC_BASE
#
# Safe to run against the live bucket: it writes only under _preflight/ and purges that prefix when
# it is done. It never touches cards/.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

log()  { printf '[preflight] %s\n' "$*" >&2; }
die()  { printf '[preflight] %s\n' "$*" >&2; exit 1; }
pass() { printf '[preflight] ok   %s\n' "$*" >&2; }

. "$ROOT/images/lib-rclone.sh"

r2_env
RCLONE="$(rclone_bin)"
pass "pinned rclone $(pin_field "$RCLONE_PIN" version) fetched and verified"

key="_preflight/$(date -u +%Y%m%dT%H%M%SZ)-$$.txt"
body="novadeck r2 preflight $(date -u +%FT%TZ)"
tmp="$(mktemp)"; printf '%s\n' "$body" > "$tmp"
trap 'rm -f "$tmp"; "$RCLONE" purge "r2:$R2_BUCKET/_preflight" >/dev/null 2>&1 || true' EXIT

# 1. Credentials + bucket scope. A token scoped to a different bucket fails here, not later.
log "uploading $key"
"$RCLONE" copyto --retries 2 --low-level-retries 2 "$tmp" "r2:$R2_BUCKET/$key" \
  || die "upload failed — check R2_ACCOUNT_ID, the access key pair, and that the token is scoped to '$R2_BUCKET' with Object Read & Write"
pass "credentials accept a write to '$R2_BUCKET'"

# 2. The public read. This is the check that matters and the one no amount of successful uploading
# implies: publicity is a BUCKET setting, invisible from the S3 API.
url="${R2_PUBLIC_BASE%/}/$key"
log "reading it back anonymously: $url"
got="$(curl -fsS "$url" 2>/dev/null || true)"
[ "$got" = "$body" ] || die "the object is NOT publicly readable at $url
  The write succeeded, so this is the bucket's public-access setting, not a credential problem.
  Enable it at R2 -> $R2_BUCKET -> Settings -> Public access -> R2.dev subdomain -> Allow Access.
  (A 401 here means public access is off; a DNS failure means R2_PUBLIC_BASE is wrong.)"
pass "public URL serves the object anonymously"

# 3. Range support. Not fatal — but a 5 GiB download that cannot resume is worth knowing about
# before someone on a bad connection finds out.
code="$(curl -fsS -o /dev/null -w '%{http_code}' -r 0-0 "$url" || true)"
case "$code" in
  206) pass "range requests honoured (a resumed download continues rather than restarting)" ;;
  200) log  "WARNING: 200 rather than 206 — no Range support, so a resumed 5 GiB download restarts" ;;
  *)   log  "WARNING: unexpected ${code:-no response} on the range request" ;;
esac

# 4. Prove the prune path works too, since publish-card.sh runs it unattended on every publish.
"$RCLONE" purge "r2:$R2_BUCKET/_preflight" || die "purge failed — the token can write but not delete, so retention (N=1) will not work and the bucket will grow past the free tier"
pass "delete works, so retention can hold the bucket inside the free tier"

log ""
log "READY — publish-card.sh will work against $R2_BUCKET"
log "cards will appear at ${R2_PUBLIC_BASE%/}/cards/<version>/sdcard.img.gz"
