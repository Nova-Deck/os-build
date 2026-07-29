#!/usr/bin/env bash
# novadeck overlay package store — publish/retrieve built overlay packages, keyed by their inputs.
#
#   packages/overlay-store.sh plan [--force] [name...]   JSON matrix of packages not in the store
#   packages/overlay-store.sh key   <name>               print the input hash for one package
#   packages/overlay-store.sh ref   <name> [hash]        print the registry reference
#   packages/overlay-store.sh have  <name> [hash]        exit 0 iff the store already has it
#   packages/overlay-store.sh push  <name> [hash]        publish this package's built artifacts
#   packages/overlay-store.sh pull  <name> [hash]        fetch them into work/repo/<arch>/
#   packages/overlay-store.sh push-all [name...]         publish everything built and current
#   packages/overlay-store.sh pull-all [name...]         fetch everything missing (never fatal)
#
# WHY THIS EXISTS. `make overlay` is the most expensive thing in this build — a cold run compiles
# ~8 packages under arm64 emulation, and fex-emu alone dominates. Every consumer (a CI runner, a
# second machine, a future image pipeline) used to pay that from scratch. This makes the build a
# ONE-TIME cost per source change: build once, publish, and every later consumer pulls the bytes.
#
# THE KEY IS packages/inputhash.sh, NOT A VERSION OR A GIT SHA. That digest already covers exactly
# the files that determine a build (source.pin + its patches + a local PKGBUILD) and is already
# path-independent by construction, because images/manifest.lock records it and a developer's
# checkout has to agree with a runner's workspace. So it is a content address that was already
# lying around: same hash <=> same sources <=> the published artifacts are the ones you would have
# built. A fourth reader of the one formula, and it must agree with the other three.
#
# WHAT THIS IS NOT. It is a CACHE, not a provenance mechanism. images/manifest.lock still pins the
# `novadeck` rows to their SOURCES and images/fetchlock.sh still re-derives that hash from
# packages/ — neither is touched by this script, and a pull miss is never fatal (we fall back to
# building). The BYTE claim is made elsewhere: .github/workflows/overlay.yml records each published
# artifact's sha256 into packages/*/artifact.pin through a reviewed pin-bump PR, and
# packages/verify-pins.sh enforces it on release builds. A registry digest was never that claim —
# `oras pull` says "I got what the registry holds", not "a reviewer approved this".
#
# `.stamps/<name>.files` IS PART OF THE PAYLOAD, not an afterthought. One PKGBUILD can emit
# several packages (mesa emits five), and that list is the ONLY mapping from a source pin to its
# artifacts — images/genmanifest.sh and images/fetchlock.sh both hard-fail without it. A pull that
# restored only the .pkg.tar.zst files would leave build-overlay.sh unable to call the package
# fresh, and the whole point is that it can.
#
# NO SHA SIDECAR, deliberately: a registry content-addresses every blob it stores, so `oras pull`
# already verifies the bytes it hands back against the digests in the manifest. Adding our own
# checksum file would be a second, weaker copy of a check that is already load-bearing.
#
# Host-side, like its siblings build-overlay.sh and customize-base.sh. PULLING NEEDS NO
# CREDENTIALS — the packages are public, so a fresh clone can retrieve without a token, a login,
# or gh(1). Only push does, and only push touches the network as a writer.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Must match packages/build-overlay.sh: the overlay repo is ARCH-scoped, one aarch64 build serving
# every aarch64 device. The registry path carries the arch too, so an arm64 repo can never be
# reconstituted from some other arch's artifacts by a tag collision.
ARCH="aarch64"
REPO_DIR="$ROOT/work/repo/$ARCH"
STAMPS="$REPO_DIR/.stamps"
ORAS_PIN="$ROOT/packages/oras.pin"

# GHCR namespace. Overridable so a fork can publish to its own account without editing tracked
# files — the hash is what identifies the content, the registry is just where it happens to live.
REGISTRY="${NOVADECK_OVERLAY_REGISTRY:-ghcr.io/nova-deck/novadeck-overlay}"

# OCI media types. `artifactType` is what makes this a novadeck artifact rather than a container
# image, so a registry UI (and anything else that walks the namespace) can tell them apart.
ARTIFACT_TYPE="application/vnd.novadeck.overlay.package.v1+json"
PKG_MEDIA="application/vnd.novadeck.overlay.pkg.v1.tar+zstd"
FILES_MEDIA="application/vnd.novadeck.overlay.files.v1+text"
# The artifact-list file, as it is named INSIDE the OCI artifact. Kept distinct from the on-disk
# `.stamps/<name>.files` name so an unpacked payload is self-describing.
FILES_NAME="novadeck-artifacts.txt"

log() { printf '[store] %s\n' "$*" >&2; }
die() { printf '[store] %s\n' "$*" >&2; exit 1; }

pin_field() { sed -n "s/^$2:[[:space:]]*//p" "$1" | head -1; }

# --- oras, pinned ---------------------------------------------------------------------------
# Fetched to work/tools/ and verified against packages/oras.pin rather than installed from a
# distro repo or resolved by a marketplace action. Same reasoning as base-devel.digest: the tool
# that moves our artifacts should not float between a runner and a developer's box.
oras_bin() {
  local ver url sha host dest tgz
  [ -f "$ORAS_PIN" ] || die "no oras pin: $ORAS_PIN"
  ver="$(pin_field "$ORAS_PIN" version)"
  case "$(uname -m)" in
    x86_64)         host=amd64 ;;
    aarch64|arm64)  host=arm64 ;;
    *) die "no pinned oras for $(uname -m) — add it to $ORAS_PIN" ;;
  esac
  url="$(pin_field "$ORAS_PIN" "url_$host")"
  sha="$(pin_field "$ORAS_PIN" "sha256_$host")"
  [ -n "$ver" ] && [ -n "$url" ] && [ -n "$sha" ] || die "$ORAS_PIN: missing version/url/sha for $host"

  dest="$ROOT/work/tools/oras-$ver-$host/oras"
  if [ ! -x "$dest" ]; then
    log "fetching oras $ver ($host)"
    mkdir -p "$(dirname "$dest")"
    tgz="$(mktemp)"
    curl -fsSL "$url" -o "$tgz" || die "oras $ver: download failed ($url)"
    # Verify BEFORE extracting: a tarball is executed-adjacent code, and checking it after
    # unpacking would mean the bad bytes already reached the filesystem.
    echo "$sha  $tgz" | sha256sum -c --status - \
      || { rm -f "$tgz"; die "oras $ver: sha256 mismatch against $ORAS_PIN"; }
    tar -xzf "$tgz" -C "$(dirname "$dest")" oras
    rm -f "$tgz"
    chmod +x "$dest"
  fi
  printf '%s\n' "$dest"
}

ORAS=""
# NOVADECK_OVERLAY_PLAIN_HTTP=1 talks to an unencrypted registry. Only for a throwaway local
# `registry:2` — which is how this store's round trip (push -> wipe -> pull -> index) can be
# exercised end to end without publishing anything. Never set it against a real registry: it
# sends the push credential in the clear.
oras() {
  [ -n "$ORAS" ] || ORAS="$(oras_bin)"
  if [ -n "${NOVADECK_OVERLAY_PLAIN_HTTP:-}" ]; then
    case "$1" in
      push|pull|login|manifest|blob|repo|tag) "$ORAS" "$@" --plain-http; return ;;
    esac
  fi
  "$ORAS" "$@"
}

# --- package identity -----------------------------------------------------------------------
pkg_dir() {
  local d="$ROOT/packages/$1"
  [ -f "$d/source.pin" ] || die "$1: no packages/$1/source.pin (not a from-source overlay package)"
  printf '%s\n' "$d"
}

# The one formula, delegated — see the header. Never reimplement it here.
# The `|| exit` matters: pkg_dir's die() runs inside the command substitution, so its exit status
# is all that reaches here — without this, a bad name printed a good message and then handed an
# EMPTY path to inputhash.sh, which failed again with a confusing usage error.
pkg_hash() { local d; d="$(pkg_dir "$1")" || exit 1; "$ROOT/packages/inputhash.sh" "$d"; }

# GHCR rejects uppercase in a repository path, and the org is spelled `Nova-Deck` upstream, so
# lowercase defensively rather than relying on whoever set the override to remember.
pkg_ref() {
  local name="$1" hash="${2:-}"
  [ -n "$hash" ] || hash="$(pkg_hash "$name")"
  printf '%s\n' "$(printf '%s/%s-%s:%s' "$REGISTRY" "$name" "$ARCH" "$hash" | tr '[:upper:]' '[:lower:]')"
}

# Resolve the caller's optional name filter into NAMES[], in the stable order the pins glob in
# (matching build-overlay.sh) when no filter is given.
#
# POPULATES A GLOBAL IN THE CURRENT SHELL, on purpose. The obvious `while read < <(select_names)`
# form put this in a process substitution, where a bad name's `exit 1` killed only that subshell:
# the caller's loop then finished normally, so `plan nosuchpkg` printed an error AND emitted a
# valid empty matrix with exit 0 — a typo in a workflow_dispatch input would have produced a green
# "nothing to build" run. Validation has to be able to abort the whole command.
NAMES=()
resolve_names() {
  local n p
  if [ "$#" -eq 0 ]; then
    shopt -s nullglob
    for p in "$ROOT"/packages/*/source.pin; do NAMES+=("$(pin_field "$p" name)"); done
  else
    for n in "$@"; do pkg_dir "$n" >/dev/null; NAMES+=("$n"); done
  fi
  [ ${#NAMES[@]} -gt 0 ] || die "no from-source overlay packages selected"
}

# --- store operations -----------------------------------------------------------------------
# Ask the registry about one package and CLASSIFY the answer, because "we could not get it" hides
# two very different problems behind one symptom:
#
#   0  present
#   1  absent — the store genuinely does not have this input hash. Normal: build it.
#   2  UNREADABLE — it may well be there, but this caller is not allowed to see it. A GHCR package
#      created by a first push is PRIVATE even in a public repo, which made every pull look like a
#      plain miss and sent the CI verify job off to recompile all 8 packages instead of saying
#      "permission denied". One bit of classification, one clear message.
#   3  something else (network, DNS, registry down)
probe() {
  local ref="$1" err rc=0
  err="$(oras manifest fetch --descriptor "$ref" 2>&1 >/dev/null)" || rc=$?
  [ "$rc" -eq 0 ] && return 0
  case "$err" in
    *[Uu]nauthorized*|*401*|*[Dd]enied*|*403*|*"authentication required"*) return 2 ;;
    *"not found"*|*404*|*"name unknown"*|*"manifest unknown"*|*NAME_UNKNOWN*|*MANIFEST_UNKNOWN*) return 1 ;;
    *) log "registry error for $ref: $err"; return 3 ;;
  esac
}

have() {
  local ref; ref="$(pkg_ref "$1" "${2:-}")"
  probe "$ref"
}

# Publish one package. Requires the LOCAL build to be current for the hash being published —
# publishing artifacts that were built from other sources is the one failure this store must not
# have, since nothing downstream can detect it (the hash is the only claim).
push_one() {
  local name="$1" hash="${2:-}" ref stage f n=0
  [ -n "$hash" ] || hash="$(pkg_hash "$name")"
  ref="$(pkg_ref "$name" "$hash")"

  [ -f "$STAMPS/$name.files" ] || die "$name: no $STAMPS/$name.files — build it first: make overlay"
  # The stamp is the builder's claim about what it just built. For PUSH (unlike fetchlock's read
  # path) that claim is exactly the right thing to check: it is what says these bytes on disk came
  # from these sources, and a mismatch means the tree moved since the build.
  [ -f "$STAMPS/$name.hash" ] || die "$name: no $STAMPS/$name.hash — build it first: make overlay"
  local built; built="$(cat "$STAMPS/$name.hash")"
  if [ "$built" != "$hash" ]; then
    die "$name: built artifacts are stale (repo ${built:0:12}, tree ${hash:0:12}) — rebuild: make overlay"
  fi

  # Hardlink into a staging dir: oras pushes paths relative to its cwd, and we want the artifact
  # to carry bare filenames rather than work/repo/... Staged UNDER work/ on purpose — a hardlink
  # cannot cross filesystems, and with a /tmp staging dir (often its own tmpfs) every push would
  # silently fall through to copying the whole ~140MB artifact set instead.
  mkdir -p "$ROOT/work"
  stage="$(mktemp -d -p "$ROOT/work" .overlay-push.XXXXXX)"
  trap 'rm -rf "$stage"' RETURN
  while read -r f; do
    [ -n "$f" ] || continue
    [ -f "$REPO_DIR/$f" ] || die "$name: $f listed in $name.files but missing from the repo — rebuild: make overlay"
    ln -f "$REPO_DIR/$f" "$stage/$f" 2>/dev/null || cp "$REPO_DIR/$f" "$stage/$f"
    n=$((n + 1))
  done < "$STAMPS/$name.files"
  [ "$n" -gt 0 ] || die "$name: $name.files is empty — rebuild: make overlay"
  cp "$STAMPS/$name.files" "$stage/$FILES_NAME"

  log "push $name ${hash:0:12} ($n artifact(s)) -> $ref"
  ( cd "$stage"
    args=("$FILES_NAME:$FILES_MEDIA")
    while read -r f; do [ -n "$f" ] && args+=("$f:$PKG_MEDIA"); done < "$FILES_NAME"
    oras push --artifact-type "$ARTIFACT_TYPE" \
      --annotation "org.opencontainers.image.source=https://github.com/Nova-Deck/os-build" \
      --annotation "org.opencontainers.image.revision=${GITHUB_SHA:-$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)}" \
      --annotation "vnd.novadeck.overlay.package=$name" \
      --annotation "vnd.novadeck.overlay.inputhash=$hash" \
      --annotation "vnd.novadeck.overlay.arch=$ARCH" \
      "$ref" "${args[@]}" >&2
  ) || die "$name: push failed. Publishing needs a credential the pull path does not.

  CI needs nothing extra: the workflow's GITHUB_TOKEN with \`permissions: packages: write\` works.

  LOCALLY, GHCR wants a CLASSIC personal access token — \`gh auth token\` returns a gho_ OAuth
  token, which authenticates (blob uploads succeed!) and is then refused at the manifest with
  'the token provided does not match expected scopes'. That message is about the token TYPE as
  much as its scopes, so adding write:packages to the gh token does not fix it. Create a classic
  PAT with write:packages (+ delete:packages only if you also want to prune), then:

      export NOVADECK_GHCR_TOKEN=ghp_...
      packages/overlay-store.sh login
      make overlay-publish

  Publishing from here is an OPTIMISATION, not a requirement — it just pre-seeds the store so CI
  does not have to build everything on its first run. Skipping it is fine."
}

# Retrieve one package. Writes the stamps LAST and only once every artifact the payload promised
# has landed, so an interrupted pull leaves the package looking un-built (and gets rebuilt) rather
# than looking fresh with files missing.
pull_one() {
  local name="$1" hash="${2:-}" ref tmp f n=0
  [ -n "$hash" ] || hash="$(pkg_hash "$name")"
  ref="$(pkg_ref "$name" "$hash")"

  # Same filesystem as the repo, so the moves below are renames rather than a second copy of
  # every artifact (see the note in push_one).
  mkdir -p "$ROOT/work"
  tmp="$(mktemp -d -p "$ROOT/work" .overlay-pull.XXXXXX)"
  trap 'rm -rf "$tmp"' RETURN
  log "pull $name ${hash:0:12} <- $ref"
  oras pull "$ref" -o "$tmp" >&2 || return 1
  [ -f "$tmp/$FILES_NAME" ] || { log "$name: payload has no $FILES_NAME — refusing it"; return 1; }

  while read -r f; do
    [ -n "$f" ] || continue
    [ -f "$tmp/$f" ] || { log "$name: payload promised $f but did not carry it — refusing it"; return 1; }
    n=$((n + 1))
  done < "$tmp/$FILES_NAME"
  [ "$n" -gt 0 ] || { log "$name: payload lists no artifacts — refusing it"; return 1; }

  mkdir -p "$REPO_DIR" "$STAMPS"
  while read -r f; do [ -n "$f" ] && mv -f "$tmp/$f" "$REPO_DIR/$f"; done < "$tmp/$FILES_NAME"
  cp "$tmp/$FILES_NAME" "$STAMPS/$name.files"
  printf '%s\n' "$hash" > "$STAMPS/$name.hash"
  log "$name: $n artifact(s) restored"
}

# Is this package already built and current on THIS machine? Same test build-overlay.sh applies,
# so a "fresh" answer here means that script will skip it too.
is_fresh() {
  local name="$1" hash="$2" f
  [ -f "$STAMPS/$name.hash" ] && [ "$(cat "$STAMPS/$name.hash")" = "$hash" ] || return 1
  [ -f "$STAMPS/$name.files" ] || return 1
  while read -r f; do
    [ -z "$f" ] || [ -f "$REPO_DIR/$f" ] || return 1
  done < "$STAMPS/$name.files"
}

# --- subcommands ----------------------------------------------------------------------------
cmd="${1:-}"; shift 2>/dev/null || true
case "$cmd" in

  key)  [ $# -ge 1 ] || die "usage: $0 key <name>";  pkg_hash "$1" ;;
  ref)  [ $# -ge 1 ] || die "usage: $0 ref <name> [hash]"; pkg_ref "$1" "${2:-}" ;;
  have) [ $# -ge 1 ] || die "usage: $0 have <name> [hash]"; have "$1" "${2:-}" ;;
  push) [ $# -ge 1 ] || die "usage: $0 push <name> [hash]"; push_one "$1" "${2:-}" ;;
  pull) [ $# -ge 1 ] || die "usage: $0 pull <name> [hash]"; pull_one "$1" "${2:-}" || die "$1: pull failed" ;;

  # Log in for push. Separate subcommand rather than something push does implicitly: writing a
  # credential into ~/.docker/config.json is a side effect on the caller's machine, and it should
  # happen because they asked, not as a surprise inside a build.
  login)
    tok="${NOVADECK_GHCR_TOKEN:-${GITHUB_TOKEN:-}}"
    if [ -z "$tok" ]; then
      command -v gh >/dev/null 2>&1 || die "no token: set NOVADECK_GHCR_TOKEN, or install gh"
      tok="$(gh auth token)"
    fi
    # The GitHub LOGIN, not git's user.name — that is a display name ("Philippe Simons"), and a
    # value with a space is not a usable registry username. GHCR largely ignores the username when
    # the password is a token, but sending a wrong one turns a scope problem into a confusing
    # credential problem.
    user="${GITHUB_ACTOR:-}"
    [ -n "$user" ] && : || user="$(gh api /user --jq .login 2>/dev/null || echo novadeck)"
    printf '%s' "$tok" | oras login "${REGISTRY%%/*}" -u "$user" --password-stdin >&2
    ;;

  # JSON matrix for the CI build job: the packages the store does NOT already have. This is what
  # makes a re-run free — an unchanged package is not a fast build, it is no build at all. Emitted
  # here rather than assembled in YAML so it can be run and read on a developer's box.
  plan)
    force=0
    if [ "${1:-}" = "--force" ]; then force=1; shift; fi
    resolve_names "$@"
    first=1; out='{"include":['
    for name in "${NAMES[@]}"; do
      h="$(pkg_hash "$name")"
      if [ "$force" -eq 0 ] && have "$name" "$h"; then
        log "$name ${h:0:12}: already published — skip"
        continue
      fi
      [ "$first" -eq 1 ] || out+=','
      out+="$(printf '{"pkg":"%s","hash":"%s"}' "$name" "$h")"
      first=0
      log "$name ${h:0:12}: NOT in the store — will build"
    done
    # Built up and printed in one go so the JSON on stdout can never be interleaved with the
    # progress lines on stderr when both land in the same terminal or log.
    printf '%s]}\n' "$out"
    ;;

  push-all)
    resolve_names "$@"
    pushed=0; skipped=0; stale=0
    for name in "${NAMES[@]}"; do
      h="$(pkg_hash "$name")"
      if have "$name" "$h"; then log "$name ${h:0:12}: already published — skip"; skipped=$((skipped+1)); continue; fi
      # A package this machine has not built (or has built from other sources) is skipped rather
      # than fatal: seeding the store from a dev box is a normal partial operation.
      if ! is_fresh "$name" "$h"; then
        log "$name ${h:0:12}: not built here from these sources — skip (make overlay to build it)"
        stale=$((stale+1)); continue
      fi
      push_one "$name" "$h"; pushed=$((pushed+1))
    done
    log "push-all: $pushed pushed, $skipped already present, $stale not built here"
    ;;

  # NEVER FATAL. This is a cache: a miss means the caller builds instead, which is slow, not
  # wrong. The one thing it will not do is leave a half-restored package looking complete.
  pull-all)
    # --require-all turns a miss from "fine, build it" into an ERROR, and it exists because the
    # lenient default put a guard in the wrong place. CI's verify job used to run `make
    # overlay-pull && make overlay` and then grep the BUILD LOG to discover that nothing had been
    # pulled — so it reported the failure only after recompiling everything it was meant to prove
    # unnecessary, ~20min to say what this line knows in seconds. Normal local use stays lenient:
    # there, a miss genuinely does mean "compile it".
    require_all=0
    if [ "${1:-}" = "--require-all" ]; then require_all=1; shift; fi
    resolve_names "$@"
    got=0; fresh=0; miss=0; denied=0; broke=0
    for name in "${NAMES[@]}"; do
      h="$(pkg_hash "$name")"
      if is_fresh "$name" "$h"; then log "$name ${h:0:12}: already built here — skip"; fresh=$((fresh+1)); continue; fi
      st=0; probe "$(pkg_ref "$name" "$h")" || st=$?
      case "$st" in
        0) if pull_one "$name" "$h"; then got=$((got+1)); else
             # Present in the registry but the payload did not survive the transfer intact. Not a
             # cache miss — something is wrong with what was published.
             log "$name ${h:0:12}: in the store but could not be restored intact"
             broke=$((broke+1))
           fi ;;
        2) log "$name ${h:0:12}: PERMISSION DENIED — the package is not readable by this caller."
           log "  A GHCR package is PRIVATE when first created, even in a public repo. Make it"
           log "  public (or link it to the repo) — pulling is supposed to need no credentials."
           denied=$((denied+1)) ;;
        1) log "$name ${h:0:12}: not in the store"; miss=$((miss+1)) ;;
        *) log "$name ${h:0:12}: registry unreachable"; broke=$((broke+1)) ;;
      esac
    done
    log "pull-all: $got restored, $fresh already local, $miss absent, $denied unreadable, $broke failed"
    if [ "$require_all" -eq 1 ]; then
      [ $((miss + denied + broke)) -eq 0 ] || die "--require-all: $((miss + denied + broke)) package(s) could not be retrieved (see above)"
    elif [ $((miss + denied + broke)) -gt 0 ]; then
      log "note: $((miss + denied + broke)) package(s) will be compiled locally — slow but correct"
    fi
    ;;

  ''|-h|--help|help)
    sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  *) die "unknown subcommand '$cmd' (try: $0 help)" ;;
esac
