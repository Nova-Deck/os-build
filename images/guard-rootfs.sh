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
# RELEASE ONLY, like the seal itself. A NOVADECK_DEV tree keeps the package manager on purpose
# and carries DEV_PKGS that the lock does not describe, so most of this would be asserting the
# wrong thing. images/assemble-rootfs.sh calls this only on the release path.
#
# What it asserts:
#   1. the seal's declaration is fully applied — every file the stripped packages own is gone,
#      expanded from the preserved database rather than from a hand-kept list
#   2. the named package-manager entry points are gone (a short, human-legible belt that does not
#      depend on the database being honest)
#   3. no dangling systemd enable-symlink — the failure mode a package removal actually leaves
#      behind, and the one that would keep a stripped unit "enabled"
#   4. images/manifest.lock still describes this tree: same package set, same versions, and its
#      `stripped` rows are exactly what seal.list removes
#   5. the trim's declaration is fully applied — nothing images/trim.list names survived
#   6. the first-boot identity is shippable — no /etc/machine-id, AND systemd-firstboot masked
#      (the two are only safe together)
#   7. the RAUC update path is installable — rauc, the keyring, system.conf and this slot's
#      own boot.img are all present, and the hook that consumes them is executable;
#   8. the system UID/GID allocation matches the pin — the ids baked into this tree's passwd and
#      group are the ones fs-overlay's sysusers.d pin names, not whatever sysusers counted down to
#   9. a size delta against the previous build (report only — never fails a build)
set -euo pipefail
shopt -s nullglob

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAGE="${1:?usage: images/guard-rootfs.sh <staged-root>}"
LOCK="$ROOT/images/manifest.lock"
LIST="$STAGE/usr/lib/novadeck/seal.list"
TRIMLIST="$STAGE/usr/lib/novadeck/trim.list"
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
# 4. The lock still describes this tree.
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
# 5. The trim's declaration is fully applied.
#
# Same argument as assertion 1, for the other declaration: images/trim.list is edited by hand,
# and a trim that half-ran (or did not run at all) leaves an image that is simply bigger than
# intended — the one failure mode with no symptom until a slot stops fitting, by which point the
# build that caused it is long past.
#
# Read from the IMAGE's copy, like the seal list, so a stale tree cannot pass against a freshly
# edited declaration in the repo. Globs are expanded exactly as the trimmer expanded them
# (extglob + globstar, relative to the tree), inside a subshell so those options cannot leak into
# the plain globs the rest of this script uses.
# ------------------------------------------------------------------------------------------
[ -f "$TRIMLIST" ] || { echo "  GUARD FAIL: no $TRIMLIST — the trim did not run on this tree" >&2; exit 1; }

trim_paths=() trim_globs=()
while read -r kind value _; do
  case "$kind" in
    path) trim_paths+=("$value") ;;
    glob) trim_globs+=("$value") ;;
  esac
done < "$TRIMLIST"
[ $(( ${#trim_paths[@]} + ${#trim_globs[@]} )) -gt 0 ] \
  || { echo "  GUARD FAIL: $TRIMLIST declares no rows" >&2; exit 1; }

trim_bad=0
for p in "${trim_paths[@]}"; do
  if [ -e "$STAGE/$p" ] || [ -L "$STAGE/$p" ]; then bad "trimmed path still present: $p"; trim_bad=1; fi
done
for g in "${trim_globs[@]}"; do
  # `|| true` is load-bearing and NOT defensive noise: compgen -G exits 1 when the pattern matches
  # nothing, which is precisely the case this assertion wants to pass. Under `set -euo pipefail`
  # that status propagated out and killed the guard with no output at all — a passing image
  # failing its own build, silently. mapfile from a process substitution keeps the status of the
  # expansion out of the shell's error handling entirely.
  mapfile -t survivors < <( (shopt -s extglob globstar dotglob; cd "$STAGE" && compgen -G "$g") || true )
  if [ "${#survivors[@]}" -gt 0 ]; then
    bad "trim pattern '$g' still matches ${#survivors[@]} path(s): ${survivors[*]:0:5}"
    trim_bad=1
  fi
done
if [ "$trim_bad" = 0 ]; then
  echo "    ok  ${#trim_paths[@]} trimmed paths + ${#trim_globs[@]} patterns, all gone"
fi

# ------------------------------------------------------------------------------------------
# 6. First-boot identity.
#
# Asserts a PAIR, because either half alone is a defect:
#
#   - /etc/machine-id must be ABSENT. systemd's first-boot detection keys on it, so a populated one
#     means preset-all never runs (the 60-novadeck-*.preset files silently do nothing) and
#     gen-mac.sh's seed chain never falls through to the per-unit SoC serial, giving every unit
#     flashed from the image the same Wi-Fi MAC. This was true of a shipped image and nothing
#     caught it: the 4c bootstrap generates one (systemd's scriptlet, mode 0444), while two
#     comments asserted it would not exist. Exactly the "declaration nobody checks" failure this
#     script exists for — the reason it is checked here and not trusted from assemble-rootfs.sh.
#
#   - systemd-firstboot.service must be MASKED. Removing machine-id is what makes
#     ConditionFirstBoot=yes true, and that unit then prompts for locale and a root password on a
#     console with no usable input, blocking sysinit.target forever on a device with no serial
#     console. So a tree with no machine-id and no mask is a BRICKED BOOT, not a cosmetic slip.
#
# Checked independently rather than as an either/or, so the log names whichever half is wrong.
# `if` context throughout: a bare `[ ... ] && x=1` that evaluates false returns 1 and, under
# `set -e`, kills the guard with no output — the same trap already documented in assertion 5.
# ------------------------------------------------------------------------------------------
echo "  6. first-boot identity"
MID="$STAGE/etc/machine-id"
FB="$STAGE/etc/systemd/system/systemd-firstboot.service"

mid_ok=1
if [ -e "$MID" ] || [ -L "$MID" ]; then
  mid_ok=0
  bad "/etc/machine-id is present ($(wc -c <"$MID" 2>/dev/null || echo '?') bytes) — first boot will not be treated as one: preset-all will not run, and every unit gets the same derived Wi-Fi MAC"
fi

fb_ok=0
if [ -L "$FB" ] && [ "$(readlink "$FB")" = /dev/null ]; then
  fb_ok=1
else
  bad "systemd-firstboot.service is not masked — with no /etc/machine-id it will run and block sysinit.target forever on a console with no input (no serial console on this device)"
fi

if [ "$mid_ok" = 1 ] && [ "$fb_ok" = 1 ]; then
  echo "    ok  no /etc/machine-id, systemd-firstboot masked"
fi

# ------------------------------------------------------------------------------------------
# 7. The RAUC update path is installable.
#
# Every part of an A/B update is inert until something needs it, and each missing piece fails at a
# different and unhelpful moment: no `rauc` binary is a missing command at install time; a missing
# keyring means bundles verify against NOTHING while still reporting success; a missing stage-1/2
# boot mirror under /usr/lib/novadeck/boot means the post-install hook cannot refresh the ESP and
# the slot's efi partition, so the updated slot boots a boot chain that does not match it.
#
# lib-slotwrite.sh is on the list because the hook SOURCES it: since the primitives were factored out
# for the internal installer to share, a root without it has a post-install that dies on its first
# line. RAUC would then report a failed install of a slot it had already written -- recoverable, but
# only from the other slot, and the build is the cheap place to notice.
#
# The exec bit on the hook is checked because it is exactly the failure this project has already
# paid for once: a shipped script that lost its exec bit in a tree refactor, where the symptom was
# a black screen rather than an error (see fs-overlay/README.md).
# ------------------------------------------------------------------------------------------
echo "  7. RAUC update path"
rauc_ok=1
for f in usr/bin/rauc etc/rauc/keyring.pem etc/rauc/system.conf \
         usr/bin/steamos-bootconf \
         usr/lib/systemd/system/novadeck-boot-good.service \
         usr/lib/systemd/system/novadeck-boot-bad.service \
         usr/lib/novadeck/boot/steamcl.efi usr/lib/novadeck/boot/steamcl-version \
         usr/lib/novadeck/boot/grubaa64.efi usr/lib/novadeck/boot/grub-a.cfg \
         usr/lib/novadeck/boot/grub-b.cfg \
         usr/lib/novadeck/boot/fonts/dejavu-mono.pf2 \
         boot/Image boot/initramfs-novadeck.img \
         usr/lib/rauc/post-install.sh \
         usr/lib/novadeck/install/lib-slotwrite.sh; do
  if [ ! -s "$STAGE/$f" ]; then
    rauc_ok=0
    bad "/$f is missing or empty — the A/B update path is not installable"
  fi
done
if [ -e "$STAGE/usr/lib/rauc/post-install.sh" ] && [ ! -x "$STAGE/usr/lib/rauc/post-install.sh" ]; then
  rauc_ok=0
  bad "/usr/lib/rauc/post-install.sh is not executable — RAUC would report a successful install of a slot that was never finished"
fi
# btrfstune is what re-randomises the target slot's fsid. Without it the hook dies mid-install,
# and a slot that shares an fsid with the running root can silently hand you the wrong filesystem.
if [ ! -s "$STAGE/usr/bin/btrfstune" ]; then
  rauc_ok=0
  bad "/usr/bin/btrfstune is missing — the post-install hook cannot re-randomise the target slot's fsid"
fi

# --- what the INTERNAL INSTALLER reads out of this root ------------------------------------------
# Separate from the list above because nothing on the A/B update path touches these, so an update
# would keep working with every one of them missing. They are read by the installer running from the
# recovery medium, which writes an ESP that does not exist yet: the constants it cannot mint on the
# device, out of the root whose boot chain they belong to.
#
# grubenv is the shared ESP's stage-2 env block, where `save_env` puts the user's board choice. It
# ships prebuilt because grub-editenv is not on this image and 1024 bytes of constant do not justify
# putting it there (boot/grub.sh emits it and asserts it is pristine). The 1024 is re-checked here
# because it is the length nothing downstream complains about: grub_envblk_open only requires the
# signature to FIT, so a short block reads back perfectly and is simply not the object a card carries.
if [ ! -s "$STAGE/usr/lib/novadeck/boot/grubenv" ]; then
  bad "/usr/lib/novadeck/boot/grubenv is missing — an internal install cannot seed the ESP's stage-2 env block, and the device has no grub-editenv to mint one"
elif [ "$(wc -c <"$STAGE/usr/lib/novadeck/boot/grubenv")" != 1024 ]; then
  bad "/usr/lib/novadeck/boot/grubenv is $(wc -c <"$STAGE/usr/lib/novadeck/boot/grubenv") bytes, not 1024 — it would read back fine and still not match what a card carries"
else
  echo "    ok  installer artifacts: grubenv (1024 B, pristine)"
fi

# var-seed.tar.zst is the /var a freshly installed slot starts from. The OTA path has no use for it
# — it rsyncs the running /var — so nothing but an install would ever notice it missing, and what
# an install would do instead is boot a slot whose /var is empty: no machine-id, no overlay upper,
# no /etc. Listed, not just stat'd, because the two things that must NOT be in it are absences, and
# an absence is what a `-s` check cannot see:
#
#   lib/novadeck/slot     per-slot, written by seed_var after unpacking. Baked in, it would be a
#                         second answer to "which slot is this" — and that file exists precisely to
#                         be the INDEPENDENT witness against the initramfs's own claim.
#   lib/novadeck/mac-wifi write-once and outranks the derivation, so a seeded copy would hand every
#                         installed device the same Wi-Fi MAC. Two on one network is the symptom.
seed="$STAGE/usr/lib/novadeck/var-seed.tar.zst"
if [ ! -s "$seed" ]; then
  bad "/usr/lib/novadeck/var-seed.tar.zst is missing — an internal install has no /var to seed a fresh slot with, and there is no running system to copy one from"
elif ! seed_list=$(tar -tf "$seed" 2>/dev/null); then
  bad "/usr/lib/novadeck/var-seed.tar.zst is not readable as a tar archive — is zstd in the build container?"
else
  seed_bad=0
  for f in ./lib/novadeck/slot ./lib/novadeck/mac-wifi; do
    if printf '%s\n' "$seed_list" | grep -qx -- "$f"; then
      seed_bad=1
      bad "var-seed.tar.zst carries $f — it is per-device/per-slot state and must be written after unpacking, not baked in"
    fi
  done
  # And the one directory whose absence is unrecoverable: the initramfs mounts /etc from the overlay
  # upper, so a slot seeded without it does not come up at all.
  printf '%s\n' "$seed_list" | grep -qx -- './lib/overlays/etc/upper/' \
    || { seed_bad=1; bad "var-seed.tar.zst has no ./lib/overlays/etc/upper/ — a slot seeded from it cannot mount /etc and will not boot"; }
  [ "$seed_bad" = 0 ] && echo "    ok  installer artifacts: var-seed.tar.zst ($(du -h "$seed" | cut -f1), no per-slot state, overlay upper present)"
fi

# --- the two halves of adaptive streaming, both of which fail SILENTLY --------------------------
# Adaptive updates (images/rauc/manifest.raucm.in) cut a release-to-release OTA from 3.90G to ~125M
# measured, but every way of losing them degrades to "a full download that still succeeds". Nothing
# goes red on the device, nothing goes red in CI, and the only symptom is a bill and a slow update.
# So they are asserted here, where a wrong answer is a build failure.
#
# 1. rauc must be BUILT with streaming. It is on by default upstream and packages/rauc/PKGBUILD
#    passes plain arch-meson, so this holds today -- but a bump that touches meson_options.txt, or a
#    distro that flips the default, would take it away with no other trace. The binary prints its
#    own feature set (`1.15.2 create=1 ... streaming=1`), so grep it out of the shipped artefact
#    rather than trusting the recipe: what matters is the aarch64 binary in the tree, not what the
#    PKGBUILD asked for.
if ! grep -aqF 'streaming=1' "$STAGE/usr/bin/rauc" 2>/dev/null; then
  rauc_ok=0
  bad "/usr/bin/rauc was built WITHOUT streaming — every OTA silently reverts to a full-slot download"
fi
# 2. The NBD module must ship. rauc streams by creating an /dev/nbdN backed by an unprivileged
#    HTTP-Range helper; without the module `genl_ctrl_resolve(nl, "nbd")` fails and the install
#    dies. It is CONFIG_BLK_DEV_NBD=m from the arm64 defconfig with no ARCH_* gate, so today it
#    survives kernel/trim-platforms.config by accident rather than by decision -- and the open
#    "residual foreign-hardware drivers" item in TODO.md proposes exactly the kind of per-driver
#    negative pass that would take it out. No modprobe is needed at runtime (nbd.c declares
#    MODULE_ALIAS_GENL_FAMILY and genetlink request_module()s an unknown family by name), so the
#    only requirement is that the .ko is present.
if ! find "$STAGE/lib/modules" -name 'nbd.ko*' -print -quit 2>/dev/null | grep -q .; then
  rauc_ok=0
  bad "nbd.ko is not in the module tree — rauc cannot stream, so adaptive updates are dead"
fi
# The hook drives the boot state through steamos-bootconf (the bc() seam), and the backend tool
# does the same, so the cross-file consistency claim moved from "hook → bootctl" to "both files →
# bootconf's real subcommand set". bootconf is external — holo-bootconf ships as
# /usr/bin/steamos-bootconf — so a subcommand either file invokes that bootconf does not have fails
# at the LAST step of an install, and the card is left with a new root, refreshed stage 2 and a
# bootconf that never re-armed it: the worst shape available. Both files live in this tree, which
# is precisely why a rename in one is easy to miss in the other.
if [ "$rauc_ok" = 1 ] && [ -s "$STAGE/usr/bin/novadeck-bootctl" ]; then
  known="dump-config selected-image this-image list-images set-mode config create"
  for f in "$STAGE/usr/lib/rauc/post-install.sh" "$STAGE/usr/bin/novadeck-bootctl"; do
    [ -s "$f" ] || continue
    # Comment lines are stripped first: this file's prose names bootconf commands too. The
    # extraction catches both `bc <cmd>` and `bc --image <img> <cmd>` call shapes.
    while read -r sub; do
      [ -n "$sub" ] || continue
      case " $known " in
        *" $sub "*) ;;
        *)
          rauc_ok=0
          bad "$f calls steamos-bootconf '$sub', which bootconf does not have"
          ;;
      esac
    done < <(grep -vE '^[[:space:]]*#' "$f" \
               | grep -oE 'bc( +--image +[^ ]+)? +[a-z][a-z-]*' \
               | awk '{print $NF}' | sort -u)
  done
fi

# --- the OTA client SteamUI drives (Phase 3) -----------------------------------------------------
#
# What Steam actually executes is /usr/bin/steamos-polkit-helpers/steamos-update, which execs the
# client. Three things have to survive the copy into $STAGE, and each fails SILENTLY on a device
# with no serial console — the symptom is the update button in Settings doing nothing at all.
#
# THE SYMLINK IS THE ONE THAT NEEDS SAYING. fs-overlay/usr/bin/steamos-update -> novadeck-update is
# the FIRST symlink in usr/bin/, and `btrfs restore` drops symlinks unless it is given -S: a tree
# extracted for verification would show it simply absent, which reads as "we never shipped it"
# rather than "the extraction lost it". Assert it is still a symlink, not merely present, so a copy
# that dereferenced it (cp without -a, an rsync without -l) is caught here rather than by its
# absence somewhere downstream. See [[declared-invariants-need-assertions]].
for f in "$STAGE/usr/bin/novadeck-update" "$STAGE/usr/bin/steamos-polkit-helpers/steamos-update"; do
  if [ ! -s "$f" ]; then
    bad "${f#"$STAGE"} is missing — SteamUI's update button has nothing to call"
  elif [ ! -x "$f" ]; then
    # The exact failure that produced the OOBE black screen: present, correct, and not executable.
    bad "${f#"$STAGE"} is not executable — Steam runs it directly, so a lost mode bit is a dead button"
  fi
done
if [ ! -L "$STAGE/usr/bin/steamos-update" ]; then
  if [ -e "$STAGE/usr/bin/steamos-update" ]; then
    bad "/usr/bin/steamos-update is a regular file — it must stay a SYMLINK to novadeck-update (a dereferencing copy: cp without -a, rsync without -l)"
  else
    bad "/usr/bin/steamos-update is missing — the CLI entry point to the update client (btrfs restore drops symlinks without -S)"
  fi
fi

# Presence is not installability. Every check above passed on a tree whose system.conf rejected
# every bundle we can sign: the release cert's codeSigning EKU and RAUC's default smimesign
# verification purpose disagreed, and the first thing that would have noticed was `rauc install`
# on a device with no serial console. So sign a throwaway bundle and verify it THROUGH the tree's
# own system.conf. Run against $STAGE, not fs-overlay, for the reason in this file's header: what
# ships is the built tree, and a source file that is correct before the copy has been wrong after.
if [ "$rauc_ok" = 1 ] && [ -s "$STAGE/etc/rauc/system.conf" ]; then
  if ! signing_out="$("$(dirname "$0")/rauc/verify-signing.sh" "$STAGE/etc/rauc/system.conf" 2>&1)"; then
    rauc_ok=0
    bad "the shipped system.conf cannot verify a bundle signed the way ci/gen-signing-ca.sh signs one"
    printf '%s\n' "$signing_out" | sed 's/^/      /' >&2
  fi
fi
if [ "$rauc_ok" = 1 ]; then
  echo "    ok  rauc + keyring + system.conf + /usr/lib/novadeck/boot stage-1/2 mirror + /boot kernel + executable hook"
  echo "    ok  a codeSigning-EKU bundle verifies through the shipped system.conf; an unrelated CA does not"
fi

# ------------------------------------------------------------------------------------------
# 8. The system UID/GID allocation matches the pin.
#
# /usr/lib/sysusers.d/01-novadeck-enforce-ids.conf declares an id for every name in the range
# systemd-sysusers would otherwise allocate. Whether it WORKED is not visible in the declaration:
# it only takes effect if it reached the target root before the transaction whose hook allocates,
# and it wins only because `01-` sorts first. Both are properties of images/customize-base.sh, one
# file away from this one, and the failure is silent — sysusers allocates by counting down from 999,
# so a pin that never applied still yields a plausible-looking passwd.
#
# What it costs to miss: the ids are recorded in the inodes of /home and of each slot's /var, and
# fs-overlay/usr/lib/rauc/post-install.sh copies /var wholesale across an update. So a build whose
# allocation silently moved ships an update that reassigns ownership of persisted state — noticed
# on a device, after the fact, as a service that cannot read its own state directory.
#
# Read from the STAGE, not from fs-overlay, for this file's usual reason: what ships is the built
# tree, and the pin is only load-bearing if it is IN it. An absent pin is a failure, not a skip.
# ------------------------------------------------------------------------------------------
echo "  8. system UID/GID allocation"
IDPIN="$STAGE/usr/lib/sysusers.d/01-novadeck-enforce-ids.conf"
PASSWD="$STAGE/etc/passwd"
GROUP="$STAGE/etc/group"

ids_ok=1
if [ ! -s "$IDPIN" ]; then
  ids_ok=0
  bad "/usr/lib/sysusers.d/01-novadeck-enforce-ids.conf is missing — nothing pins the system id range, so every id in it is a function of the package set"
elif [ ! -s "$PASSWD" ] || [ ! -s "$GROUP" ]; then
  ids_ok=0
  bad "/etc/passwd or /etc/group is missing or empty — the tree has no id allocation to check"
else
  ids_checked=0
  # Fields: <type> <name> <id> ... — only `u` and `g` lines carry an id we pin. A `-` id would mean
  # "allocate", which is the thing this file exists to prevent, so it is a failure and not a skip.
  while read -r kind name id _rest; do
    case "$kind" in u|g) ;; *) continue ;; esac
    [ -n "${id:-}" ] || continue
    if [ "$id" = "-" ]; then
      ids_ok=0
      bad "the id pin leaves '$name' unpinned ($kind line with '-') — that name is back to being allocated by package order"
      continue
    fi
    # Which files must agree: a `g` line fixes only the group, a `u` line fixes the user AND the
    # like-named group, because sysusers creates both at the same id.
    case "$kind" in
      g) files="group" ;;
      u) files="passwd group" ;;
    esac
    for which in $files; do
      case "$which" in passwd) file="$PASSWD" ;; group) file="$GROUP" ;; esac
      # Look the NAME up, not the id. A name sitting at the wrong id is exactly the failure being
      # hunted, and searching by id would simply not find it.
      got="$(awk -F: -v n="$name" '$1 == n { print $3; exit }' "$file")"
      if [ -z "$got" ]; then
        ids_ok=0
        bad "'$name' is pinned to $id but is absent from /etc/$which — the pin names something this tree does not create"
      elif [ "$got" != "$id" ]; then
        ids_ok=0
        bad "'$name' is $got in /etc/$which but the pin says $id — the pin did not apply (it must reach the target root BEFORE the pacman transaction; see images/customize-base.sh)"
      fi
    done
    ids_checked=$((ids_checked + 1))
  done < <(grep -vE '^[[:space:]]*(#|$)' "$IDPIN")

  if [ "$ids_checked" = 0 ]; then
    ids_ok=0
    bad "the id pin declares no u/g entries — it is a comment, not a pin"
  elif [ "$ids_ok" = 1 ]; then
    echo "    ok  $ids_checked pinned system ids match /etc/passwd + /etc/group"
  fi
fi

# ------------------------------------------------------------------------------------------
# 9. Size delta (report only).
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
