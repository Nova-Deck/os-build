#!/usr/bin/env bash
# novadeck release-card publisher — upload a built SD card to the Cloudflare R2 bucket it is served
# from, and emit the metadata the GitHub Release carries alongside it.
#
#   images/card-meta.sh <image-file>                     -> out/images/release-meta/
#   images/publish-card.sh <version> <image-file> <metadir>
#
# Metadata is built by its own script rather than here, because the non-publishing path needs the
# identical checksums and provenance for its workflow artifact — one producer, two consumers.
#
# WHY THIS EXISTS RATHER THAN A RELEASE ASSET. A release card compresses to 5.08 GiB (measured
# 2026-08-04, pigz -6, 19G apparent / 11G real): the payload is ALREADY-compressed content (the
# btrfs root carries compress=zstd), so no format or level gets it near a GiB. GitHub caps a single
# release asset at 2 GiB, which rules the Release out as the transport by 2.5x. GHCR was the other
# candidate and was ruled out by test: a bare
# blob URL answers 401 even for a public package, so a browser cannot fetch one and every consumer
# would need oras or a curl+jq token dance. R2 is what leaves a person with a link they can click.
#
# The GitHub Release still exists and still matters — it carries sha256sums.txt, the provenance pins
# and the link. That is the reviewable, permanent record; the bucket is only where the bytes live.
#
# CREDENTIALS. Push-only, and only here: R2_ACCOUNT_ID / R2_ACCESS_KEY_ID / R2_SECRET_ACCESS_KEY.
# In CI they live in the `release-cards` GitHub environment, not in repo-wide secrets, since
# 2026-08-04 — because of the retention paragraph below, these can DELETE the published card, not
# just add one, so "a write credential to a public bucket" undersells them. If they arrive empty,
# read the hint r2_env prints: the usual cause is a job that did not declare the environment.
# They are consumed as environment variables and never written to a config file, for the reason
# .github/workflows/image.yml already keeps the RAUC key in $RUNNER_TEMP — anything on disk in the
# workspace gets swept into artifacts and caches. The token they belong to should be scoped to this
# ONE bucket with Object Read & Write: it is a write credential to a public host.
#
# RETENTION IS N=1, deliberately, and it STAYS N=1 even though the card halved. R2's free tier is
# 10 GB = 9.31 GiB; two 5.08 GiB cards are 10.16 GiB, which is over it. Dropping slot B took the
# card from 8.97 to 5.08 GiB (measured 2026-08-04 — release cards carried a second copy of the root
# in slot B until then), so the margin is far healthier than it was at 96% of the tier, but it is
# still not two cards. Older prefixes are pruned on publish; bump KEEP if you decide to pay for a
# back catalogue.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEEP="${NOVADECK_CARD_KEEP:-1}"

log() { printf '[publish] %s\n' "$*" >&2; }
die() { printf '[publish] %s\n' "$*" >&2; exit 1; }

. "$ROOT/images/lib-rclone.sh"

# --- args -----------------------------------------------------------------------------------
VERSION="${1:-}"
IMG="${2:-}"
stage="${3:-$ROOT/out/images/release-meta}"
[ -n "$VERSION" ] || die "usage: $0 <version> <image-file> [metadir]"
[ -n "$IMG" ] && [ -f "$IMG" ] || die "no such image: ${IMG:-<unset>}"
[ -f "$stage/sha256sums.txt" ] || die "no metadata at $stage — run images/card-meta.sh '$IMG' first"

# A version becomes a URL path segment and a bucket prefix. Refuse anything that could escape it
# rather than discovering later that a tag with a slash wrote to the wrong prefix.
case "$VERSION" in
  *[!A-Za-z0-9._-]*) die "version '$VERSION' has characters that do not belong in a URL path" ;;
esac

r2_env
RCLONE="$(rclone_bin)"

name="$(basename "$IMG")"
prefix="cards/$VERSION"

log "uploading $name -> r2:$R2_BUCKET/$prefix/ (multipart)"
"$RCLONE" copyto --s3-chunk-size 64M --retries 5 --low-level-retries 10 \
  --stats 30s --stats-one-line \
  "$IMG" "r2:$R2_BUCKET/$prefix/$name"

log "uploading metadata"
"$RCLONE" copy --retries 5 "$stage/sha256sums.txt" "r2:$R2_BUCKET/$prefix/"
"$RCLONE" copy --retries 5 "$stage/provenance" "r2:$R2_BUCKET/$prefix/provenance/"

# Verify the object is actually readable at the PUBLIC url, not merely present in the bucket. A
# bucket whose public access was never enabled looks identical from in here — the upload succeeds
# and the link 404s — and that failure would otherwise be found by the first person to try to flash
# a card. Range request rather than a full GET: it proves reachability and resumability in one
# round trip without pulling 9 GiB through the runner.
url="${R2_PUBLIC_BASE%/}/$prefix/$name"
log "verifying public readability: $url"
code="$(curl -fsS -o /dev/null -w '%{http_code}' -r 0-0 "$url" || true)"
case "$code" in
  206) log "ok: 206 Partial Content (public, and range requests work)" ;;
  200) log "WARNING: 200 rather than 206 — public, but the CDN is not honouring Range; a resumed download will restart" ;;
  *)   die "the uploaded card is NOT publicly readable (HTTP ${code:-no response}) at $url
  The bytes are in the bucket, so this is an access setting, not a failed upload. Enable public
  access on '$R2_BUCKET' (R2 -> bucket -> Settings -> Public access) and re-run." ;;
esac

# Prune older cards. R2's free tier is 10 GB against ~9 GiB per card, so this is what keeps the
# bucket free rather than a tidiness preference. Never touches the prefix just written.
case "$KEEP" in
  ''|*[!0-9]*) die "NOVADECK_CARD_KEEP must be a whole number, got '$KEEP'" ;;
esac
if [ "$KEEP" -ge 1 ]; then
  mapfile -t old < <("$RCLONE" lsf --dirs-only "r2:$R2_BUCKET/cards/" 2>/dev/null | sed 's:/$::' | sort -V)
  n=${#old[@]}
  if [ "$n" -gt "$KEEP" ]; then
    for d in "${old[@]:0:$((n - KEEP))}"; do
      [ "$d" = "$VERSION" ] && continue
      log "pruning older card: cards/$d"
      "$RCLONE" purge "r2:$R2_BUCKET/cards/$d" || log "could not prune cards/$d (continuing)"
    done
  fi
fi

# Hand the caller the two things the GitHub Release needs: where the card can be downloaded, and
# the directory holding the checksums + provenance to attach.
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  { echo "url=$url"; echo "metadir=$stage"; } >> "$GITHUB_OUTPUT"
fi
log "published: $url"
log "release metadata staged in ${stage#"$ROOT"/}"
