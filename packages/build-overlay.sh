#!/usr/bin/env bash
# novadeck overlay package builder — rebuild holo packages FROM SOURCE with novadeck patches.
#
# For every packages/<name>/source.pin: fetch the holo PKGBUILD (raw, at the pinned commit —
# anonymous read), drop our patches in, bump pkgrel so the build outranks the holo binary, and
# `makepkg` it inside the pinned base-devel image under arm64 qemu emulation. The built
# packages + a repo db land in work/repo/<soc>/, a local pacman repo that customize-base.sh
# prepends ahead of the holo repos so the patched build is what actually gets installed.
#
# Host-side (drives docker, like customize-base.sh). Network required: the PKGBUILD comes from
# the GitLab raw endpoint and makepkg clones the actual sources from public GitHub/freedesktop.
# Reads base-devel.digest. Re-run is cheap to invoke but the emulated build itself is slow.
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

# Fresh staging + repo each run, so no stale package versions linger in work/repo/<soc>/.
rm -rf "$STAGE" "$REPO_DIR"; mkdir -p "$STAGE" "$REPO_DIR"

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

  bd="$STAGE/$name"; mkdir -p "$bd"
  if [ -n "$local_pb" ]; then
    # Local PKGBUILD: a novadeck-owned recipe checked in at packages/<name>/<pkgbuild_local>,
    # used when there is no suitable holo PKGBUILD to fetch (e.g. a version bump or a
    # driver-trimmed build the holo recipe doesn't cover). makepkg still pulls the upstream
    # source the PKGBUILD names (e.g. a release tarball) just the same.
    lpb="$pdir/$local_pb"
    [ -f "$lpb" ] || { echo "[overlay] $name: missing local PKGBUILD $lpb (declared in $pin)" >&2; exit 1; }
    echo "[overlay] $name: local PKGBUILD ${local_pb}" >&2
    cp "$lpb" "$bd/PKGBUILD"
  else
    : "${repo:?$pin: missing pkgbuild_repo}"
    : "${path:?$pin: missing pkgbuild_path}"; : "${ref:?$pin: missing pkgbuild_ref}"
    echo "[overlay] $name: fetch PKGBUILD ${repo}@${ref:0:12} ($path)" >&2
    curl -fsSL "$GL/$repo/-/raw/$ref/$path/PKGBUILD" -o "$bd/PKGBUILD"
  fi

  for p in $patches; do
    src="$pdir/patches/$p"
    [ -f "$src" ] || { echo "[overlay] $name: missing patch $src (declared in $pin)" >&2; exit 1; }
    cp "$src" "$bd/$p"
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
done

# Build inside the pinned base-devel image under arm64 emulation. makepkg refuses to run as
# root, so create an unprivileged builder with passwordless sudo (makepkg -s installs the
# makedepends via pacman). --skipinteg skips checksum validation for our added patch sources;
# the upstream gamescope is still pinned by the PKGBUILD's git #commit=<tag>.
if ! docker run --rm --platform linux/arm64 "$DEVEL_REF" /usr/bin/true >/dev/null 2>&1; then
  echo "[overlay] registering arm64 binfmt (qemu) via tonistiigi/binfmt" >&2
  docker run --privileged --rm tonistiigi/binfmt --install arm64 >&2
fi

echo "[overlay] building under arm64 qemu (this is slow — emulated C++ compile)" >&2
docker run --rm --platform linux/arm64 \
  -e HOSTUID="$(id -u)" -e HOSTGID="$(id -g)" \
  -v "$STAGE":/stage -v "$REPO_DIR":/repo "$DEVEL_REF" \
  bash -euo pipefail -c '
    useradd -m builder 2>/dev/null || true
    printf "builder ALL=(ALL) NOPASSWD: ALL\n" > /etc/sudoers.d/builder
    chmod 0440 /etc/sudoers.d/builder
    pacman -Sy --noconfirm
    chown -R builder /stage /repo
    for d in /stage/*/; do
      [ -f "$d/PKGBUILD" ] || continue
      echo "[overlay] makepkg in ${d}" >&2
      ( cd "$d" && sudo -u builder \
          makepkg -sf --noconfirm --nocheck --skipinteg --noprogressbar )
      cp "$d"/*.pkg.tar.zst /repo/
    done
    cd /repo
    repo-add novadeck.db.tar.zst *.pkg.tar.zst
    # Hand the artifacts back to the host build user so re-runs (the initial rm -rf) and
    # make clean-overlay work WITHOUT root — the container built them as root/builder.
    chown -R "$HOSTUID:$HOSTGID" /stage /repo
  ' >&2

echo "[overlay] built repo: ${REPO_DIR#"$ROOT"/}" >&2
ls -1 "$REPO_DIR"/*.pkg.tar.zst >&2
