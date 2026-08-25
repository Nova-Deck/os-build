#!/usr/bin/env bash
# novadeck Steam-seed publisher — put the /home seed where a network installer can fetch it.
# Phase 6 of .claude/plans/internal-install.plan.md.
#
#   ota/publish-seed.sh out/steam-seed/steam-seed-<sha256>.tar.zst
#
# Shaped after ota/publish-bundle.sh — credentials from the environment only, bytes uploaded under a
# .part name and renamed into place, hashed ON THE SERVER, then proven readable from the internet —
# and it differs from that script in exactly two ways, both because of what a seed is:
#
# 1. THERE IS NO SIGNATURE, AND NO POINTER TO FLIP. A bundle is signed and named by a manifest a
#    device fetches; this artifact is CONTENT-ADDRESSED. install/novadeck-install hashes what it
#    downloads and compares it against the pin baked into the medium, refusing on a mismatch, and
#    install/release-info builds the URL out of that same pin:
#
#        <OTA_URL>/seed/steam-seed-<pin>.tar.zst
#
#    So the file's NAME is the integrity gate, and the one thing this script must never do is put
#    bytes at a name that does not hash to it. That is the first check below, before anything moves.
#    A medium asks for its own bytes by hash and gets them or gets a 404 — there is nothing here that
#    a stale or hostile pointer could aim somewhere else, because there is no pointer.
#
# 2. IT DOES NOT PRUNE BY DEFAULT. A published seed is not superseded by a newer one: every installer
#    medium ever built names exactly one seed, by hash, forever. Deleting an old seed does not
#    inconvenience an old medium, it BREAKS it — the download 404s and the install stops at the seed
#    step, on a device whose Android data may already be gone. NOVADECK_SEED_KEEP exists for the day
#    the disk fills; it is opt-in, and the header of that step says what it costs.
#
# NOT A CHANNEL. Seeds live in one flat `seed/` directory: the Steam client tree has nothing to do
# with which OS channel a medium was built from, and an installer built against `dev` needs the same
# tree as one built against `stable`. Putting them under channels would publish the same 3 GB twice
# and give two names to one artifact.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

HOST="${NOVADECK_OTA_HOST:-updates.novadeck.cloud-ip.cc}"
USER_="${NOVADECK_OTA_USER:-ubuntu}"
SSH_KEY="${NOVADECK_OTA_SSH_KEY:-}"
DOCROOT="${NOVADECK_OTA_DOCROOT:-/srv/novadeck-ota}"
BASE_URL="${NOVADECK_OTA_URL:-https://$HOST}"
# 0 = keep every seed, which is the correct default (see 2. above). A positive value keeps that many
# newest and deletes the rest.
KEEP="${NOVADECK_SEED_KEEP:-0}"

SEED="${1:-}"

log()  { printf '[publish-seed] %s\n' "$*" >&2; }
die()  { printf '[publish-seed] %s\n' "$*" >&2; exit 1; }

[ -n "$SEED" ] || die "usage: $0 <steam-seed-<sha256>.tar.zst>"
[ -f "$SEED" ] || die "no such seed artifact: $SEED"
case "$KEEP" in
  ''|*[!0-9]*) die "NOVADECK_SEED_KEEP must be a whole number, got '$KEEP'" ;;
esac

SEED_ABS="$(cd "$(dirname "$SEED")" && pwd)/$(basename "$SEED")"
NAME="$(basename "$SEED_ABS")"

command -v rsync >/dev/null 2>&1 || die "rsync is not installed, and this script cannot publish
  without it. The SERVER has it; this is the publishing workstation that does not."

# --- 1. the name gate ------------------------------------------------------------------------------
# THE ONLY GATE THERE IS, and it replaces publish-bundle.sh's signature check. The medium derives the
# URL from its baked pin, so publishing bytes under a name they do not hash to produces a file that
# either serves nobody (no medium pins it) or, worse, answers a pin with the wrong tree — and the
# only thing standing between that and a stranger's /home is the spine's own hash check, which fails
# AFTER the download, on a device that is already mid-install.
case "$NAME" in
  steam-seed-*.tar.zst) ;;
  *) die "'$NAME' is not a seed artifact name — expected steam-seed-<sha256>.tar.zst (steam-seed/pack-seed.sh names it)" ;;
esac
CLAIMED="${NAME#steam-seed-}"; CLAIMED="${CLAIMED%.tar.zst}"
case "$CLAIMED" in
  *[!0-9a-f]*|"") die "'$NAME' does not carry a lower-case sha256 in its name" ;;
esac
[ "${#CLAIMED}" -eq 64 ] || die "'$NAME' carries a ${#CLAIMED}-character hash, not a sha256"

SIZE="$(stat -c %s "$SEED_ABS")"
log "hashing $((SIZE / 1024 / 1024)) MiB"
SHA="$(sha256sum "$SEED_ABS" | cut -d' ' -f1)"
[ "$SHA" = "$CLAIMED" ] || die "the file does not hash to its own name — refusing to publish it.
  name says: $CLAIMED
  file is:   $SHA
  A medium pins the hash and builds the URL from it, so this file would answer a pin with the wrong
  bytes. Re-pack it (steam-seed/pack-seed.sh names the output from its own hash) rather than
  renaming it."
log "ok: $NAME hashes to its own name"

# --- 2. ssh/rsync plumbing -------------------------------------------------------------------------
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)
[ -n "$SSH_KEY" ] && SSH_OPTS+=(-i "$SSH_KEY")
remote() { ssh "${SSH_OPTS[@]}" "$USER_@$HOST" "$@"; }

DEST="$DOCROOT/seed"
remote "mkdir -p '$DEST'" || die "cannot create $DEST on $HOST (is the docroot owned by $USER_? run ota/setup-server.sh)"

# --- 3. already there? -----------------------------------------------------------------------------
# A REPUBLISH IS THE NORMAL CASE, not an exception: pack-seed.sh is deterministic, so a seed that has
# not changed packs to the same bytes and the same name on every build. Uploading 3 GB to overwrite a
# file with itself is the shape that makes people skip the publish step entirely.
existing="$(remote "sha256sum '$DEST/$NAME' 2>/dev/null | cut -d' ' -f1" || true)"
if [ "$existing" = "$SHA" ]; then
  log "already published and byte-identical: $BASE_URL/seed/$NAME"
  log "nothing to do"
  exit 0
fi
[ -z "$existing" ] || die "$DEST/$NAME exists on $HOST and hashes $existing, not $SHA.
  Two different trees cannot share a content-addressed name; one of them is corrupt. Do NOT
  overwrite it — media in the field pin this hash. Investigate on the server first."

# Space on the SERVER, before the transfer rather than after it.
avail="$(remote "df -kP '$DEST' | awk 'NR==2{print \$4}'")"
need=$(( (SIZE / 1024) + 262144 ))
[ "${avail:-0}" -ge "$need" ] || die "not enough room on $HOST: need $((need / 1024)) MiB at $DEST, have $((avail / 1024)) MiB
  Prune old bundles first (they supersede each other; seeds do not) — see NOVADECK_OTA_KEEP in
  ota/publish-bundle.sh — before considering NOVADECK_SEED_KEEP here."

# --- 4. upload -------------------------------------------------------------------------------------
log "uploading $NAME (resumable)"
rsync -e "ssh ${SSH_OPTS[*]}" --partial --inplace --progress \
  "$SEED_ABS" "$USER_@$HOST:$DEST/$NAME.part" \
  || die "upload failed; the partial file is left at $DEST/$NAME.part and will resume on the next run"
remote "mv -f '$DEST/$NAME.part' '$DEST/$NAME' && chmod 0644 '$DEST/$NAME'"

# --- 5. prove the bytes that LANDED are the bytes we hashed ----------------------------------------
# The same reasoning as publish-bundle.sh's step 3b, with one difference in the consequence: a
# corrupt seed is caught by the medium's own pin check, so it cannot install a broken /home. What it
# CAN do is fail every install with a hash mismatch that looks like a bad pin, on a device that has
# already downloaded 3 GB to find out. Caught here it costs one re-upload.
log "verifying the uploaded bytes (sha256 on the server, ~$((SIZE / 1024 / 1024)) MiB to read)"
remote_sha="$(remote "sha256sum '$DEST/$NAME' | cut -d' ' -f1" || true)"
[ -n "$remote_sha" ] || die "could not hash $DEST/$NAME on $HOST — refusing to leave bytes nobody has checked under a name media will ask for"
[ "$remote_sha" = "$SHA" ] || die "CORRUPT UPLOAD: $NAME on $HOST does not match what was sent.
  local:  $SHA
  server: $remote_sha
  Delete '$DEST/$NAME' on the server and re-run; the re-run re-sends in full."
log "ok: server-side sha256 matches"

# --- 6. prove it is readable from the internet -----------------------------------------------------
# A Range request, for the same reason the bundle's publish uses one: the spine fetches this with
# `curl -fsSL --retry 3` over a first-boot Wi-Fi link, and a 3 GB download that cannot resume is a
# 3 GB download that may never finish.
url="$BASE_URL/seed/$NAME"
log "verifying public readability: $url"
code="$(curl -fsS -o /dev/null -w '%{http_code}' -r 0-0 --max-time 30 "$url" || true)"
case "$code" in
  206) log "ok: 206 Partial Content (public, and Range works)" ;;
  200) log "WARNING: 200 rather than 206 — public, but Range is not honoured; an interrupted download will restart from zero" ;;
  *)   die "the uploaded seed is NOT publicly readable (HTTP ${code:-no response}) at $url
  The bytes are on the server, so this is nginx or TLS, not a failed upload. Check:
  ssh $USER_@$HOST 'sudo nginx -t'" ;;
esac

# --- 7. prune, opt-in and never by default ---------------------------------------------------------
# READ THIS BEFORE SETTING IT. Old seeds are not superseded: an installer medium built six months ago
# names exactly one seed by hash and will name it forever. Deleting that seed does not make the
# medium fetch a newer one — release-info derives the URL from the medium's own pin — it RETIRES
# that medium: every copy of it in the field stops being able to install anything.
#
# It stops SAFELY. The spine verifies its sources before consent and therefore before the first
# sgdisk (plan §3 rule 11), so the operator gets a failure with Android intact rather than a
# half-installed device. That bounds the damage to a wasted trip; it does not make the deletion
# recoverable, because nothing on that medium can be repointed. Bundles supersede each other and
# prune safely; these do not.
if [ "$KEEP" -ge 1 ]; then
  log "NOVADECK_SEED_KEEP=$KEEP — pruning all but the $KEEP newest seeds"
  log "any installer medium pinned to a pruned seed can no longer complete an install"
  remote "DEST='$DEST' KEEP='$KEEP' NAME='$NAME' bash -s" <<'PRUNE' >&2 || log "prune failed (continuing — the publish itself succeeded)"
set -eu
cd "$DEST" 2>/dev/null || exit 0
ls -1t steam-seed-*.tar.zst 2>/dev/null | tail -n "+$((KEEP + 1))" | while read -r old; do
  [ "$old" = "$NAME" ] && continue
  echo "[publish-seed] pruning $old"
  rm -f -- "$old"
done
PRUNE
fi

log "published: $url"
log "an installer image built with NOVADECK_SEED_SHA256=$SHA will fetch it"
