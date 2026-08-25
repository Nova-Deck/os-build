#!/usr/bin/env bash
# Offline test for images/publish-card.sh — specifically its BUCKET PREFIX and its PRUNE.
#
#   images/test-publish-card.sh
#
# WHY THIS FILE EXISTS. The bundle publisher has had a suite since its integrity gate was written;
# this one had none, and it is the one that DELETES. Retention here is `rclone purge` over a whole
# prefix, at KEEP=1 for cards — so the difference between `cards/` and anything else is the
# difference between pruning a superseded release and deleting the card people are downloading right
# now. That was survivable while one caller passed one hardcoded prefix. It stopped being survivable
# on 2026-08-25, when the installer medium became a second artifact through the same script.
#
# SO THE CASE THAT EARNS THIS FILE is "publishing an installer leaves cards/ alone". Everything else
# here is scaffolding around it.
#
# HOW IT WORKS: the real, shipped script runs — not a copy. Its seams are the NOVADECK_*/R2_*
# variables it already documents, plus NOVADECK_RCLONE, which images/lib-rclone.sh honours precisely
# so this can exist: rclone_bin returns an ABSOLUTE path under work/tools/, so a stub cannot be
# shadowed onto PATH, and pre-creating that path would overwrite a real operator's binary.
#
# The "bucket" is a local directory and the stub implements the four verbs the script uses
# (copyto, copy, lsf --dirs-only, purge) against it, so every path the script builds is exercised as
# a real filesystem path rather than asserted as a string.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PUBLISH="$ROOT/images/publish-card.sh"
[ -f "$PUBLISH" ] || { echo "no publish-card.sh: $PUBLISH" >&2; exit 1; }

PASS=0; FAIL=0; CASE=""
ok()  { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin" "$W/bucket" "$W/meta/provenance"

# The metadata publish-card.sh refuses to run without. Content is irrelevant here — images/
# card-meta.sh owns what goes in it — but the FILES have to exist, because their absence is one of
# the script's own preconditions.
printf 'deadbeef  sdcard.img.gz\n' >"$W/meta/sha256sums.txt"
printf 'a manifest\n' >"$W/meta/provenance/manifest.lock"

# The stub rclone. Only the four verbs the script uses, against $W/bucket as the "bucket".
cat >"$W/bin/rclone" <<'STUB'
#!/usr/bin/env bash
# args are logged whole so a case can assert what was asked, not just what happened
printf '%s\n' "$*" >> "$RCLONELOG"
verb="$1"; shift
# strip the flags; what is left is the positional pair
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --s3-chunk-size|--retries|--low-level-retries|--stats) shift 2 ;;
    --stats-one-line|--dirs-only) shift ;;
    *) args+=("$1"); shift ;;
  esac
done
localpath() { printf '%s\n' "$BUCKETDIR/${1#r2:}"; }
case "$verb" in
  copyto) dest="$(localpath "${args[1]}")"; mkdir -p "$(dirname "$dest")"; cp "${args[0]}" "$dest" ;;
  copy)   dest="$(localpath "${args[1]}")"; mkdir -p "$dest"; cp -r "${args[0]}" "$dest/" ;;
  lsf)    d="$(localpath "${args[0]}")"; [ -d "$d" ] || exit 0
          for x in "$d"/*/; do [ -d "$x" ] && printf '%s/\n' "$(basename "$x")"; done ;;
  purge)  rm -rf -- "$(localpath "${args[0]}")" ;;
  *) echo "stub rclone: unhandled verb $verb" >&2; exit 2 ;;
esac
STUB
# curl: the public-readability probe. 206 unless a case says otherwise.
cat >"$W/bin/curl" <<'STUB'
#!/usr/bin/env bash
url=""
for a in "$@"; do case "$a" in http*|https*) url="$a" ;; esac; done
printf '%s\n' "$url" >> "$CURLLOG"
[ "${TEST_UNSERVED:-0}" = 1 ] && exit 22
path="${url#*://}"; path="${path#*/}"          # strip host
path="${path#*/}"                              # strip bucket
[ -f "$BUCKETDIR/$R2_BUCKET/$path" ] || exit 22
printf '206'
STUB
chmod +x "$W/bin/rclone" "$W/bin/curl"

IMG="$W/sdcard.img.gz"; printf 'an image\n' >"$IMG"

run() {  # [env assignments...] <version> [image]
  local -a envs=()
  while [ $# -gt 0 ] && [[ $1 == *=* ]]; do envs+=("$1"); shift; done
  : >"$W/rclone.log"; : >"$W/curl.log"
  OUT="$(env PATH="$W/bin:$PATH" \
      NOVADECK_RCLONE="$W/bin/rclone" \
      RCLONELOG="$W/rclone.log" CURLLOG="$W/curl.log" BUCKETDIR="$W/bucket" \
      R2_ACCOUNT_ID=acct R2_ACCESS_KEY_ID=key R2_SECRET_ACCESS_KEY=secret \
      R2_BUCKET=novadeck R2_PUBLIC_BASE="https://pub.example/novadeck" \
      "${envs[@]}" bash "$PUBLISH" "$1" "${2:-$IMG}" "$W/meta" 2>"$W/err")"
  RC=$?
  ERR="$(cat "$W/err")"
}

reset_bucket() { rm -rf "$W/bucket"; mkdir -p "$W/bucket/novadeck"; }
seed_prefix() { mkdir -p "$W/bucket/novadeck/$1"; printf 'x\n' >"$W/bucket/novadeck/$1/old.img.gz"; }

# =================================================================================================
CASE="the default prefix is cards/, unchanged"
reset_bucket
run 1.0.0
[ "$RC" = 0 ] && ok "exit 0" || bad "exit $RC: $ERR"
[ -f "$W/bucket/novadeck/cards/1.0.0/sdcard.img.gz" ] \
  && ok "the card lands in cards/<version>/" \
  || bad "nothing at cards/1.0.0/: $(find "$W/bucket" -type f | head -3)"
[ -f "$W/bucket/novadeck/cards/1.0.0/sha256sums.txt" ] \
  && ok "with the checksums beside it" || bad "the metadata did not land"
printf '%s' "$OUT$ERR" | grep -q 'pub.example/novadeck/cards/1.0.0/sdcard.img.gz' \
  && ok "and the URL it hands back is the one it uploaded to" \
  || bad "the published URL is wrong: $ERR"

CASE="NOVADECK_R2_KIND puts a medium somewhere else"
reset_bucket
run NOVADECK_R2_KIND=installer 2.0.0
[ -f "$W/bucket/novadeck/installer/2.0.0/sdcard.img.gz" ] \
  && ok "it lands in installer/<version>/" \
  || bad "nothing at installer/2.0.0/"
[ -d "$W/bucket/novadeck/cards" ] \
  && bad "it created a cards/ prefix as well" \
  || ok "and nothing was written under cards/"

# =================================================================================================
CASE="a prune stays inside its own prefix"
# THE ONE THIS FILE IS FOR. Retention is `rclone purge` over a whole prefix, and the card path runs
# it at KEEP=1 — so a prefix that leaked between callers would not misplace a file, it would delete
# the card people are downloading right now.
reset_bucket
seed_prefix cards/0.9.0
seed_prefix cards/0.9.1
seed_prefix installer/1.0.0
run NOVADECK_R2_KIND=installer NOVADECK_CARD_KEEP=1 2.0.0
[ -d "$W/bucket/novadeck/cards/0.9.0" ] && [ -d "$W/bucket/novadeck/cards/0.9.1" ] \
  && ok "publishing an installer left BOTH cards alone" \
  || bad "the installer publish pruned cards/: $(ls "$W/bucket/novadeck/cards" 2>&1)"
[ ! -d "$W/bucket/novadeck/installer/1.0.0" ] \
  && ok "and pruned the older installer, as KEEP=1 asks" \
  || bad "the older installer survived a KEEP=1 prune"
[ -d "$W/bucket/novadeck/installer/2.0.0" ] \
  && ok "never the one just published" \
  || bad "it deleted the version it had just uploaded"
grep -q 'purge .*cards' "$W/rclone.log" \
  && bad "it issued a purge against cards/ while publishing an installer" \
  || ok "no purge was ever aimed at the other prefix"

CASE="the card path prunes cards/ and nothing else"
reset_bucket
seed_prefix cards/0.9.0
seed_prefix installer/1.0.0
run NOVADECK_CARD_KEEP=1 1.0.0
[ ! -d "$W/bucket/novadeck/cards/0.9.0" ] \
  && ok "the older card is pruned" || bad "KEEP=1 kept two cards"
[ -d "$W/bucket/novadeck/installer/1.0.0" ] \
  && ok "and the installer prefix is untouched" \
  || bad "a card publish deleted a published installer medium"

CASE="KEEP=0 prunes nothing at all"
reset_bucket
seed_prefix cards/0.9.0
run NOVADECK_CARD_KEEP=0 1.0.0
[ -d "$W/bucket/novadeck/cards/0.9.0" ] \
  && ok "an explicit 0 keeps the back catalogue" || bad "KEEP=0 still pruned"

# =================================================================================================
CASE="a prefix that could escape is refused before anything moves"
reset_bucket
for k in "../evil" "cards/nested" "Cards" "up/../down"; do
  run NOVADECK_R2_KIND="$k" 1.0.0
  if [ "$RC" != 0 ] && [ ! -s "$W/rclone.log" ]; then
    ok "'$k' is refused, and nothing was uploaded"
  else
    bad "'$k' was accepted (rc=$RC, log: $(cat "$W/rclone.log"))"
  fi
done
# AN EMPTY ONE IS THE DEFAULT, NOT A REFUSAL, and that is the `:-` semantics every knob in this
# repo uses. It matters in CI: a `NOVADECK_R2_KIND: ${{ vars.X }}` that evaluates empty should
# publish a card rather than fail the release.
reset_bucket
run NOVADECK_R2_KIND= 1.0.0
[ "$RC" = 0 ] && [ -f "$W/bucket/novadeck/cards/1.0.0/sdcard.img.gz" ] \
  && ok "an empty prefix falls back to cards/, like every other :- knob here" \
  || bad "an empty NOVADECK_R2_KIND did not default (rc=$RC)"

# The version is a path segment too, and it was already guarded — assert it stayed guarded.
run "1.0.0/../.."
[ "$RC" != 0 ] && ok "a version that could escape its prefix is refused" \
              || bad "a traversing version was accepted"

CASE="bytes in the bucket that are not publicly readable are a failure"
reset_bucket
run TEST_UNSERVED=1 1.0.0
[ "$RC" != 0 ] \
  && ok "exit $RC -- present in the bucket and served to the world are different claims" \
  || bad "exit 0 for a card nobody can download"

# =================================================================================================
printf '\ntest-publish-card.sh: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
