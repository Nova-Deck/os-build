#!/usr/bin/env bash
# novadeck rootfs sealer — strip the package manager from the release root (Phase 4a step 3).
#
#   rootfs/seal-rootfs.sh <staged-root>
#
# Runs on the STAGED tree inside rootfs/assemble-rootfs.sh, not on work/base. That placement is
# deliberate: work/base stays a faithful record of what was installed, so rootfs/genmanifest.sh
# can keep reading its package database and `make relock` is unaffected. The seal applies to what
# ships, once, per build — there is no sealed tree lying around for a later build to reuse.
#
# WHAT IT REMOVES is declared in rootfs/conf/seal.list (committed, reviewed) — read that file first;
# this script is only the mechanism. In short: pacman, gnupg (and therefore dirmngr), the keyring
# package with its vendor-enabled weekly refresh timer, and the generated pacman state.
#
# WHY IT MATTERS beyond dead weight: the keyring package ships an enable-symlink under
# usr/lib/systemd/system/timers.target.wants/, which no preset can disable. When that timer fires
# it activates dirmngr@etc-pacman.d-gnupg, which then ignores SIGTERM at shutdown and burns its
# full 90s stop timeout — the "a stop job is running for GnuPG network certificate management
# daemon" stall. Deleting the daemon is the fix; masking it would leave the runtime on the image.
#
# PROVENANCE IS PRESERVED, NOT DESTROYED: the local package database is MOVED to
# /usr/lib/novadeck/pkgdb before anything is deleted — out of every path a package manager would
# consult, but still on the image, so a device can still answer "what was I built from". The
# removal list is copied alongside it as /usr/lib/novadeck/seal.list, so the image also states
# what it no longer has. rootfs/genmanifest.sh reads the same list and marks those rows
# `stripped` in rootfs/manifest.lock, so one artifact describes the real image.
#
# Not called under NOVADECK_DEV=1 — see rootfs/assemble-rootfs.sh.
set -euo pipefail
shopt -s nullglob

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAGE="${1:?usage: rootfs/seal-rootfs.sh <staged-root>}"
LIST="$ROOT/rootfs/conf/seal.list"
DB="$STAGE/var/lib/pacman/local"
KEEP="$STAGE/usr/lib/novadeck/pkgdb"

[ -d "$STAGE" ] || { echo "no staged root: $STAGE" >&2; exit 2; }
[ -f "$LIST" ] || { echo "no removal list: $LIST" >&2; exit 1; }
[ -d "$DB" ] || { echo "no package database under $STAGE (already sealed?)" >&2; exit 1; }

# Parse the declaration. Rejected up front: an absolute path or one containing `..`, either of
# which would let a typo in a committed list escape the staged tree and delete from the host.
pkgs=() paths=()
while read -r kind value extra; do
  case "$kind" in ''|'#'*) continue ;; esac
  [ -n "$value" ] || { echo "$LIST: '$kind' row with no value" >&2; exit 1; }
  [ -z "$extra" ] || { echo "$LIST: unexpected extra field in '$kind $value $extra'" >&2; exit 1; }
  case "$kind" in
    pkg)  pkgs+=("$value") ;;
    path)
      case "$value" in
        /*|*..*) echo "$LIST: refusing path '$value' (must be root-relative, no ..)" >&2; exit 1 ;;
      esac
      paths+=("$value") ;;
    *) echo "$LIST: unknown row kind '$kind' (want: pkg|path)" >&2; exit 1 ;;
  esac
done < "$LIST"
[ "${#pkgs[@]}" -gt 0 ] || { echo "$LIST: no pkg rows — refusing a no-op seal" >&2; exit 1; }

desc_field() { sed -n "/^%$2%\$/{n;p;q}" "$1"; }

# Resolve each declared name to its database directory BEFORE anything moves. The glob is by
# prefix, so `pacman-*` also matches pacman-mirrorlist — the %NAME% check is what makes the
# match exact. A declared package that is not installed means the list has drifted from the
# tree, which is exactly the silent divergence this step exists to prevent: fail loudly.
dbdirs=()
for p in "${pkgs[@]}"; do
  found=""
  for d in "$DB/$p"-*/; do
    [ -f "$d/desc" ] || continue
    [ "$(desc_field "$d/desc" NAME)" = "$p" ] || continue
    found="$(basename "$d")"; break
  done
  [ -n "$found" ] || {
    echo "${LIST#"$ROOT"/} declares '$p' but it is not installed in the staged tree" >&2
    echo "  the removal list has drifted — drop the row or fix the name" >&2
    exit 1
  }
  dbdirs+=("$found")
done

before_kib="$(du -sk "$STAGE" | cut -f1)"
echo "  sealing: stripping ${#pkgs[@]} packages + ${#paths[@]} paths (rootfs/conf/seal.list)"

# Preserve the database first: everything below reads its file lists, and `var/lib/pacman` is
# itself on the removal list.
install -d -m0755 "$STAGE/usr/lib/novadeck"
mv "$DB" "$KEEP"

# Remove each package's own files. Directories the package listed are collected rather than
# deleted here: they are shared (usr/bin/, usr/share/) and only the ones that end up empty may
# go, which is a single rmdir pass after every removal has happened.
files_removed=0
dirs=()
for d in "${dbdirs[@]}"; do
  in_files=0
  while IFS= read -r rel; do
    case "$rel" in
      '%FILES%') in_files=1; continue ;;   # the section we want
      '%'*)      in_files=0; continue ;;   # %BACKUP% et al: path + checksum, not a file list
      '')        continue ;;
    esac
    [ "$in_files" = 1 ] || continue
    case "$rel" in
      /*|*..*) echo "$d/files: refusing entry '$rel'" >&2; exit 1 ;;
      */)      dirs+=("$rel"); continue ;;
    esac
    # -e is false for a dangling symlink, so test -L too, or a broken link survives the seal.
    if [ -e "$STAGE/$rel" ] || [ -L "$STAGE/$rel" ]; then
      rm -f "$STAGE/$rel"
      files_removed=$((files_removed + 1))
    fi
  done < "$KEEP/$d/files"
done

# Generated state no package owns.
for p in "${paths[@]}"; do
  if [ -e "$STAGE/$p" ]; then
    rm -rf "${STAGE:?}/$p"
  else
    echo "  seal: $p already absent" >&2
  fi
done

# Reverse-sorted so children precede parents (usr/bin/ before usr/), and rmdir refuses a
# non-empty directory — so a path another package still occupies is left alone by construction.
dirs_removed=0
if [ "${#dirs[@]}" -gt 0 ]; then
  mapfile -t sorted < <(printf '%s\n' "${dirs[@]}" | LC_ALL=C sort -ru)
  for d in "${sorted[@]}"; do
    if rmdir "$STAGE/$d" 2>/dev/null; then dirs_removed=$((dirs_removed + 1)); fi
  done
fi

# State on the image what the image no longer has.
install -Dm0644 "$LIST" "$STAGE/usr/lib/novadeck/seal.list"

after_kib="$(du -sk "$STAGE" | cut -f1)"
echo "  sealed: $files_removed files, $dirs_removed empty dirs, $(( (before_kib - after_kib + 512) / 1024 ))MiB freed"
echo "  package db preserved -> /usr/lib/novadeck/pkgdb ($(du -sh "$KEEP" | cut -f1))"
