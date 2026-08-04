#!/usr/bin/env bash
# novadeck overlay artifact pins — verify the BYTES of our own built packages.
#
#   packages/verify-pins.sh              verify work/repo/<arch> against packages/*/artifact.pin
#   packages/verify-pins.sh --write      (re)generate those pins from what is built right now
#   packages/verify-pins.sh --store [p…] verify the committed pins against the PUBLISHED bytes
#
# WHAT THIS ADDS THAT THE LOCK CANNOT. images/manifest.lock pins the `novadeck` rows to their
# SOURCES (packages/inputhash.sh over source.pin + patches + a local PKGBUILD) and not to the
# artifact's sha256, because our builds are not bit-reproducible: rebuilding from identical inputs
# moves every artifact hash, so an artifact hash in the lock only ever verified on the machine that
# last ran `make relock`. That is the right trade for the lock — it is the claim that survives
# crossing a machine — but it leaves a real gap, stated outright in images/fetchlock.sh: anyone who
# can write work/repo can substitute a package and the lock still verifies.
#
# These pins close that gap WITHOUT re-breaking cross-machine builds, by separating the two
# questions instead of overloading one column:
#
#   images/manifest.lock   "were these built from the reviewed sources?"   every build, every machine
#   packages/*/artifact.pin "are these the reviewed BYTES?"                release builds only
#
# A release build must satisfy both. A dev build (NOVADECK_DEV=1) satisfies only the first and is
# unaffected by this file — which is the point: locally built bytes will never match a published
# sha, so requiring these pins everywhere would mean a publish round trip before you could flash
# anything you just compiled.
#
# WHERE THE TRUST ACTUALLY ENTERS: the pin-bump PR. .github/workflows/overlay.yml publishes each
# package to the store and opens a PR carrying these shas; a human reviews that diff. This script
# then proves the bytes on disk are the ones that diff named. It CANNOT prove anyone looked — if
# that PR is rubber-stamped, all this verifies is that CI published what CI published. The review
# is the provenance claim; this is only the mechanism that makes the review binding.
#
# --store: WHAT A PIN CLAIMS, CHECKED WHERE THE BYTES LIVE. The default mode above compares a pin
# against work/repo — it answers "is the repo in front of me the pinned one?". That leaves the pin
# ITSELF unchecked: `--write` will happily record a local build's shas, and until a release build
# runs, nothing notices that those bytes exist on exactly one machine. --store asks the other
# question — "was anything with these shas ever published?" — by pulling each pinned artifact from
# packages/overlay-store.sh and hashing it. It needs no work/, no lock and no credentials, so it
# runs on a bare clone and on a fork's pull request.
#
# THAT IS WHAT MAKES A PIN VERIFIABLE RATHER THAN CONVENTIONAL. The ref it pulls is
# `<name>-<arch>:<inputhash>`, and the inputhash is checked against the tree first — so the
# location being read is fully determined by the SOURCES in the commit, not by anything the pin
# author chose. A hand-written pin passes iff those exact bytes are published under those exact
# sources, and getting them published means actually pushing them, at which point the pin is honest
# by construction. So hand-writing a pin is legitimate now (`make overlay-publish && make
# pin-artifacts`), where before it was a rule nothing enforced.
#
# WHAT IT STILL DOES NOT PROVE: that anyone reviewed the diff, or that the published bytes are
# GOOD. It proves the pin is not a private fiction. Provenance is still the review.
#
# WHY IT CHECKS ONLY THE PINS IT IS GIVEN, in CI. A commit that bumps a package's SOURCES makes
# that package's existing pin stale by definition — the pin-bump for it cannot exist yet, since the
# publish happens after the merge. So a gate over ALL pins on every push would go red on exactly
# the commits that are supposed to be fine. .github/workflows/ci.yml therefore passes it the pins a
# change actually touched. A bare `--store` (every pin) is for a human auditing main.
#
# WHY THE VERIFY PATH READS ONLY COMMITTED FILES. The artifact -> package mapping comes from the
# PINS, not from work/repo/<arch>/.stamps/<name>.files. The stamps are the builder's claim about
# itself, and a check that trusts them is checking the substituted tree's own paperwork. Same
# reasoning images/fetchlock.sh applies when it re-derives the input hash from packages/ rather
# than reading .stamps/<name>.hash. `--write` is allowed to read the stamps, because writing a pin
# is exactly the act of recording what the builder produced.
#
# WHICH ARTIFACTS NEED A PIN: precisely the `novadeck` rows in the lock, i.e. what actually gets
# installed. One PKGBUILD can emit more than it ships — mesa builds five artifacts and the image
# installs three (mesa, vulkan-freedreno, vulkan-mesa-device-select); every *-debug package and
# vulkan-mesa-layers are built and never installed. Pinning what is not installed would be busywork
# that fails the day a split package changes.
#
# NOT pinned, deliberately: novadeck.db / novadeck.files. repo-add is not byte-reproducible either,
# so the db is rebuilt locally on every pull and a pin on it could never hold. Nothing installs
# FROM the db in a locked build — images/fetchlock.sh hands pacman an explicit file list — so the
# db is a convenience index, not an input to what lands in the image.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Must match packages/build-overlay.sh and packages/overlay-store.sh: one aarch64 build serves
# every aarch64 device, so the overlay repo is arch-scoped rather than per-board.
ARCH="aarch64"
REPO_DIR="$ROOT/work/repo/$ARCH"
STAMPS="$REPO_DIR/.stamps"
LOCK="$ROOT/images/manifest.lock"

log() { printf '[pins] %s\n' "$*" >&2; }
die() { printf '[pins] %s\n' "$*" >&2; exit 1; }

pin_field() { sed -n "s/^$2:[[:space:]]*//p" "$1" | head -1; }

MODE=verify
SELECTED=()
case "${1:-}" in
  --write) MODE=write ;;
  --store) MODE=store; shift; SELECTED=("$@") ;;
  '') ;;
  *) die "usage: $0 [--write | --store [package|path…]]" ;;
esac

# --- package dirs ---------------------------------------------------------------------------
# Stable order (the pins glob), matching build-overlay.sh and overlay-store.sh. Hoisted above the
# lock/repo guards because --store needs this and needs neither of those.
PKGDIRS=()
shopt -s nullglob
for p in "$ROOT"/packages/*/source.pin; do PKGDIRS+=("$(dirname "$p")"); done
shopt -u nullglob
[ ${#PKGDIRS[@]} -gt 0 ] || die "no packages/*/source.pin found"

# ============================================================================================
# --store: check the committed pins against the published bytes (see the header)
# ============================================================================================
if [ "$MODE" = store ]; then
  STORE="$ROOT/packages/overlay-store.sh"

  # Accept either a package name or a path to its pin, because the two callers naturally hold
  # different things: a human types `gamescope`, and CI has `packages/gamescope/artifact.pin` out
  # of `git diff --name-only`. Translating in the caller would mean the same basename dance in a
  # YAML run block, which is where it would eventually be got wrong.
  SEL=()
  if [ ${#SELECTED[@]} -eq 0 ]; then
    for dir in "${PKGDIRS[@]}"; do [ -f "$dir/artifact.pin" ] && SEL+=("$dir"); done
    [ ${#SEL[@]} -gt 0 ] || die "no packages/*/artifact.pin to check"
  else
    for arg in "${SELECTED[@]}"; do
      case "$arg" in */*) dir="$ROOT/$(dirname "${arg#"$ROOT"/}")" ;; *) dir="$ROOT/packages/$arg" ;; esac
      [ -f "$dir/source.pin" ] || die "$arg: not an overlay package dir (no source.pin)"
      # A pin that was DELETED by the change under test is not a pin to verify. The caller is
      # expected to filter deletions, so reaching here with a missing file is worth saying out
      # loud rather than silently skipping — a silent skip is how a check reports nothing.
      [ -f "$dir/artifact.pin" ] || die "$arg: no artifact.pin (deleted? filter deletions out)"
      SEL+=("$dir")
    done
  fi

  # Ask the store about one package, retrying ONLY the answer that can be transient. `have` exits
  # 0 present / 1 absent / 2 unreadable / 3 registry error — overlay-store.sh's probe() classifies
  # them, and that classification is the whole point here: "absent" and "unreachable" mean
  # opposite things (a pin describing bytes nobody published, versus a flaky registry that has
  # told us nothing at all). Retrying a 1 would be retrying a fact.
  store_have() {
    local name="$1" hash="$2" st try
    for try in 1 2 3; do
      st=0; "$STORE" have "$name" "$hash" || st=$?
      [ "$st" -eq 3 ] || return "$st"
      [ "$try" -eq 3 ] || sleep $((try * 5))
    done
    return 3
  }

  stale=""; unpublished=""; mismatched=""; unreachable=""
  checked=0
  for dir in "${SEL[@]}"; do
    pin="$dir/artifact.pin"
    rel="${pin#"$ROOT"/}"
    pname="$(pin_field "$pin" name)"
    [ -n "$pname" ] || die "$rel: missing name"
    declared="$(pin_field "$pin" inputhash)"
    [ -n "$declared" ] || die "$rel: missing inputhash"

    # FIRST, same as the local path and for the same reason: if the pin's inputhash disagrees with
    # the tree, the ref below would be the wrong ref, and every byte result after it would be an
    # answer to a question nobody asked.
    actual="$("$ROOT/packages/inputhash.sh" "$dir")"
    if [ "$declared" != "$actual" ]; then
      stale+="  $pname: pin ${declared:0:16} vs tree ${actual:0:16}"$'\n'
      continue
    fi

    st=0; store_have "$pname" "$declared" || st=$?
    case "$st" in
      0) ;;
      1) unpublished+="  $pname: nothing is published at inputhash ${declared:0:16}"$'\n'; continue ;;
      2) unreachable+="  $pname: the store will not let this caller read it (private package?)"$'\n'; continue ;;
      *) unreachable+="  $pname: the registry could not be reached"$'\n'; continue ;;
    esac

    # System temp, not work/: this mode must run on a clone that has never built anything, and it
    # must not create build state as a side effect of checking.
    tmp="$(mktemp -d)"
    if ! "$STORE" fetch "$pname" "$tmp" "$declared"; then
      unreachable+="  $pname: published, but the payload could not be retrieved intact"$'\n'
      rm -rf "$tmp"; continue
    fi

    while read -r kind sha file; do
      [ "$kind" = "artifact:" ] || continue
      [ -n "$sha" ] && [ -n "$file" ] || die "$rel: malformed artifact line"
      if [ ! -f "$tmp/$file" ]; then
        mismatched+="  $pname: $file"$'\n'"    the published payload does not contain this file at all"$'\n'
        continue
      fi
      got="$(sha256sum "$tmp/$file" | cut -d' ' -f1)"
      if [ "$got" != "$sha" ]; then
        mismatched+="  $pname: $file"$'\n'"    pin:   $sha"$'\n'"    store: $got"$'\n'
        continue
      fi
      checked=$((checked + 1))
    done < "$pin"
    rm -rf "$tmp"
  done

  fail=0
  if [ -n "$stale" ]; then
    echo "[pins] STALE — these pins describe different sources than the tree they are committed with:" >&2
    printf '%s' "$stale" >&2
    echo "  Nothing was checked for them: the store is addressed BY the input hash, so a stale pin" >&2
    echo "  would have been compared against some other commit's artifacts." >&2
    fail=1
  fi
  if [ -n "$unpublished" ]; then
    echo "[pins] NOT PUBLISHED — these pins name bytes the store has never seen:" >&2
    printf '%s' "$unpublished" >&2
    echo "  A pin is a claim about bytes a release build will install, so it has to name bytes that" >&2
    echo "  exist somewhere other than the machine that wrote it. Either let the overlay pipeline" >&2
    echo "  publish and open its pin-bump PR, or publish these yourself and re-pin:" >&2
    echo "      packages/overlay-store.sh login && make overlay-publish && make pin-artifacts" >&2
    fail=1
  fi
  if [ -n "$mismatched" ]; then
    echo "[pins] BYTES DO NOT MATCH what is published for these exact sources:" >&2
    printf '%s' "$mismatched" >&2
    echo "  The store already holds an artifact for this input hash and it is not the pinned one." >&2
    echo "  Our builds are not bit-reproducible, so the usual cause is a pin generated from a LOCAL" >&2
    echo "  rebuild of sources someone else published first — the store keeps the first bytes, and" >&2
    echo "  a second push at the same hash is skipped rather than overwriting them. To take the" >&2
    echo "  published bytes and re-pin from them, PER PACKAGE named above:" >&2
    echo "      rm work/repo/$ARCH/.stamps/<pkg>.hash && make overlay-pull && make pin-artifacts" >&2
    echo "  Deleting the stamp is the load-bearing half: pull-all skips anything is_fresh() says is" >&2
    echo "  already built here, so a BARE overlay-pull is a no-op on precisely these packages." >&2
    fail=1
  fi
  if [ -n "$unreachable" ]; then
    echo "[pins] COULD NOT REACH THE STORE (this says nothing about the pins):" >&2
    printf '%s' "$unreachable" >&2
    echo "  Infrastructure, not provenance — retry rather than change a pin." >&2
    # A distinct exit code so a caller can tell "your pins are wrong" from "ask again later"; the
    # two want opposite responses and a single non-zero would flatten them back together. A real
    # pin failure alongside it still wins: that one does not get better by waiting.
    [ "$fail" -eq 1 ] || exit 3
  fi
  [ "$fail" -eq 0 ] || exit 1

  log "$checked artifact(s) verified against the store across ${#SEL[@]} pin(s)"
  exit 0
fi

[ -f "$LOCK" ] || die "no lock: ${LOCK#"$ROOT"/}"
[ -d "$REPO_DIR" ] || die "no overlay repo: ${REPO_DIR#"$ROOT"/} — build it: make overlay"

# --- what the lock says must be installed ---------------------------------------------------
# Field 4 is the provenance class and field 1/2/3 reconstruct the filename, exactly as
# images/fetchlock.sh does it. Read with an explicit 5-field split so a future column cannot
# silently land in the last variable.
WANTED=()
while read -r name ver arch src _sha; do
  case "$name" in ''|'#'*) continue ;; esac
  [ "$src" = novadeck ] || continue
  WANTED+=("$name-$ver-$arch.pkg.tar.zst")
done < "$LOCK"
[ ${#WANTED[@]} -gt 0 ] || die "${LOCK#"$ROOT"/} has no novadeck rows — nothing to pin"

# ============================================================================================
# --write: record what is built right now
# ============================================================================================
if [ "$MODE" = write ]; then
  # Only artifacts the lock installs get a pin (see the header). Build the set once.
  declare -A INSTALLED=()
  for f in "${WANTED[@]}"; do INSTALLED["$f"]=1; done

  wrote=0
  for dir in "${PKGDIRS[@]}"; do
    pname="$(pin_field "$dir/source.pin" name)"
    [ -n "$pname" ] || die "${dir#"$ROOT"/}/source.pin: missing name"

    # The stamp is the ONLY mapping from a source pin to its artifacts — one PKGBUILD can emit
    # several and only the builder knows which. Reading it is legitimate here (see the header).
    [ -f "$STAMPS/$pname.files" ] \
      || die "$pname: no ${STAMPS#"$ROOT"/}/$pname.files — build it first: make overlay"

    lines=""
    n=0
    while read -r f; do
      [ -n "$f" ] || continue
      [ -n "${INSTALLED["$f"]:-}" ] || continue   # built but not installed: no pin needed
      [ -f "$REPO_DIR/$f" ] \
        || die "$pname: $f is in the lock and in $pname.files but missing from the repo — make overlay"
      sha="$(sha256sum "$REPO_DIR/$f" | cut -d' ' -f1)"
      lines+="artifact: $sha  $f"$'\n'
      n=$((n + 1))
    done < "$STAMPS/$pname.files"

    # A package that emits nothing the lock installs has no pin at all, rather than an empty one:
    # an empty pin file is indistinguishable from a truncated write.
    if [ "$n" -eq 0 ]; then
      log "$pname: no installed artifacts — no pin written"
      continue
    fi

    ihash="$("$ROOT/packages/inputhash.sh" "$dir")"
    {
      echo "# novadeck artifact pin — GENERATED by packages/verify-pins.sh --write, do not hand-edit."
      echo "#"
      echo "# The sha256 of each BUILT artifact this package contributes to the image. Reviewing a"
      echo "# change to this file is what makes a release build's bytes accountable — see the header"
      echo "# of packages/verify-pins.sh for what this claims and what it cannot."
      echo "#"
      echo "# inputhash ties these bytes to the sources that produced them (packages/inputhash.sh)."
      echo "# If it disagrees with the tree, the pin is STALE — the sources moved and no pin-bump PR"
      echo "# has landed yet — which is a different failure from bytes that do not match."
      echo "name: $pname"
      echo "inputhash: $ihash"
      printf '%s' "$lines"
    } > "$dir/artifact.pin"
    log "$pname: pinned $n artifact(s)"
    wrote=$((wrote + 1))
  done

  log "wrote $wrote artifact pin(s) — review the diff, then commit"
  exit 0
fi

# ============================================================================================
# verify (default)
# ============================================================================================
# Build filename -> "sha<TAB>package" and package -> declared input hash, from the PINS only.
declare -A PINSHA=() PINPKG=()
pinned_pkgs=0
for dir in "${PKGDIRS[@]}"; do
  pin="$dir/artifact.pin"
  [ -f "$pin" ] || continue
  pname="$(pin_field "$pin" name)"
  [ -n "$pname" ] || die "${pin#"$ROOT"/}: missing name"

  # STALE-PIN CHECK, and it comes first on purpose: if the sources moved, every byte mismatch
  # below is a consequence rather than a finding, and reporting ten of those instead of one
  # "your pin predates your sources" is how a clear failure becomes a confusing one.
  declared="$(pin_field "$pin" inputhash)"
  [ -n "$declared" ] || die "${pin#"$ROOT"/}: missing inputhash"
  actual="$("$ROOT/packages/inputhash.sh" "$dir")"
  if [ "$declared" != "$actual" ]; then
    echo "[pins] $pname: artifact pin is STALE — it describes different sources than the tree" >&2
    echo "         pin:  ${declared:0:16}" >&2
    echo "         tree: ${actual:0:16}   (source.pin + patches + PKGBUILD)" >&2
    echo "  The sources changed and no pin-bump has landed for them yet. A release build cannot" >&2
    echo "  vouch for bytes nobody has published or reviewed. Either:" >&2
    echo "    - push the source change and let .github/workflows/overlay.yml open the pin-bump PR" >&2
    echo "    - or build locally instead:  NOVADECK_DEV=1 make sdcard" >&2
    exit 1
  fi

  while read -r kind sha file; do
    [ "$kind" = "artifact:" ] || continue
    [ -n "$sha" ] && [ -n "$file" ] || die "${pin#"$ROOT"/}: malformed artifact line"
    PINSHA["$file"]="$sha"
    PINPKG["$file"]="$pname"
  done < "$pin"
  pinned_pkgs=$((pinned_pkgs + 1))
done

# Report every problem rather than dying on the first: a stale publish tends to move several
# artifacts at once, and fixing them one build at a time is the slow way to find that out.
unpinned=""
mismatched=""
verified=0
for f in "${WANTED[@]}"; do
  want="${PINSHA["$f"]:-}"
  if [ -z "$want" ]; then
    unpinned+="  $f"$'\n'
    continue
  fi
  [ -f "$REPO_DIR/$f" ] || die "$f: in the lock but missing from ${REPO_DIR#"$ROOT"/} — make overlay"
  got="$(sha256sum "$REPO_DIR/$f" | cut -d' ' -f1)"
  if [ "$got" != "$want" ]; then
    mismatched+="  ${PINPKG["$f"]}: $f"$'\n'"    pin: $want"$'\n'"    got: $got"$'\n'
    continue
  fi
  verified=$((verified + 1))
done

if [ -n "$unpinned" ]; then
  echo "[pins] a RELEASE build needs a reviewed sha for every overlay package it installs," >&2
  echo "       and these have no artifact pin:" >&2
  printf '%s' "$unpinned" >&2
  echo "  A release image is only built by CI, from artifacts the store published and a pin-bump" >&2
  echo "  PR recorded. To build from what you compiled here, use the dev path instead:" >&2
  echo "      NOVADECK_DEV=1 make sdcard" >&2
  echo "  To pin what is built here on purpose (then review the diff):" >&2
  echo "      packages/verify-pins.sh --write" >&2
  exit 1
fi

if [ -n "$mismatched" ]; then
  echo "[pins] BYTES DO NOT MATCH the reviewed pins:" >&2
  printf '%s' "$mismatched" >&2
  echo "  The sources agree (the stale-pin check above passed), so these are different bytes" >&2
  echo "  built from the same sources — which is expected for a LOCAL rebuild, because our builds" >&2
  echo "  are not bit-reproducible. If you compiled these yourself, either build the dev path:" >&2
  echo "      NOVADECK_DEV=1 make sdcard" >&2
  echo "  or swap the PINNED bytes back in, per package named above:" >&2
  echo "      rm work/repo/$ARCH/.stamps/<pkg>.hash && make overlay-pull" >&2
  echo "  Both halves matter. A bare overlay-pull is a NO-OP here — pull-all skips anything" >&2
  echo "  is_fresh() considers already built on this machine — and clean-overlay would go far" >&2
  echo "  too wide, deleting work/overlay-build (~5G of source trees, hours to rebuild)." >&2
  echo "  If you did NOT build these, a substitution is the other explanation and worth chasing." >&2
  exit 1
fi

log "$verified artifact(s) byte-verified against $pinned_pkgs pin(s)"
