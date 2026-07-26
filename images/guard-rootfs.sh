#!/usr/bin/env bash
# novadeck sealed-root guard — assert on the BUILT TREE (Phase 4a step 4).
#
#   images/guard-rootfs.sh <staged-root>
#
# The last thing that looks at a release root before it is frozen into rootfs.img. Everything
# earlier in Phase 4a is a declaration — the lock says what installs, seal.list says what is
# stripped — and a declaration that is never checked against the artifact it describes is a
# comment. This is the check.
#
# WHY ON THE TREE AND NOT ON THE SOURCE DIFF: this repo has already shipped a source change that
# was correct in the diff and wrong in the built tree (a file-mode regression that reached
# hardware and blacked out the OOBE). A guard that reads seal.list and seal-rootfs.sh and
# concludes they agree would have caught none of it. So every assertion below opens files in the
# staged tree.
#
# The staged tree IS the image: section 6 of images/assemble-rootfs.sh hands exactly this
# directory to `mkfs.btrfs --rootdir`, and /var is carved out of it into var.img. Nothing between
# here and there adds content. (The one gap: this asserts the tree, not the image bytes — reading
# a btrfs image back would need a mount, which the unprivileged build deliberately avoids.)
#
# RELEASE ONLY, like the seal itself. A NOVADECK_TEST tree keeps the package manager on purpose
# and carries TEST_PKGS that the lock does not describe, so most of this would be asserting the
# wrong thing. images/assemble-rootfs.sh calls this only on the release path.
#
# What it asserts:
#   1. the seal's declaration is fully applied — every file the stripped packages own is gone,
#      expanded from the preserved database rather than from a hand-kept list
#   2. the named package-manager entry points are gone (a short, human-legible belt that does not
#      depend on the database being honest)
#   3. no dangling systemd enable-symlink — the failure mode a package removal actually leaves
#      behind, and the one that would keep a stripped unit "enabled"
#   4. no build-provenance marker reached the tree (images/provenance.list) — a regression guard
#      against a container filesystem ever becoming a content source again
#   5. images/manifest.lock still describes this tree: same package set, same versions, and its
#      `stripped` rows are exactly what seal.list removes
#   6. a size delta against the previous build (report only — never fails a build)
set -euo pipefail
shopt -s nullglob

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAGE="${1:?usage: images/guard-rootfs.sh <staged-root>}"
LOCK="$ROOT/images/manifest.lock"
LIST="$STAGE/usr/lib/novadeck/seal.list"
DB="$STAGE/usr/lib/novadeck/pkgdb"
SIZES="$ROOT/out/images/rootfs.sizes"

[ -d "$STAGE" ] || { echo "no staged root: $STAGE" >&2; exit 2; }

fail=0
bad() { echo "  GUARD FAIL: $*" >&2; fail=1; }

echo "  guarding the sealed release root (images/guard-rootfs.sh)"

# Preconditions. Both artifacts are written by images/seal-rootfs.sh, so their absence means the
# seal did not run — and then assertion 1 would pass vacuously over an empty declaration, which is
# the one way a guard can be worse than no guard.
[ -f "$LIST" ] || { echo "  GUARD FAIL: no $LIST — the seal did not run on this tree" >&2; exit 1; }
[ -d "$DB" ]   || { echo "  GUARD FAIL: no $DB — the seal did not run on this tree" >&2; exit 1; }
[ -f "$LOCK" ] || { echo "  GUARD FAIL: no ${LOCK#"$ROOT"/}" >&2; exit 1; }

# ------------------------------------------------------------------------------------------
# 1. The declaration is fully applied.
#
# Read the seal list from the IMAGE, not from the repo: the image's own copy is what it claims
# about itself, and checking the repo copy instead would let a stale image pass against a freshly
# edited declaration. Each name is expanded through the preserved database exactly the way the
# sealer expanded it, so this catches a file the sealer skipped — not just a name it never saw.
# ------------------------------------------------------------------------------------------
desc_field() { sed -n "/^%$2%\$/{n;p;q}" "$1"; }

pkgs=() paths=()
while read -r kind value _; do
  case "$kind" in
    pkg)  pkgs+=("$value") ;;
    path) paths+=("$value") ;;
  esac
done < "$LIST"
[ "${#pkgs[@]}" -gt 0 ] || { echo "  GUARD FAIL: $LIST declares no packages" >&2; exit 1; }

checked=0
survivors=0
declare -A OWNED       # every file the stripped packages own — assertion 2 checks itself against it
for p in "${pkgs[@]}"; do
  dbdir=""
  for d in "$DB/$p"-*/; do
    [ -f "$d/desc" ] || continue
    [ "$(desc_field "$d/desc" NAME)" = "$p" ] || continue
    dbdir="$d"; break
  done
  # The database is what makes the expansion possible; a stripped package missing from it means
  # the provenance copy is incomplete, and assertion 1 silently stops covering that package.
  [ -n "$dbdir" ] || { bad "'$p' is on the removal list but has no entry under usr/lib/novadeck/pkgdb"; continue; }

  in_files=0
  while IFS= read -r rel; do
    case "$rel" in
      '%FILES%') in_files=1; continue ;;
      '%'*)      in_files=0; continue ;;
      ''|*/)     continue ;;              # directories are shared; the sealer only rmdirs empty ones
    esac
    [ "$in_files" = 1 ] || continue
    checked=$((checked + 1))
    OWNED["$rel"]=1
    # -e is false for a dangling symlink, so test -L too — a broken link left behind is exactly
    # the kind of leftover this is looking for.
    if [ -e "$STAGE/$rel" ] || [ -L "$STAGE/$rel" ]; then
      survivors=$((survivors + 1))
      [ "$survivors" -gt 10 ] || bad "$p still owns $rel"
    fi
  done < "$dbdir/files"
done
if [ "$survivors" -gt 10 ]; then bad "... and $((survivors - 10)) more files from stripped packages"; fi
if [ "$survivors" = 0 ]; then echo "    ok  ${#pkgs[@]} stripped packages: all $checked files gone"; fi

paths_bad=0
for p in "${paths[@]}"; do
  if [ -e "$STAGE/$p" ] || [ -L "$STAGE/$p" ]; then bad "declared path still present: $p"; paths_bad=1; fi
done
if [ "$paths_bad" = 0 ]; then echo "    ok  ${#paths[@]} declared paths gone"; fi

# ------------------------------------------------------------------------------------------
# 2. The named entry points, spelled out.
#
# Redundant with assertion 1 while the database is honest — and that is the point. Assertion 1
# trusts usr/lib/novadeck/pkgdb to say what a package owned; this list trusts nothing, so a
# truncated or wrong database cannot make the guard pass. These are also the names a person
# reviewing this file wants to see stated: the shutdown stall (dirmngr) and the ability of a
# running device to mutate its own read-only root (pacman).
# ------------------------------------------------------------------------------------------
NAMED=(
  usr/bin/pacman usr/bin/pacman-key usr/bin/pacman-conf usr/bin/makepkg usr/bin/repo-add
  usr/bin/gpg usr/bin/gpg-agent usr/bin/dirmngr usr/bin/gpgconf
  usr/lib/systemd/system/dirmngr@.service
  usr/lib/systemd/system/timers.target.wants/archlinux-keyring-wkd-sync.timer
  etc/pacman.conf etc/pacman.d var/lib/pacman
)
named_bad=0
for n in "${NAMED[@]}"; do
  if [ -e "$STAGE/$n" ] || [ -L "$STAGE/$n" ]; then bad "package-manager runtime survived: $n"; named_bad=1; fi
  # A hand-kept list of paths that must be absent is self-fulfilling if a name is misspelled: the
  # typo is absent from every tree ever built, so the line asserts nothing, forever. Require each
  # name to be something the declaration actually removes — owned by a stripped package, or under a
  # declared path row. This uses the database to validate the LIST, never to make the assertion.
  if [ -z "${OWNED["$n"]:-}" ]; then
    covered=0
    for p in "${paths[@]}"; do
      case "$n" in "$p"|"$p"/*) covered=1; break ;; esac
    done
    if [ "$covered" = 0 ]; then
      bad "guard names '$n', which images/seal.list does not remove — dead assertion (typo, or the list moved on)"
      named_bad=1
    fi
  fi
done
if [ "$named_bad" = 0 ]; then echo "    ok  no pacman/gnupg/dirmngr entry point, no /var/lib/pacman"; fi

# ------------------------------------------------------------------------------------------
# 3. No dangling systemd enable-symlink.
#
# Deleting a package's files deletes its units but NOT the .wants/.requires symlinks other
# packages (or we) point at them, and a vendor enable-symlink is precisely how the keyring's
# weekly timer stayed on in the first place. A link to a unit that no longer exists is systemd
# telling us the removal was incomplete.
#
# Scoped to .wants/.requires deliberately: the tree carries ~48 pre-existing dangling absolute
# symlinks elsewhere (all from the base image, none of them ours), so a whole-tree check would
# fail every build for a condition this step did not create. A mask (-> /dev/null) is valid.
# ------------------------------------------------------------------------------------------
wants_bad=0
wants_seen=0
while IFS= read -r -d '' w; do
  for l in "$w"/*; do
    [ -L "$l" ] || continue
    wants_seen=$((wants_seen + 1))
    t="$(readlink "$l")"
    [ "$t" = /dev/null ] && continue
    case "$t" in
      /*) target="$STAGE$t" ;;
      *)  target="$w/$t" ;;
    esac
    if [ ! -e "$target" ]; then
      bad "dangling enable-symlink: ${l#"$STAGE"/} -> $t"
      wants_bad=1
    fi
  done
done < <(find "$STAGE/usr/lib/systemd" "$STAGE/etc/systemd" \
              \( -name '*.wants' -o -name '*.requires' \) -type d -print0 2>/dev/null)
if [ "$wants_bad" = 0 ]; then echo "    ok  $wants_seen enable-symlinks, all resolve"; fi

# ------------------------------------------------------------------------------------------
# 4. No build-provenance marker reached the tree.
#
# Until Phase 4c the tree was `docker export` of a vendor-built image, so it started out carrying
# two other build systems' artifacts and the assembler had to scrub them; this was where that
# scrub stopped being a claim. The root is bootstrapped from packages now, so there is nothing to
# scrub and this assertion should never be able to fail — which is exactly why it is kept. The
# stakes are asymmetric: /.dockerenv makes systemd-detect-virt report a container on the real
# device and SILENTLY skip ~13 ConditionVirtualization=!container units (timesyncd the visible
# one), a failure that costs a HW debug cycle to find and that no build-time symptom shows. A
# stat per marker buys immunity to anyone reintroducing a container filesystem as a content
# source, so this is now a REGRESSION guard rather than the second half of a scrub.
#
# Read from the REPO, not from the image, unlike seal.list at assertion 1: this declaration lists
# what must be ABSENT, so there is nothing for the image to self-describe.
#
# The self-fulfilling case this shares with assertion 2 (a declared path that is never present in
# any tree, so the line asserts nothing forever) is NOT cross-checked here, and deliberately so:
# post-4c the correct state is that no marker is ever present, so there is no longer any tree in
# which one could be observed to validate the entry against.
# ------------------------------------------------------------------------------------------
PROV="$ROOT/images/provenance.list"
prov_bad=0
prov_seen=0
if [ -f "$PROV" ]; then
  while read -r marker _; do
    case "$marker" in ''|'#'*) continue ;; esac
    prov_seen=$((prov_seen + 1))
    if [ -e "$STAGE/$marker" ] || [ -L "$STAGE/$marker" ]; then
      bad "build-provenance marker survived into the image: $marker"
      prov_bad=1
    fi
  done < "$PROV"
  [ "$prov_bad" = 0 ] && echo "    ok  $prov_seen provenance markers absent"
else
  bad "no ${PROV#"$ROOT"/} — the provenance declaration is missing"
fi

# ------------------------------------------------------------------------------------------
# 5. The lock still describes this tree.
#
# The payoff of steps 1-3: images/manifest.lock is a committed, reviewed artifact, and this is
# where it stops being a claim. Two directions, both required —
#
#   set equality  every package the tree has is in the lock at the same version, and vice versa.
#                 A build that installs from the lock cannot drift, which is the argument for
#                 checking it rather than for not bothering: if it ever differs, something
#                 outside the locked install path put a package on the image.
#   stripped rows the lock's `stripped` class must be exactly seal.list's `pkg` rows. Those two
#                 files are edited by hand and are the pair that has to stay in step — the whole
#                 reason the lock carries the class at all is so ONE artifact describes the image.
#
# `prebuilt` rows are excluded: they are tarballs from packages/*/prebuilt.pin, not pacman
# packages, so they were never in a package database to begin with.
# ------------------------------------------------------------------------------------------
lock_set="$(awk '!/^#/ && NF && $4 != "prebuilt" { print $1 "-" $2 }' "$LOCK" | LC_ALL=C sort)"
tree_set="$(cd "$DB" && ls -1 | grep -vx 'ALPM_DB_VERSION' | LC_ALL=C sort)"
if [ "$lock_set" != "$tree_set" ]; then
  bad "images/manifest.lock does not describe this tree:"
  diff <(printf '%s\n' "$lock_set") <(printf '%s\n' "$tree_set") \
    | sed -n 's/^</    only in lock: /p; s/^>/    only in tree: /p' >&2 || true
  echo "    (regenerate with \`make relock\` and review the diff)" >&2
else
  echo "    ok  manifest.lock matches the tree ($(printf '%s\n' "$lock_set" | wc -l) packages)"
fi

lock_stripped="$(awk '!/^#/ && $4 == "stripped" { print $1 }' "$LOCK" | LC_ALL=C sort)"
list_stripped="$(printf '%s\n' "${pkgs[@]}" | LC_ALL=C sort)"
if [ "$lock_stripped" != "$list_stripped" ]; then
  bad "the lock's 'stripped' rows and seal.list disagree:"
  diff <(printf '%s\n' "$lock_stripped") <(printf '%s\n' "$list_stripped") \
    | sed -n 's/^</    only in lock: /p; s/^>/    only in seal.list: /p' >&2 || true
fi

# ------------------------------------------------------------------------------------------
# 6. Size delta (report only).
#
# Never fails a build — there is no defensible threshold, and a guard that blocks on growth would
# be disabled the first time a legitimate package got bigger. Its job is to put the number in
# front of whoever reads the build log, next to the assertions, so a 200 MiB jump is noticed in
# the build that caused it rather than when the slot stops fitting. Per top-level directory,
# because "the image grew" is not actionable and "usr grew" is.
# ------------------------------------------------------------------------------------------
measure() {
  du -sk "$STAGE" | awk '{print "TOTAL", $1}'
  # -type d rather than a `*/` glob: bin, sbin, lib and lib64 are usrmerge SYMLINKS into usr, and
  # a glob with a trailing slash makes du follow them — which counts usr's 8.5 GiB four extra
  # times and turns every real change under usr into five identical bogus deltas. TOTAL is du on
  # the tree itself, which does not follow them, so only the per-directory rows were ever wrong.
  while IFS= read -r d; do
    du -sk "$STAGE/$d" | awk -v n="$d" '{print n, $1}'
  done < <(find "$STAGE" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | LC_ALL=C sort)
}
new="$(measure)"

echo "    size: $(awk '$1=="TOTAL"{printf "%.1f MiB", $2/1024}' <<<"$new") staged"
if [ -f "$SIZES" ]; then
  # Report TOTAL always; per-directory only past 1 MiB, so ordinary churn stays quiet.
  awk -v prev="$SIZES" '
    BEGIN { while ((getline line < prev) > 0) { split(line, f, " "); if (f[1] !~ /^#/) old[f[1]] = f[2] } }
    { d = $2 - (($1 in old) ? old[$1] : 0)
      if ($1 == "TOTAL" || d >= 1024 || d <= -1024)
        printf "    delta %-14s %+8.1f MiB%s\n", $1, d/1024, (($1 in old) ? "" : "  (new)") }
  ' <<<"$new" >&2
  awk -v prev="$SIZES" '
    BEGIN { while ((getline line < prev) > 0) { split(line, f, " "); if (f[1] !~ /^#/) old[f[1]] = f[2] } }
    { seen[$1] = 1 }
    END { for (k in old) if (!(k in seen)) printf "    delta %-14s   GONE\n", k }
  ' <<<"$new" >&2
else
  echo "    (no previous build recorded — no delta)" >&2
fi
if [ "$fail" != 0 ]; then
  echo "  the sealed root does not match its declaration — refusing to build an image from it" >&2
  exit 1
fi

# Record the baseline only now. The delta above is printed either way (it is diagnostic, and most
# useful next to a failure), but a tree the guard just REJECTED must not become what the next
# build measures itself against — that would report the rejected tree's size as normal and hide
# the very change that caused the rejection.
#
# Best-effort write, deliberately: this is the guard's only side effect, and a report artifact must
# never be what fails a release build. (It is also what runs when someone points this script at a
# tree by hand outside the container, where out/ is root-owned.)
if ! { install -d -m0755 "$(dirname "$SIZES")" \
       && { echo "# novadeck staged-root sizes in KiB — written by images/guard-rootfs.sh, read as the next build's baseline."
            printf '%s\n' "$new"; } >"$SIZES"; } 2>/dev/null; then
  echo "    (could not record sizes to ${SIZES#"$ROOT"/} — next build reports no delta)" >&2
fi

echo "  guard passed"
