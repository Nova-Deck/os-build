#!/usr/bin/env bash
# novadeck overlay package builder — rebuild holo packages FROM SOURCE with novadeck patches.
#
# For every packages/<name>/source.pin: fetch the holo PKGBUILD (raw, at the pinned commit —
# anonymous read), drop our patches in, bump pkgrel so the build outranks the holo binary, and
# `makepkg` it inside the pinned base-devel image under arm64 qemu emulation. The built
# packages + a repo db land in work/repo/<arch>/, a local pacman repo that customize-base.sh
# prepends ahead of the holo repos so the patched build is what actually gets installed.
#
# INCREMENTAL: each package carries a content hash of ITS OWN inputs (source.pin + patches +
# local PKGBUILD) under work/repo/<arch>/.stamps/<name>.hash. A package is rebuilt only when
# that hash changes (or its built artifacts are missing) — so a one-line gamescope patch no
# longer drags mesa/sddm/… through a full emulated recompile. The repo db is re-indexed from
# whatever package artifacts are present. The Makefile still lists the union of all overlay
# inputs as $(OVERLAY_DB) prerequisites; that just re-triggers this (now cheap) script, which
# self-selects which packages actually need the slow build.
#
# That hash is computed by packages/inputhash.sh, NOT here, because it has a second job: it is
# also what rootfs/manifest.lock records for the `novadeck` rows (our builds are not
# bit-reproducible, so the lock pins the sources rather than the artifact bytes — see that script
# and rootfs/fetchlock.sh). Three readers, one formula.
#
# Host-side (drives docker, like customize-base.sh). Network required: the PKGBUILD comes from
# the GitLab raw endpoint and makepkg clones the actual sources from public GitHub/freedesktop.
# Reads build/base-devel.digest. Re-run is cheap to invoke but an emulated build itself is slow.
#
#   packages/build-overlay.sh [--only <name>]... [--no-index]
#
# --only    build ONLY the named package(s), instead of every package whose inputs changed.
#           Repeatable. This is what lets the CI compile pass fan out one package per job
#           (.github/workflows/overlay.yml) — the builds were already independent, since each runs
#           in its own fresh container. Handy locally too, to re-run a single slow package without
#           re-examining the rest.
# --no-index  skip the closing repo-add. A single-package job holds only its own artifacts, and
#           the index is rebuilt from scratch over EVERYTHING present — indexing there would
#           produce a db describing a subset. Whoever assembles the full repo indexes it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

ONLY=()
DO_INDEX=1
while [ $# -gt 0 ]; do
  case "$1" in
    --only) [ $# -ge 2 ] || { echo "--only needs a package name" >&2; exit 2; }; ONLY+=("$2"); shift 2 ;;
    --no-index) DO_INDEX=0; shift ;;
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument '$1' (try --help)" >&2; exit 2 ;;
  esac
done

# Is this package in the caller's --only filter? No filter means everything, which is the
# default `make overlay` behaviour and has to stay byte-identical.
selected() {
  [ ${#ONLY[@]} -eq 0 ] && return 0
  local n; for n in "${ONLY[@]}"; do [ "$n" = "$1" ] && return 0; done
  return 1
}

# Overlay packages are ARCH-scoped, NOT SoC-scoped: a rebuilt holo package (e.g. gamescope) is a
# plain aarch64 binary every aarch64 SoC shares, so ONE build serves all devices — and the
# patches under packages/*/patches/ are generic too. ARCH matches the base-devel image platform;
# customize-base.sh reads this same work/repo/<arch>/ path no matter which SoC's base it builds.
ARCH="aarch64"
GL="https://gitlab.steamos.cloud"
REPO_DIR="$ROOT/work/repo/$ARCH"
STAMPS="$REPO_DIR/.stamps"
STAGE="$ROOT/work/overlay-build/$ARCH"
DEVEL_PIN="$ROOT/build/base-devel.digest"

shopt -s nullglob
PINS=("$ROOT"/packages/*/source.pin)
if [ ${#PINS[@]} -eq 0 ]; then
  echo "[overlay] no packages/*/source.pin — nothing to build" >&2
  exit 0
fi

command -v docker >/dev/null 2>&1 || { echo "docker required for overlay build" >&2; exit 1; }
[ -f "$DEVEL_PIN" ] || { echo "no build-env pin: $DEVEL_PIN" >&2; exit 1; }
# Pin = last non-comment, non-blank line: an image ref ending in @sha256:<digest>.
DEVEL_REF="$(grep -vE '^[[:space:]]*(#|$)' "$DEVEL_PIN" | tail -1)"
case "$DEVEL_REF" in
  *@sha256:*) ;;
  *) echo "refusing unpinned base-devel ref (need ...@sha256:<digest>): '$DEVEL_REF'" >&2; exit 1 ;;
esac

pin_field() { sed -n "s/^$2:[[:space:]]*//p" "$1" | head -1; }

# Persist the repo + per-package stamps across runs (incremental); only re-stage what we rebuild.
mkdir -p "$STAGE" "$REPO_DIR" "$STAMPS"

# --- decide which packages need a (re)build ------------------------------------------------
# A package is up-to-date when its stored input hash matches AND every artifact it last produced
# is still present in the repo. Otherwise it is staged (PKGBUILD fetched/patched) and queued.
declare -A HASH        # name -> content hash of this package's inputs (recorded after a good build)
BUILD_NAMES=()

for pin in "${PINS[@]}"; do
  pdir="$(dirname "$pin")"
  name="$(pin_field "$pin" name)"
  repo="$(pin_field "$pin" pkgbuild_repo)"
  path="$(pin_field "$pin" pkgbuild_path)"
  ref="$(pin_field "$pin" pkgbuild_ref)"
  local_pb="$(pin_field "$pin" pkgbuild_local)"
  suffix="$(pin_field "$pin" pkgrel_suffix)"
  patches="$(pin_field "$pin" patches)"
  : "${name:?$pin: missing name}"

  # Hash this package's committed inputs (source.pin + its patches + a local PKGBUILD), fail-fast
  # on a missing one. The pin carries pkgbuild_ref, so a bumped holo PKGBUILD or upstream source
  # pin flows into the hash; anything makepkg fetches is downstream of these inputs.
  #
  # Delegated to packages/inputhash.sh rather than computed here, because this value is no longer
  # only a local cache key: rootfs/genmanifest.sh writes the same digest into manifest.lock as the
  # `novadeck` rows' pin and rootfs/fetchlock.sh re-derives it, so all three have to agree byte for
  # byte. That script also documents why it is deliberately path-independent — the formula that
  # used to be inlined here was not, which was harmless for a per-machine stamp and would have
  # quietly broken the lock across machines.
  hash="$("$ROOT/packages/inputhash.sh" "$pdir")"
  HASH["$name"]="$hash"

  # Filter AFTER hashing, not before: the hash is cheap (three sha256sums over committed files)
  # and computing it for every package keeps this loop's accounting — and any message it prints —
  # the same whether or not a filter is in play.
  if ! selected "$name"; then
    echo "[overlay] $name: not selected (--only) — skip" >&2
    continue
  fi

  # WHY this package is being built, distinguished rather than lumped together. The three reasons
  # mean very different things, and in CI only ever ONE of them is true:
  #
  #   not built here yet   no stamp at all — a fresh runner or a clean clone. Nothing CHANGED;
  #                        there is simply no previous build to compare against. This is the
  #                        normal case for every CI build now that the overlay is compiled in-run.
  #   inputs changed       source.pin, a patch or the local PKGBUILD moved. The dev-box case.
  #   artifact missing     the stamp agrees, but a file it names is gone from the repo.
  #
  # These shared one message until 2026-08-04 ("inputs changed / artifacts missing"), which was
  # tolerable while a store-pulled repo made the up-to-date path the CI norm — and actively
  # confusing now that it is not. That exact string also used to be a FAILURE signal: the retired
  # overlay.yml `verify` job grepped for it to assert a pulled repo had compiled nothing. Reading
  # it as an alarm is a trained reflex worth disarming, since it is now the expected output.
  why=""
  if [ ! -f "$STAMPS/$name.hash" ] || [ ! -f "$STAMPS/$name.files" ]; then
    why="not built in this tree yet"
  elif [ "$(cat "$STAMPS/$name.hash")" != "$hash" ]; then
    why="inputs changed ($(cut -c1-12 "$STAMPS/$name.hash") -> ${hash:0:12})"
  else
    # The stamp agrees, so the only way to need a build is a file it names being absent. Name the
    # FIRST one: "something is missing" without saying what sends you reading ten filenames.
    # A blank line counts as missing — it did before this change too (the old one-liner's
    # `[ -n "$f" ] && … || fresh=0` treated it that way), and a stamp that cannot say what it
    # produced is not a stamp to trust.
    while read -r f; do
      [ -n "$f" ] || { why="stamp has a blank artifact line"; break; }
      [ -f "$REPO_DIR/$f" ] || { why="artifact missing: $f"; break; }
    done < "$STAMPS/$name.files"
  fi
  if [ -z "$why" ]; then
    echo "[overlay] $name: up-to-date (${hash:0:12}) — skip" >&2
    continue
  fi
  echo "[overlay] $name: $why — building" >&2

  # Stage: fetch (or copy) the PKGBUILD, drop patches in, edit the PKGBUILD. Fresh per-package
  # staging dir so a re-stage never mixes with a prior attempt.
  bd="$STAGE/$name"; rm -rf "$bd"; mkdir -p "$bd"
  if [ -n "$local_pb" ]; then
    # Local PKGBUILD: a novadeck-owned recipe checked in at packages/<name>/<pkgbuild_local>,
    # used when there is no suitable holo PKGBUILD to fetch (e.g. a version bump or a
    # driver-trimmed build the holo recipe doesn't cover). makepkg still pulls the upstream
    # source the PKGBUILD names (e.g. a release tarball) just the same.
    echo "[overlay] $name: local PKGBUILD ${local_pb}" >&2
    cp "$pdir/$local_pb" "$bd/PKGBUILD"
  else
    : "${repo:?$pin: missing pkgbuild_repo}"
    : "${path:?$pin: missing pkgbuild_path}"; : "${ref:?$pin: missing pkgbuild_ref}"
    echo "[overlay] $name: fetch PKGBUILD ${repo}@${ref:0:12} ($path)" >&2
    curl -fsSL "$GL/$repo/-/raw/$ref/$path/PKGBUILD" -o "$bd/PKGBUILD"
  fi

  for p in $patches; do
    cp "$pdir/patches/$p" "$bd/$p"
  done

  # Edit the PKGBUILD: bump pkgrel, register our patches as local sources (so makepkg copies
  # them into $srcdir), and apply them right after the first `cd <dir>` in prepare().
  PATCHES="$patches" SUFFIX="$suffix" python3 - "$bd/PKGBUILD" <<'PY'
import os, re, sys
pkgbuild = sys.argv[1]
patches  = os.environ.get("PATCHES", "").split()
suffix   = os.environ.get("SUFFIX", "").strip()
lines    = open(pkgbuild).read().splitlines()

out, in_prepare, applied = [], False, False
for line in lines:
    m = re.match(r'^pkgrel=(\S+)', line)
    if m and suffix:
        out.append('pkgrel=%s.%s' % (m.group(1), suffix)); continue
    out.append(line)
    if re.match(r'^prepare\s*\(\)', line):
        in_prepare = True
    if in_prepare and not applied and re.match(r'^\s*cd\s+\S+', line):
        for p in patches:
            out.append('  patch -p1 < "$srcdir/%s"' % p)
        applied = True

text = "\n".join(out) + "\n"
if patches:
    text += "\nsource+=(%s)\n" % " ".join("'%s'" % p for p in patches)
open(pkgbuild, "w").write(text)
if patches and not applied:
    sys.stderr.write("ERROR: no 'cd <dir>' found in prepare(); cannot place patch step\n")
    sys.exit(3)
PY
  BUILD_NAMES+=("$name")
done

# Foreign-arch artifacts left in this arch-scoped repo by an older build (see the index step at
# the end of this file). They are not a package whose inputs changed, so nothing above selects
# them for rebuild — but leaving them indexed is exactly the bug, so their presence alone has to
# be enough to reach the re-index below.
stale_foreign=0
for f in "$REPO_DIR"/*.pkg.tar.zst; do
  case "$f" in
    *-"$ARCH".pkg.tar.zst|*-any.pkg.tar.zst) ;;
    *) stale_foreign=$((stale_foreign + 1)) ;;
  esac
done

# The db's presence is part of this condition, and it stays that way even though the case that
# forced it is gone. A repo pulled from the retired GHCR store arrived with every stamp fresh and
# NO db, because the index was rebuilt locally rather than shipped — a state this early exit never
# used to anticipate. Any other route to fresh-stamps-no-db (a deleted db, an interrupted index)
# lands in exactly the same trap, so the `-f` test earns its place on its own.
#
# Without the `-f` test, that state took this branch and the script exited 0 having built NOTHING
# and indexed nothing: it printed "all overlay packages up-to-date" and "repo: <dir>", which reads
# as a completely successful run. (The bare `[ -f ... ] && touch` was not itself fatal — `set -e`
# exempts a failing AND-OR list — it just quietly did nothing.) The damage landed later and
# elsewhere: make's $(OVERLAY_DB) target does not exist after a recipe that succeeded, so
# $(OVERLAY_STAMP)'s sha256sum fails, or customize-base.sh's "no usable overlay repo" check fires.
# Falling through to the index step instead is both the fix and exactly what a freshly pulled repo
# needs: one cheap container, no compiles.
if [ ${#BUILD_NAMES[@]} -eq 0 ] && [ "$stale_foreign" -eq 0 ] \
   && [ -f "$REPO_DIR/novadeck.db.tar.zst" ]; then
  echo "[overlay] all overlay packages up-to-date — nothing to rebuild" >&2
  # Bump the db mtime so make sees $(OVERLAY_DB) as satisfied against the touched inputs and
  # does not keep re-invoking this script every build.
  touch "$REPO_DIR/novadeck.db.tar.zst"
  echo "[overlay] repo: ${REPO_DIR#"$ROOT"/}" >&2
  exit 0
fi

# Build inside the pinned base-devel image under arm64 emulation. makepkg refuses to run as
# root, so create an unprivileged builder with passwordless sudo (makepkg -s installs the
# makedepends via pacman). --skipinteg skips checksum validation for our added patch sources;
# the upstream gamescope is still pinned by the PKGBUILD's git #commit=<tag>.
if ! docker run --rm --platform linux/arm64 "$DEVEL_REF" /usr/bin/true >/dev/null 2>&1; then
  echo "[overlay] registering arm64 binfmt (qemu) via tonistiigi/binfmt" >&2
  docker run --privileged --rm tonistiigi/binfmt --install arm64 >&2
fi

# ONE FRESH CONTAINER PER PACKAGE. An earlier design built every package in a single shared
# container (one `pacman -Sy`, then a loop over /stage/*/). That poisoned the LAST build, sddm:
# its Qt6 find_package failed with Qt6Quick -> Qt6QmlMeta -> Qt6QmlWorkerScript all NOT FOUND,
# even though sddm builds fine in isolation with the exact same cmake 4.1.2 + qt6 6.10 (proven:
# the standalone build-sddm-only.sh, and a clean-container configure probe). The makedepends
# installed for gamescope/gtk2/mesa left the container in a state that broke sddm's transitive
# Qt6 module resolution. Isolating each build removes that cross-contamination at the cost of a
# per-package dep re-sync (the emulated compile dwarfs it anyway).
if [ ${#BUILD_NAMES[@]} -eq 0 ]; then
  echo "[overlay] no package changed — re-indexing only ($stale_foreign foreign-arch artifact(s) to drop)" >&2
else
  echo "[overlay] building ${#BUILD_NAMES[@]} changed package(s) in isolated arm64 qemu containers (slow — emulated)" >&2
fi
for name in "${BUILD_NAMES[@]}"; do
  echo "[overlay] === build $name (isolated container) ===" >&2
  docker run --rm --platform linux/arm64 \
    -e HOSTUID="$(id -u)" -e HOSTGID="$(id -g)" -e PKG="$name" \
    -v "$STAGE":/stage -v "$REPO_DIR":/repo "$DEVEL_REF" \
    bash -euo pipefail -c '
      useradd -m builder 2>/dev/null || true
      printf "builder ALL=(ALL) NOPASSWD: ALL\n" > /etc/sudoers.d/builder
      chmod 0440 /etc/sudoers.d/builder
      pacman -Sy --noconfirm
      # PKGDEST separates what makepkg PRODUCED from what it merely DOWNLOADED. Without it the
      # copy below is a glob over the build directory, which also matches source packages a
      # PKGBUILD fetches: packages/fex-emu assembles an Arch x86 sysroot in prepare() from pinned
      # archive.archlinux.org packages, so six x86_64 .pkg.tar.zst (glibc, gcc, libstdc++,
      # lib32-*, linux-api-headers) were being copied in and repo-add`ed as installable [novadeck]
      # packages. Inert while the root arrived pre-populated by `docker export` — those names were
      # already installed, so --needed skipped them — but a from-packages bootstrap (Phase 4c)
      # resolves them for real and picks the overlay glibc 2.43 over the snapshot`s 2.42.
      mkdir -p "/stage/$PKG/out"
      chown -R builder "/stage/$PKG" /repo
      echo "[overlay] makepkg in /stage/$PKG" >&2
      ( cd "/stage/$PKG" && sudo -u builder \
          env PKGDEST="/stage/$PKG/out" \
          makepkg -sf --noconfirm --nocheck --skipinteg --noprogressbar )
      cp "/stage/$PKG/out"/*.pkg.tar.zst /repo/
      chown -R "$HOSTUID:$HOSTGID" "/stage/$PKG" /repo
    ' >&2

  # Record this package's artifacts and purge any it produced last time but no longer does
  # (e.g. a pkgver/pkgrel bump renamed the file) so stale versions never linger in the repo.
  # Only after a SUCCESSFUL build do we write the stamp — a failed build (set -e) leaves the
  # old hash so the next run retries.
  produced=("$STAGE/$name"/out/*.pkg.tar.zst)
  new_basenames=(); for f in "${produced[@]}"; do new_basenames+=("$(basename "$f")"); done
  if [ -f "$STAMPS/$name.files" ]; then
    while read -r old; do
      [ -n "$old" ] || continue
      keep=0; for b in "${new_basenames[@]}"; do [ "$b" = "$old" ] && keep=1 && break; done
      [ "$keep" = 0 ] && rm -f "$REPO_DIR/$old"
    done < "$STAMPS/$name.files"
  fi
  printf '%s\n' "${new_basenames[@]}" > "$STAMPS/$name.files"
  printf '%s\n' "${HASH[$name]}"      > "$STAMPS/$name.hash"
done

# Re-index the repo db from ALL present artifacts (repo-add is an arm64 tool). Rebuild it from
# scratch each time so entries for purged/renamed packages never linger. Hand the artifacts back
# to the host build user so re-runs and make clean-overlay work WITHOUT root.
#
# This repo is ARCH-SCOPED (work/repo/$ARCH), so an artifact for another architecture in it is
# wrong by construction — index only $ARCH and `any`, and DELETE anything else rather than leave
# a file the db no longer mentions. That is a second line behind the PKGDEST fix above: PKGDEST
# stops foreign packages arriving, this clears the ones an older build already deposited (the
# fex-emu x86 sysroot) without waiting for a fex-emu rebuild to purge them by file manifest.
#
# --no-index exists BECAUSE this step is global. A per-package CI job holds only its own
# artifacts, so indexing there would write a db describing a subset — and the foreign-arch purge
# above would delete every OTHER package's artifacts as "not mine" if they ever shared a workspace.
# The job publishes its package and stops; the consumer that reassembles the full repo indexes it.
if [ "$DO_INDEX" -eq 0 ]; then
  echo "[overlay] --no-index: skipping the repo db (caller will index the assembled repo)" >&2
else
echo "[overlay] indexing repo db" >&2
docker run --rm --platform linux/arm64 \
  -e HOSTUID="$(id -u)" -e HOSTGID="$(id -g)" -e ARCH="$ARCH" \
  -v "$REPO_DIR":/repo "$DEVEL_REF" \
  bash -euo pipefail -c '
    cd /repo
    shopt -s nullglob
    for f in *.pkg.tar.zst; do
      case "$f" in
        *-"$ARCH".pkg.tar.zst|*-any.pkg.tar.zst) ;;
        *) echo "[overlay] dropping foreign-arch artifact from an $ARCH repo: $f" >&2; rm -f "$f" ;;
      esac
    done
    rm -f novadeck.db.tar.zst novadeck.db novadeck.files.tar.zst novadeck.files
    repo-add novadeck.db.tar.zst *.pkg.tar.zst
    chown -R "$HOSTUID:$HOSTGID" /repo
  ' >&2
fi

# NOTE: we do NOT advance work/repo/<arch>/.overlay.stamp here. The Makefile's $(OVERLAY_STAMP) rule
# owns it, keyed on the CONTENT hash of the re-indexed novadeck.db — so a real re-index (db content
# changed) advances the stamp and rebuilds the base within the SAME make run, while the db-mtime bump
# on a no-op run (above) does not cascade. Touching it here too was redundant AND could only advance
# it as a side effect the same make invocation never re-stat'd (the stale-mtime miss the rule fixes).
echo "[overlay] built repo: ${REPO_DIR#"$ROOT"/}" >&2
ls -1 "$REPO_DIR"/*.pkg.tar.zst >&2
