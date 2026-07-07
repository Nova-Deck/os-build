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
# Host-side (drives docker, like customize-base.sh). Network required: the PKGBUILD comes from
# the GitLab raw endpoint and makepkg clones the actual sources from public GitHub/freedesktop.
# Reads base-devel.digest. Re-run is cheap to invoke but an emulated build itself is slow.
#
#   packages/build-overlay.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Overlay packages are ARCH-scoped, NOT SoC-scoped: a rebuilt holo package (e.g. gamescope) is a
# plain aarch64 binary every aarch64 SoC shares, so ONE build serves all devices — and the
# patches under packages/*/patches/ are generic too. ARCH matches the base-devel image platform;
# customize-base.sh reads this same work/repo/<arch>/ path no matter which SoC's base it builds.
ARCH="aarch64"
GL="https://gitlab.steamos.cloud"
REPO_DIR="$ROOT/work/repo/$ARCH"
STAMPS="$REPO_DIR/.stamps"
STAGE="$ROOT/work/overlay-build/$ARCH"
DEVEL_PIN="$ROOT/base-devel.digest"

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

  # Gather this package's input files (fail-fast on a missing patch / local PKGBUILD, same as
  # before) and hash them. The pin carries pkgbuild_ref, so a bumped holo PKGBUILD or upstream
  # source pin flows into the hash; anything makepkg fetches is downstream of these inputs.
  inputs=("$pin")
  for p in $patches; do
    src="$pdir/patches/$p"
    [ -f "$src" ] || { echo "[overlay] $name: missing patch $src (declared in $pin)" >&2; exit 1; }
    inputs+=("$src")
  done
  if [ -n "$local_pb" ]; then
    lpb="$pdir/$local_pb"
    [ -f "$lpb" ] || { echo "[overlay] $name: missing local PKGBUILD $lpb (declared in $pin)" >&2; exit 1; }
    inputs+=("$lpb")
  fi
  hash="$(sha256sum "${inputs[@]}" | sha256sum | cut -c1-64)"
  HASH["$name"]="$hash"

  if [ -f "$STAMPS/$name.hash" ] && [ "$(cat "$STAMPS/$name.hash")" = "$hash" ] \
     && [ -f "$STAMPS/$name.files" ]; then
    fresh=1
    while read -r f; do [ -n "$f" ] && [ -f "$REPO_DIR/$f" ] || { fresh=0; break; }; done < "$STAMPS/$name.files"
    if [ "$fresh" = 1 ]; then
      echo "[overlay] $name: up-to-date (${hash:0:12}) — skip" >&2
      continue
    fi
  fi
  echo "[overlay] $name: inputs changed / artifacts missing — will rebuild" >&2

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

if [ ${#BUILD_NAMES[@]} -eq 0 ]; then
  echo "[overlay] all overlay packages up-to-date — nothing to rebuild" >&2
  # Bump the db mtime so make sees $(OVERLAY_DB) as satisfied against the touched inputs and
  # does not keep re-invoking this script every build.
  [ -f "$REPO_DIR/novadeck.db.tar.zst" ] && touch "$REPO_DIR/novadeck.db.tar.zst"
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
echo "[overlay] building ${#BUILD_NAMES[@]} changed package(s) in isolated arm64 qemu containers (slow — emulated)" >&2
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
      chown -R builder "/stage/$PKG" /repo
      echo "[overlay] makepkg in /stage/$PKG" >&2
      ( cd "/stage/$PKG" && sudo -u builder \
          makepkg -sf --noconfirm --nocheck --skipinteg --noprogressbar )
      cp "/stage/$PKG"/*.pkg.tar.zst /repo/
      chown -R "$HOSTUID:$HOSTGID" "/stage/$PKG" /repo
    ' >&2

  # Record this package's artifacts and purge any it produced last time but no longer does
  # (e.g. a pkgver/pkgrel bump renamed the file) so stale versions never linger in the repo.
  # Only after a SUCCESSFUL build do we write the stamp — a failed build (set -e) leaves the
  # old hash so the next run retries.
  produced=("$STAGE/$name"/*.pkg.tar.zst)
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
echo "[overlay] indexing repo db" >&2
docker run --rm --platform linux/arm64 \
  -e HOSTUID="$(id -u)" -e HOSTGID="$(id -g)" \
  -v "$REPO_DIR":/repo "$DEVEL_REF" \
  bash -euo pipefail -c '
    cd /repo
    rm -f novadeck.db.tar.zst novadeck.db novadeck.files.tar.zst novadeck.files
    repo-add novadeck.db.tar.zst *.pkg.tar.zst
    chown -R "$HOSTUID:$HOSTGID" /repo
  ' >&2

echo "[overlay] built repo: ${REPO_DIR#"$ROOT"/}" >&2
ls -1 "$REPO_DIR"/*.pkg.tar.zst >&2
