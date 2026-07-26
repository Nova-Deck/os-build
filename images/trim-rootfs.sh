#!/usr/bin/env bash
# novadeck rootfs trimmer — delete build and documentation artefacts from the release root.
#
#   images/trim-rootfs.sh <staged-root>
#
# The size counterpart to images/seal-rootfs.sh, and deliberately a separate step: the seal is
# about what a sealed root can DO (it removes the package manager), this is about what it WEIGHS.
# Runs on the STAGED tree inside images/assemble-rootfs.sh, after the seal, so work/base keeps
# being a faithful record of what was installed and `make relock` is unaffected.
#
# WHAT IT REMOVES is declared in images/trim.list (committed, reviewed) — read that file first;
# this script is only the mechanism.
#
# WHY IT MATTERS under A/B: every megabyte on the release root is paid twice once Phase 4b lands
# — once in each of the two 7G slots, and again in every RAUC bundle that has to be downloaded
# onto a handheld over Wi-Fi. Headers, static libraries and man pages are not reachable from a
# read-only root that has no compiler and no terminal.
#
# The declaration is copied to /usr/lib/novadeck/trim.list, next to the seal's, so the image
# states what it no longer has — and images/guard-rootfs.sh re-expands that copy against the
# built tree and fails the build if anything it names survived.
#
# Not called under NOVADECK_TEST=1 — see images/assemble-rootfs.sh.
set -euo pipefail
# extglob and globstar are what the `glob` rows are written against; trim.list documents both.
shopt -s extglob globstar nullglob dotglob

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAGE="${1:?usage: images/trim-rootfs.sh <staged-root>}"
LIST="$ROOT/images/trim.list"

[ -d "$STAGE" ] || { echo "no staged root: $STAGE" >&2; exit 2; }
[ -f "$LIST" ] || { echo "no trim list: $LIST" >&2; exit 1; }

# Parse the declaration. Rejected up front: an absolute path or one containing `..`, either of
# which would let a typo in a committed list escape the staged tree and delete from the host.
# The rejection happens on the PATTERN, before any expansion, so a glob can never walk out either.
paths=() globs=()
while read -r kind value extra; do
  case "$kind" in ''|'#'*) continue ;; esac
  [ -n "$value" ] || { echo "$LIST: '$kind' row with no value" >&2; exit 1; }
  [ -z "$extra" ] || { echo "$LIST: unexpected extra field in '$kind $value $extra'" >&2; exit 1; }
  case "$value" in
    /*|*..*) echo "$LIST: refusing '$value' (must be root-relative, no ..)" >&2; exit 1 ;;
  esac
  case "$kind" in
    path) paths+=("$value") ;;
    glob) globs+=("$value") ;;
    *) echo "$LIST: unknown row kind '$kind' (want: path|glob)" >&2; exit 1 ;;
  esac
done < "$LIST"
[ $(( ${#paths[@]} + ${#globs[@]} )) -gt 0 ] || { echo "$LIST: no rows — refusing a no-op trim" >&2; exit 1; }

before_kib="$(du -sk "$STAGE" | cut -f1)"
echo "  trimming: ${#paths[@]} paths + ${#globs[@]} globs (images/trim.list)"

# `path` rows: whole directories. An absent one is reported rather than fatal — a package that
# stopped shipping its docs is not a reason to fail a build, and the row is still doing its job
# for every other package under that directory.
for p in "${paths[@]}"; do
  if [ -e "$STAGE/$p" ] || [ -L "$STAGE/$p" ]; then
    rm -rf "${STAGE:?}/$p"
  else
    echo "  trim: $p already absent" >&2
  fi
done

# `glob` rows: expanded relative to the stage, which is why this subshell cd's there — a pattern
# anchored at $STAGE would put the stage path itself through globbing, and a `[` or `*` anywhere
# in the build directory's own name would then change what the row means.
#
# A pattern matching NOTHING is fatal, unlike an absent `path`. The difference is what the two
# say when they go stale: an empty directory row still covers every other package under it, but
# an empty glob covers nothing at all — it is a row that has quietly stopped removing the thing
# it was written for (upstream renamed a soname, a package was dropped), and the only signal it
# will ever give is a build that silently got bigger.
glob_removed=0
for g in "${globs[@]}"; do
  # compgen -G, not eval: the pattern is expanded as a pathname pattern and nothing else, so a
  # row that somehow contained shell metacharacters is a pattern that matches nothing rather
  # than a command. extglob/globstar are shell options, so the subshell inherits them.
  matches=()
  while IFS= read -r m; do
    [ -n "$m" ] && matches+=("$m")
  done < <(cd "$STAGE" && compgen -G "$g" || true)
  [ "${#matches[@]}" -gt 0 ] || {
    echo "$LIST: pattern '$g' matches nothing in the staged tree — the list has drifted" >&2
    echo "  fix the pattern or drop the row; a glob that matches nothing removes nothing" >&2
    exit 1
  }
  for m in "${matches[@]}"; do
    # Re-check each EXPANSION, not just the pattern: a symlink inside the tree cannot make the
    # pattern absolute, but this costs nothing and keeps the invariant local to the deletion.
    case "$m" in /*|*..*) echo "$LIST: refusing expansion '$m' of '$g'" >&2; exit 1 ;; esac
    rm -rf "${STAGE:?}/$m"
    glob_removed=$((glob_removed + 1))
  done
done

# State on the image what the image no longer has, exactly as the seal does.
install -Dm0644 "$LIST" "$STAGE/usr/lib/novadeck/trim.list"

after_kib="$(du -sk "$STAGE" | cut -f1)"
echo "  trimmed: ${#paths[@]} paths, $glob_removed glob matches, $(( (before_kib - after_kib + 512) / 1024 ))MiB freed"
