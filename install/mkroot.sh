#!/usr/bin/env bash
# novadeck INSTALLER root bootstrap — lay the installer/recovery root down from packages, into an
# empty tree. Phase 6 of .claude/plans/internal-install.plan.md.
#
#   install/mkroot.sh                    # locked: install/manifest.lock, sha256-verified
#   NOVADECK_RESOLVE=1 install/mkroot.sh # re-resolve from install/pkgs.list (this is how the lock
#                                        # is REGENERATED -- `make relock-installer`). Never ships.
#
# Prints the bootstrapped rootfs path on stdout. FORCE=1 re-runs.
#
# WHAT THIS IS. The installer image is a standalone medium that boots on the handheld, draws a
# consent screen on the panel, and writes NovaDeck to the device's internal UFS. It is not the
# shipped image and must never drift towards it: no Steam, no `deck` user, no SDDM, no Bluetooth,
# no audio, no FEX. See install/pkgs.list, which is the declaration this reads.
#
# PEER OF images/customize-base.sh, and deliberately a separate script rather than a mode of it.
# The shipped bootstrap carries five things this one has no analogue for -- the UID/GID pin (there
# is no persistent /home here to keep uids stable for), the `deck` and `sddm` accounts, auto-
# discovery of every packages/*/prebuilt.pin, the dev-tooling branch, and a seal that strips pacman
# back out. Folding an installer mode into it would have made each of those a conditional in the
# one file whose value is that a reviewer can read it top to bottom and know what is on a device.
# What the two genuinely share -- materializing a lock -- IS shared: images/fetchlock.sh takes the
# lock as an argument and neither knows which image it is serving.
#
# IT PRODUCES A TREE, NOT A SQUASHFS. The plan sketched mksquashfs at the end of this script;
# install/mkimage.sh does it instead, for the same reason images/assemble-rootfs.sh rather than
# images/customize-base.sh builds the shipped image: the tree is root-owned, so compressing it
# while preserving ownership needs the build container, and this script is host-side by design
# (its only container is the emulated pacman). One stage per artifact, same as the main pipeline.
#
# NO SEAL, NO GUARD. The release image is sealed (images/seal-rootfs.sh removes pacman) and then
# asserted against images/manifest.lock, because it is the thing a user lives on for years. The
# installer runs once, from removable media, as root, and is thrown away. A package manager on it
# is a diagnosable installer, and there is no measurement after the fact for a seal to protect.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# The EXECUTION environment, not the content source. The SAME pinned arm64 builder
# images/customize-base.sh and packages/build-overlay.sh use -- one builder for the whole tree, so
# a bump cannot leave the two images laid down by different pacmans.
PINFILE="$ROOT/base-devel.digest"
SNAPFILE="$ROOT/snapshot.pin"
LOCKFILE="$ROOT/install/manifest.lock"
PACMANCONF="$ROOT/images/pacman.conf"
OSRELEASE="$ROOT/install/os-release"
PKGSLIST="$ROOT/install/pkgs.list"
DEST="$ROOT/work/installer-base"
STAGE="$ROOT/work/installer-stage"
PACMAN_CACHE="$ROOT/work/pacman-cache"
OVERLAY_REPO="$ROOT/work/repo/aarch64"
OVERLAY_DB="$OVERLAY_REPO/novadeck.db.tar.zst"
RESOLVE="${NOVADECK_RESOLVE:-}"

# The FAT label install/mkimage.sh gives the medium's own ESP, and the /etc/fstab entry below finds
# it by. It is deliberately NOT one of the `novadeck-*` labels an INSTALL carries: a dev card and an
# install already share those, which is the whole reason REPLACES_OURS=1 cannot be judged from a dev
# card ([[internal-install-phase6-plan]]), and an installer that mounted the target's ESP at its own
# /esp would write its failure log onto the disk it just failed to install. 11 characters exactly,
# which is all a FAT label has room for.
ESP_LABEL="NDINSTALLER"

log() { echo "[novadeck] $*" >&2; }
die() { echo "$*" >&2; exit 1; }

# ---- the declaration ---------------------------------------------------------------------------
# install/pkgs.list is the human-editable intent; the lock is the resolved closure. Comments and
# blank lines out, inline trailing comments out (the list is heavily annotated), names in order.
[ -f "$PKGSLIST" ] || die "no package declaration: $PKGSLIST"
mapfile -t PKGS < <(sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$PKGSLIST" | grep -v '^$')
[ "${#PKGS[@]}" -gt 0 ] || die "${PKGSLIST#"$ROOT"/} declares no packages"

# ---- the two prebuilt pins, named rather than discovered -----------------------------------------
# images/customize-base.sh globs packages/*/prebuilt.pin, which is exactly the behaviour
# install/pygame-ce.pin exists OUTSIDE packages/ to stay clear of -- 39 MB of Python SDL bindings
# that only install/ui uses would otherwise be pure weight on every shipped device. So this image
# names its two, and the list is short enough to read:
#
#   inputplumber  the handheld input daemon. It ships here NOT for size but so the installer's input
#                 path is IDENTICAL to the HW-validated main-image one, rather than a second raw-
#                 evdev stack inside the tool that has to work when the device is already broken.
#   pygame-ce     the SDL binding install/ui draws with. There is no python-pygame and no PySDL2 in
#                 the holo repos (measured); the wheel vendors its own libSDL2 with the wayland
#                 driver compiled in. See the pin for why a vendored wheel was acceptable.
PINS=("$ROOT/packages/inputplumber/prebuilt.pin" "$ROOT/install/pygame-ce.pin")
pin_field() { sed -n "s/^$2:[[:space:]]*//p" "$1" | head -1; }

# `deps:` in a pin names holo-repo packages the prebuilt links against. The shipped bootstrap
# aggregates them into its install list automatically; here they are LEAVES of install/pkgs.list,
# declared by hand next to a comment saying which pin they belong to. That is only safe if a pin
# that GAINS a dependency cannot go unnoticed, so assert it -- a build-time check, in the one place
# that can see both sides, rather than a runtime guard on the device.
for pin in "${PINS[@]}"; do
  [ -f "$pin" ] || die "no prebuilt pin: ${pin#"$ROOT"/}"
  for dep in $(pin_field "$pin" deps); do   # word-split: deps is space-separated
    printf '%s\n' "${PKGS[@]}" | grep -qx "$dep" \
      || die "${pin#"$ROOT"/} declares dep '$dep', which ${PKGSLIST#"$ROOT"/} does not carry"
  done
done

# ---- the pins that decide WHAT is laid down -------------------------------------------------------
[ -f "$PINFILE" ] || die "no builder pin: $PINFILE"
REF="$(grep -vE '^[[:space:]]*(#|$)' "$PINFILE" | tail -1)"
case "$REF" in
  *@sha256:*) ;;
  *) die "refusing unpinned builder ref (need ...@sha256:<digest>): '$REF'" ;;
esac
[ -f "$SNAPFILE" ] || die "no snapshot pin: $SNAPFILE"
SNAPSHOT="$(grep -vE '^[[:space:]]*(#|$)' "$SNAPFILE" | tail -1)"
case "$SNAPSHOT" in
  *mash-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9].[0-9]*) ;;
  *) die "refusing unpinned snapshot (need an explicit .N revision, not the alias): '$SNAPSHOT'" ;;
esac
[ -f "$PACMANCONF" ] || die "no bootstrap pacman config: $PACMANCONF"
[ -f "$OSRELEASE" ]  || die "no os-release declaration: $OSRELEASE"
command -v docker >/dev/null 2>&1 || die "docker required for the root bootstrap"

# The from-source overlay repo is REQUIRED, not optional: install/pkgs.list names gamescope, which
# exists in no holo repo at all. Refuse here, on the host, rather than 20 emulated minutes in.
if [ ! -f "$OVERLAY_DB" ] || ! ls "$OVERLAY_REPO"/*.pkg.tar.zst >/dev/null 2>&1; then
  echo "no usable overlay repo at ${OVERLAY_REPO#"$ROOT"/} — the root cannot be laid down without it" >&2
  die "  build it first: make overlay"
fi

# ---- the files that travel with the tree ----------------------------------------------------------
# The §5 set is FOUR model/view files plus the spine and its helpers, and they find each other by
# dirname(__file__) and by $SELFDIR -- so ONE FLAT DIRECTORY is the entire layout requirement. Named
# explicitly rather than globbed: install/ also holds the hw-* stagers (build-host only), the test
# suites, this script, and a __pycache__ that a glob would happily ship.
INSTALL_FILES=(
  carve.sh select-target.sh novadeck-install rauc-session.sh post-install-fresh.sh
  verify-install.sh netcfg confirm-tty confirm-ui
  ui uipad.py uiflow.py uiview.py installer-session save-log.sh
)
# ...and three the spine resolves by SEARCH, which live outside install/ because the shipped image
# needs them too. novadeck-install tries $SELFDIR first, so landing them in the same flat directory
# is what makes the installer image the case where the search succeeds on its first candidate.
#   <source>:<name in the flat directory>
FOREIGN_FILES=(
  "fs-overlay/usr/lib/novadeck/install/lib-slotwrite.sh:lib-slotwrite.sh"
  "images/genpart.sh:genpart.sh"
  "images/partition-table.txt:partition-table.txt"
  "images/lib-homestage.sh:lib-homestage.sh"
)
for f in "${INSTALL_FILES[@]}"; do
  [ -f "$ROOT/install/$f" ] || die "install/$f is missing — the installer cannot ship without it"
done
for spec in "${FOREIGN_FILES[@]}"; do
  [ -f "$ROOT/${spec%%:*}" ] || die "${spec%%:*} is missing — the spine resolves it by search and would die"
done
# The device registry: the pre-flight screen names the board with it and installer-session derives
# the panel's logical output from it. Both fall back if it is absent, but every board would then
# draw a generic 1920x1080 and call itself "this device" -- the kind of degradation nobody notices
# until a user reports it.
DEVICE_ENV="$ROOT/fs-overlay/usr/lib/novadeck/device-env"
DEVICES_DIR="$ROOT/fs-overlay/usr/lib/novadeck/devices"
[ -x "$DEVICE_ENV" ] || die "no ${DEVICE_ENV#"$ROOT"/} — every board would draw a generic output"
[ -d "$DEVICES_DIR" ] || die "no ${DEVICES_DIR#"$ROOT"/} — device-env would resolve no board"
# The RAUC keyring. The spine refuses outright without a readable one, and correctly: an installer
# that could not verify a bundle would write unverified bytes to a stranger's internal disk. Same
# CA the shipped image gets from images/assemble-rootfs.sh, so one bundle verifies against both.
KEYRING_SRC="$ROOT/images/rauc/novadeck-ca.pem"
[ -f "$KEYRING_SRC" ] || die "no RAUC CA at ${KEYRING_SRC#"$ROOT"/}"

# The baked steam-seed pin. The spine checks the published seed against THIS file and refuses if it
# is absent, because "we could not check" and "it checked out" must not have the same effect. The
# publisher that emits it is the other half of Phase 6 and does not exist yet, so accept it as an
# input and say plainly what an image without one can and cannot do -- the refusal already lives in
# the spine, and duplicating it here would just mean two places to fix when the publisher lands.
SEED_SHA="${NOVADECK_SEED_SHA256:-}"
if [ -z "$SEED_SHA" ] && [ -f "$ROOT/install/steam-seed.sha256" ]; then
  SEED_SHA="$(tr -d '[:space:]' <"$ROOT/install/steam-seed.sha256")"
fi

# ---- the reuse-cache key -------------------------------------------------------------------------
# The bootstrap is a slow emulated install, so it is reused unless an INPUT moved. Every input that
# can change the tree without changing the package names has to be in this key; the shipped
# bootstrap learned that the hard way (twice, on the same day) by leaving its own script out of it.
# One row per pin, sorted: `name version sha256 kind dest strip`. install/genlock.sh reads the
# copy of this that lands in the tree, so it is the image's own record of what was placed rather
# than a re-walk of the pins. Every optional field carries a DEFAULT here — inputplumber's pin
# declares neither `kind` nor `dest`, and an empty field would shift every column after it, which
# the reader would see as a tar extracting to a path named after a checksum.
prebuilt_manifest() {
  local pin kind dest strip
  for pin in "${PINS[@]}"; do
    kind="$(pin_field "$pin" kind)";   kind="${kind:-tar}"
    dest="$(pin_field "$pin" dest)";   dest="${dest:--}"
    strip="$(pin_field "$pin" strip)"; strip="${strip:-0}"
    printf '%s %s %s %s %s %s\n' \
      "$(pin_field "$pin" name)" "$(pin_field "$pin" version)" "$(pin_field "$pin" sha256)" \
      "$kind" "$dest" "$strip"
  done | sort
}
EXPECTED_MANIFEST="$(prebuilt_manifest)"
EXPECTED_PKGS="$(printf '%s\n' "${PKGS[@]}" | sort -u)
env:$REF
snapshot:$SNAPSHOT
overlay:$(sha256sum "$OVERLAY_DB" | cut -d' ' -f1)
script:$(sha256sum "$0" | cut -d' ' -f1)
osrelease:$(sha256sum "$OSRELEASE" | cut -d' ' -f1)
seed:${SEED_SHA:-none}
esplabel:$ESP_LABEL"
# Every file that lands in the tree, hashed. These are the installer -- an edit to install/ui or to
# a unit changes the image completely while leaving the package set untouched, so without this the
# next build would happily reuse a tree carrying the previous code.
payload=""
for f in "${INSTALL_FILES[@]}"; do payload+="$(sha256sum "$ROOT/install/$f")"$'\n'; done
for spec in "${FOREIGN_FILES[@]}"; do payload+="$(sha256sum "$ROOT/${spec%%:*}")"$'\n'; done
# `[ -e ] && …` would be the last command of the loop body, so a single absent file makes the
# whole loop exit non-zero and `set -e` kills the script here rather than at the missing file.
for f in "$ROOT"/install/units/*.service "$DEVICE_ENV" "$DEVICES_DIR"/*.conf "$KEYRING_SRC"; do
  if [ -e "$f" ]; then payload+="$(sha256sum "$f")"$'\n'; fi
done
EXPECTED_PKGS="$EXPECTED_PKGS
payload:$(printf '%s' "$payload" | sha256sum | cut -d' ' -f1)"
if [ -n "$RESOLVE" ]; then
  EXPECTED_PKGS="$EXPECTED_PKGS
mode:resolve"
else
  [ -f "$LOCKFILE" ] || die "no manifest: ${LOCKFILE#"$ROOT"/} (run \`make relock-installer\`)"
  EXPECTED_PKGS="$EXPECTED_PKGS
mode:locked
lock:$(sha256sum "$LOCKFILE" | cut -d' ' -f1)"
fi

if [ -z "${FORCE:-}" ] \
   && [ "$(cat "$DEST/usr/lib/novadeck/pkgs" 2>/dev/null)" = "$EXPECTED_PKGS" ] \
   && [ "$(cat "$DEST/usr/lib/novadeck/prebuilt.manifest" 2>/dev/null)" = "$EXPECTED_MANIFEST" ]; then
  log "installer root present: ${DEST#"$ROOT"/} (FORCE=1 to rebuild)"
  echo "$DEST"; exit 0
fi

# ---- stage everything the container needs ---------------------------------------------------------
# One read-only staging directory. It MUST be mounted at /prebuilt and the name is not ours to
# pick: images/pacman.conf is a shared committed declaration carrying `Include =
# /prebuilt/mirrorlist`, so a staging dir mounted anywhere else makes pacman fail with "config file
# /prebuilt/mirrorlist could not be read" — after the builder pull and the root wipe, far from the
# cause. (Measured 2026-08-24, on the first real run.) The repo itself is NOT mounted: the container
# runs as root, and a writable repo mount is how a build starts editing the tree it was built from.
rm -rf "$STAGE"
mkdir -p "$STAGE/flat" "$STAGE/units" "$STAGE/devices" "$STAGE/prebuilt" "$PACMAN_CACHE"
for f in "${INSTALL_FILES[@]}"; do cp -p "$ROOT/install/$f" "$STAGE/flat/$f"; done
for spec in "${FOREIGN_FILES[@]}"; do cp -p "$ROOT/${spec%%:*}" "$STAGE/flat/${spec##*:}"; done
cp -p "$ROOT"/install/units/*.service "$STAGE/units/"
cp -p "$DEVICE_ENV" "$STAGE/device-env"
cp -p "$DEVICES_DIR"/*.conf "$STAGE/devices/"
cp    "$KEYRING_SRC" "$STAGE/keyring.pem"
cp    "$PACMANCONF"  "$STAGE/pacman.conf"
cp    "$OSRELEASE"   "$STAGE/os-release"
if [ -n "$SEED_SHA" ]; then printf '%s\n' "$SEED_SHA" >"$STAGE/steam-seed.sha256"; fi
printf '%s\n' "$ESP_LABEL" >"$STAGE/esp-label"
# The package names alone, as their own file. The reuse-cache marker below is a superset (it also
# carries the pins, the mode and the payload hash) and filtering the names back out of it in the
# container would be a guess about which lines are names.
printf '%s\n' "${PKGS[@]}" >"$STAGE/declared.pkgs"
# The mirrorlist crosses as a FILE rather than being interpolated into the container script: the URL
# carries a literal $repo/$arch that pacman expands and neither shell must.
printf 'Server = %s/$repo/os/$arch\n' "$SNAPSHOT" >"$STAGE/mirrorlist"
printf '%s\n' "$EXPECTED_MANIFEST" >"$STAGE/prebuilt.manifest"
printf '%s\n' "$EXPECTED_PKGS"     >"$STAGE/pkgs"

# Fetch + verify each prebuilt on the host (network here). The staged blobs live under work/ and are
# reused across runs when their sha still matches the pin, so a re-bootstrap does not re-download.
PREBUILT_CACHE="$ROOT/work/installer-prebuilt"
mkdir -p "$PREBUILT_CACHE"
for pin in "${PINS[@]}"; do
  p_name="$(pin_field "$pin" name)"; p_ver="$(pin_field "$pin" version)"
  p_url="$(pin_field "$pin" url)";   p_sha="$(pin_field "$pin" sha256)"
  p_kind="$(pin_field "$pin" kind)"; p_kind="${p_kind:-tar}"
  : "${p_name:?${pin}: missing name}"; : "${p_url:?${pin}: missing url}"; : "${p_sha:?${pin}: missing sha256}"
  staged="$PREBUILT_CACHE/$p_name.$p_kind"
  if [ -f "$staged" ] && echo "$p_sha  $staged" | sha256sum -c --status -; then
    log "prebuilt $p_name $p_ver ($p_kind): cached"
  else
    log "fetching prebuilt $p_name $p_ver ($p_kind): $p_url"
    curl -fsSL "$p_url" -o "$staged.part"
    echo "$p_sha  $staged.part" | sha256sum -c - \
      || { rm -f "$staged.part"; die "$p_name sha256 mismatch — refusing"; }
    mv -f "$staged.part" "$staged"
  fi
  cp "$staged" "$STAGE/prebuilt/$p_name.$p_kind"
done

# LOCKED mode: materialize + sha256-verify the lock's package files on the host and hand the
# container an explicit install list. Done HERE, before the container starts, so a republished
# package fails the build with a hash mismatch instead of after 20 minutes of emulated install.
# Resolve mode writes no list, which is how the container tells the modes apart.
if [ -z "$RESOLVE" ]; then
  "$ROOT/images/fetchlock.sh" "$STAGE/install.list" "$LOCKFILE"
else
  log "NOVADECK_RESOLVE=1 — re-resolving from ${PKGSLIST#"$ROOT"/}, this tree is for relock only"
fi

log "pulling pinned builder: $REF"
docker pull "$REF" >&2
if ! docker run --rm --platform linux/arm64 "$REF" /usr/bin/true >/dev/null 2>&1; then
  log "registering arm64 binfmt (qemu) via tonistiigi/binfmt"
  docker run --privileged --rm tonistiigi/binfmt --install arm64 >&2
fi

# The target root must start EMPTY: this is a bootstrap, and reusing a partially populated tree
# reintroduces exactly the "content of unknown origin" the from-packages model removes. Both the
# wipe and the re-create run IN A CONTAINER so the directory is root-owned like everything pacman
# writes into it -- created host-side it is owned by the build user, and systemd-tmpfiles then
# refuses to descend into it ("unsafe path transition"), silently producing a tree with none of the
# tmpfiles directories in it.
log "clearing the target root -> ${DEST#"$ROOT"/}"
mkdir -p "$ROOT/work"
docker run --rm -v "$ROOT/work":/wb "$REF" sh -c 'rm -rf /wb/installer-base && mkdir -m0755 /wb/installer-base'

if [ -n "$RESOLVE" ]; then
  log "resolving the installer root under arm64: ${PKGS[*]}"
else
  log "laying down $(wc -l <"$STAGE/install.list") locked packages under arm64"
fi

docker run --rm --platform linux/arm64 \
  -v "$STAGE":/prebuilt:ro \
  -v "$PACMAN_CACHE":/var/cache/pacman/pkg \
  -v "$OVERLAY_REPO":/novarepo:ro \
  -v "$DEST":/target \
  "$REF" \
  bash -euo pipefail -c '
  # Same three flags the shipped bootstrap uses, and for the same reasons: -r installs into the
  # bind-mounted empty tree rather than into this container; --config is the committed pacman.conf
  # (which Includes the mirrorlist the host wrote from snapshot.pin), so the vendor /etc/pacman.conf
  # in this image is never read; --cachedir is the persistent host cache, since a root-relative one
  # would put the cache INSIDE the image being built. dbpath defaults to /target/var/lib/pacman,
  # which is where it belongs -- install/genlock.sh reads that database to write the lock.
  PA=(pacman -r /target --config /prebuilt/pacman.conf --cachedir /var/cache/pacman/pkg)
  mkdir -p /target/var/lib/pacman

  # A minimal /dev, because pacman runs install scriptlets CHROOTED into the target and the target
  # has no API filesystems. Without /dev/null a scriptlet that redirects dies, and pacman reports a
  # failed hook as a WARNING -- so the build stays green with the scriptlet half-run.
  mkdir -p /target/dev
  mknod -m 0666 /target/dev/null    c 1 3 2>/dev/null || true
  mknod -m 0666 /target/dev/zero    c 1 5 2>/dev/null || true
  mknod -m 0666 /target/dev/random  c 1 8 2>/dev/null || true
  mknod -m 0666 /target/dev/urandom c 1 9 2>/dev/null || true
  mknod -m 0600 /target/dev/console c 5 1 2>/dev/null || true

  if [ -s /prebuilt/install.list ]; then
    # No -Sy anywhere on this path: nothing syncs a repo database, so pacman CANNOT resolve
    # anything of its own accord -- it installs exactly these host-verified files, and its
    # dependency check over the batch is then a free proof that the lock is a closed set.
    mapfile -t lockpkgs < /prebuilt/install.list
    echo "laying down ${#lockpkgs[@]} locked packages into an empty root"
    "${PA[@]}" -U --noconfirm "${lockpkgs[@]}"
  else
    mapfile -t want < /prebuilt/declared.pkgs
    "${PA[@]}" -Sy --noconfirm --disable-download-timeout "${want[@]}"
  fi

  # Assert the tree against the DECLARATION, not only against the lock. A lock is a resolved
  # closure, so a leaf that dropped OUT of it leaves no unsatisfied dependency behind: pacman -U
  # succeeds and the package is simply absent on the medium. -T reports unsatisfied names and
  # honours provides (unlike -Q), which catches exactly that. For this image the stakes are
  # concrete -- a missing mtools is a rule 3b that fails on a stranger foreign ESP.
  mapfile -t declared < /prebuilt/declared.pkgs
  unmet="$("${PA[@]}" -T "${declared[@]}" || true)"
  if [ -n "$unmet" ]; then
    echo "the bootstrap did not satisfy the declared package set; unsatisfied:" >&2
    printf "  %s\n" $unmet >&2
    echo "the lock is stale for this declaration -- run: make relock-installer" >&2
    exit 1
  fi

  # ---- identity ---------------------------------------------------------------------------------
  # Three files no package owns. Without them the tree falls back to the vendor
  # /usr/lib/os-release, an unset LANG and a compiled-in hostname -- i.e. an installer that
  # announces itself as someone else`s distro on the one console a person reads when it has failed.
  rm -f /target/etc/os-release
  install -Dm0644 /prebuilt/os-release /target/etc/os-release
  printf "LANG=en_US.UTF-8\n" >/target/etc/locale.conf
  printf "novadeck-installer\n" >/target/etc/hostname
  grep -q "^en_US.UTF-8 UTF-8" /target/etc/locale.gen || echo "en_US.UTF-8 UTF-8" >>/target/etc/locale.gen
  chroot /target locale-gen

  # ---- the prebuilts ----------------------------------------------------------------------------
  # kind=tar -> extract with the pin`s strip-components into dest (default /).
  # kind=zip -> the pygame-ce wheel: a ZIP whose members are already rooted at the package
  #             directory, unpacked into site-packages. `dest` is a path in the TARGET root.
  # --no-same-owner on the tar is LOAD-BEARING, not hygiene: these archives carry their own CI
  # builder`s numeric uid (InputPlumber is 1001/1001 throughout) and it unpacks at / with strip 1,
  # so a root tar -x would chown the TARGET`s /usr, /usr/bin and /usr/lib to a uid that does not
  # exist on the image.
  while read -r p_name p_ver p_sha p_kind p_dest p_strip; do
    [ -n "$p_name" ] || continue
    : "${p_ver:-}" "${p_sha:-}"
    if [ "$p_dest" = "-" ] || [ -z "$p_dest" ]; then p_dest=/; fi
    mkdir -p "/target$p_dest"
    case "${p_kind:-tar}" in
      tar) tar -C "/target$p_dest" --no-same-owner --strip-components="${p_strip:-0}" \
               -xf "/prebuilt/prebuilt/$p_name.tar" ;;
      zip) bsdtar -C "/target$p_dest" --no-same-owner -xf "/prebuilt/prebuilt/$p_name.zip" ;;
      *)   echo "prebuilt $p_name: unknown kind ${p_kind}" >&2; exit 1 ;;
    esac
  done < /prebuilt/prebuilt.manifest
  install -Dm0644 /prebuilt/prebuilt.manifest /target/usr/lib/novadeck/prebuilt.manifest

  # ---- the installer itself -----------------------------------------------------------------------
  # ONE FLAT DIRECTORY. Every component resolves $SELFDIR / dirname(__file__) first, so this is the
  # whole layout requirement -- and it is what makes the spine`s search succeed on its first
  # candidate here rather than falling through to a path that happens to exist.
  install -d -m0755 /target/usr/lib/novadeck/install
  for f in /prebuilt/flat/*; do
    case "$(basename "$f")" in
      *.txt|*.py) install -m0644 "$f" /target/usr/lib/novadeck/install/ ;;
      lib-*.sh)   install -m0644 "$f" /target/usr/lib/novadeck/install/ ;;
      *)          install -m0755 "$f" /target/usr/lib/novadeck/install/ ;;
    esac
  done
  # uipad/uiflow/uiview are imported, never executed -- 0644 above. `ui` IS executed and is not a
  # .py, which is why the extension decides the mode rather than a name list that would drift.

  # $CONFIRM is a FIXED PATH the spine reads (NOVADECK_CONFIRM defaults to it), and it points at
  # confirm-ui rather than confirm-tty: on this image the UI is already running and owns both the
  # panel and the pad, so a second SDL client would contend with it for gamescope focus -- the
  # failure mode being a consent screen that never appears. confirm-tty stays on the image for a
  # novadeck.install.debug boot, where there is no UI to shim to.
  ln -sf confirm-ui /target/usr/lib/novadeck/install/confirm

  # The device registry. Both consumers fall back without it, to a generic 1920x1080 output and a
  # board that calls itself "this device".
  install -Dm0755 /prebuilt/device-env /target/usr/lib/novadeck/device-env
  install -d -m0755 /target/usr/lib/novadeck/devices
  install -m0644 /prebuilt/devices/*.conf /target/usr/lib/novadeck/devices/

  # The RAUC keyring, at the path the spine and /etc/rauc/system.conf both name. 0444: it is a
  # public certificate and nothing on this image should ever rewrite it.
  install -Dm0444 /prebuilt/keyring.pem /target/etc/rauc/keyring.pem

  # The baked seed pin, when the build was given one. Absent, the spine refuses at the seed step --
  # which is the correct behaviour and is checked THERE, not duplicated here.
  if [ -f /prebuilt/steam-seed.sha256 ]; then
    install -Dm0644 /prebuilt/steam-seed.sha256 /target/usr/lib/novadeck/install/steam-seed.sha256
  fi

  # ---- units --------------------------------------------------------------------------------------
  install -m0644 /prebuilt/units/*.service /target/usr/lib/systemd/system/
  mkdir -p /target/etc/systemd/system/multi-user.target.wants
  # ONLY the session unit is enabled. The console unit is started by OnFailure= and enabling it
  # would run the fallback on every boot, including the ones that worked.
  ln -sf /usr/lib/systemd/system/novadeck-installer.service \
         /target/etc/systemd/system/multi-user.target.wants/novadeck-installer.service

  # ---- a READ-ONLY /etc, and the three things that would write to it ------------------------------
  # The root is squashfs, so /etc cannot be written at runtime and there is NO overlay: the shipped
  # image gets one, but that overlay is what forces an initramfs, and it exists so a user can
  # persist config across updates -- neither of which an installer that runs once from removable
  # media needs. The writers are few and enumerable, so each is pointed at /run instead. A writer
  # nobody enumerated is the risk this trades for; install/test-mkroot.sh greps the shipped payload
  # for new ones, and /var is a tmpfs at runtime via systemd.volatile=state on the cmdline.
  #
  # 1. machine-id. The file must EXIST for systemd to bind-mount a transient one over it from tmpfs
  #    on a read-only root; absent entirely, PID1 fails early instead. Empty means "not yet set",
  #    which is exactly the state we want on every boot of a tool that is not a persistent system.
  : >/target/etc/machine-id
  chmod 0444 /target/etc/machine-id

  # 2. NetworkManager profiles. install/netcfg creates a connection with nmcli, and the keyfile
  #    plugin writes it to /etc/NetworkManager/system-connections by default. Point it at tmpfs --
  #    a Wi-Fi profile on an installer is per-run state, not configuration, and the PSK is better
  #    off never touching the medium anyway.
  install -d -m0755 /target/etc/NetworkManager/conf.d
  printf "%s\n" \
    "# novadeck installer: the root is read-only squashfs (install/mkroot.sh)." \
    "[keyfile]" \
    "path=/run/NetworkManager/system-connections" \
    "" \
    "[main]" \
    "# Do not try to rewrite /etc/resolv.conf; it is a symlink into /run (below)." \
    "rc-manager=unmanaged" \
    >/target/etc/NetworkManager/conf.d/00-novadeck-installer.conf

  # 3. resolv.conf. NM maintains /run/NetworkManager/resolv.conf whatever rc-manager says, so the
  #    symlink is what makes name resolution work; rc-manager=unmanaged above is what stops NM
  #    trying to replace the symlink with a regular file and logging a failure every connect.
  ln -sf /run/NetworkManager/resolv.conf /target/etc/resolv.conf

  # systemd-firstboot would block sysinit forever. The machine-id written above is EMPTY, which is
  # still ConditionFirstBoot=yes, so the unit runs and prompts for locale and a root password on a
  # console with no usable input. systemd.firstboot=off on the cmdline disables PID1`s builtin
  # query, NOT this unit -- mask it. A transient machine-id is still established at boot.
  mkdir -p /target/etc/systemd/system
  ln -sf /dev/null /target/etc/systemd/system/systemd-firstboot.service

  # Network: NetworkManager owns the links (install/netcfg drives nmcli), so mask networkd. Both
  # running is what pins network-online.target until networkd`s wait-online times out EVERY boot,
  # stalling anything ordered after it -- HW-confirmed on the main image, and this image orders a
  # bundle download behind it. Masking is preset-proof; nothing can socket-activate them back.
  ln -sf /dev/null /target/etc/systemd/system/systemd-networkd.service
  ln -sf /dev/null /target/etc/systemd/system/systemd-networkd.socket
  ln -sf /dev/null /target/etc/systemd/system/systemd-networkd-wait-online.service
  mkdir -p /target/etc/systemd/system-preset
  echo "enable NetworkManager.service" >/target/etc/systemd/system-preset/60-novadeck-network.preset
  ln -sf /usr/lib/systemd/system/NetworkManager.service \
         /target/etc/systemd/system/multi-user.target.wants/NetworkManager.service
  ln -sf /usr/lib/systemd/system/NetworkManager.service \
         /target/etc/systemd/system/dbus-org.freedesktop.NetworkManager.service

  # seatd.service IS enabled, and that is a Phase 6 choice installer-session explicitly left open.
  # It takes either branch -- use a seatd that is already listening, or launch one via seatd-launch
  # -- and the branch with an END-TO-END hardware result behind it is the first: the 2026-08-22
  # Pocket S2 run drew the consent screen through a seatd that systemd had already started. The
  # seatd-launch branch is validated only as bare gamescope (bringup-phase2 gate 1b), and it also
  # leaks /run/seatd.sock on an unclean exit, which is the worse property in a tool people re-run
  # after a crash. Reversible in this one line if that ever inverts.
  echo "enable seatd.service" >>/target/etc/systemd/system-preset/60-novadeck-network.preset
  ln -sf /usr/lib/systemd/system/seatd.service \
         /target/etc/systemd/system/multi-user.target.wants/seatd.service
  # InputPlumber: the unit ships inside the prebuilt tarball, and novadeck-installer.service Wants=
  # it. Enable it the same preset-proof way.
  if [ -f /target/usr/lib/systemd/system/inputplumber.service ]; then
    ln -sf /usr/lib/systemd/system/inputplumber.service \
           /target/etc/systemd/system/multi-user.target.wants/inputplumber.service
  else
    echo "inputplumber.service is not in the tree — the prebuilt layout moved" >&2
    exit 1
  fi

  # ---- /esp, a REAL mount point -------------------------------------------------------------------
  # save-log.sh checks that /esp is a mount point, not merely a directory of that name, and keeps the
  # log in /run when it is not. The log on the medium`s own FAT partition is the ONE artifact that
  # can leave a device that failed to install -- pull the card, read it on a PC. `nofail` because an
  # installer that refuses to boot over a missing log destination has traded the whole tool for the
  # diagnostic. `x-systemd.device-timeout` so a medium without the partition does not spend 90s at it.
  install -d -m0755 /target/esp
  printf "LABEL=%s /esp vfat rw,nofail,noatime,umask=0077,x-systemd.device-timeout=5s 0 2\n" \
      "$(cat /prebuilt/esp-label)" >>/target/etc/fstab

  # ---- offline application ------------------------------------------------------------------------
  # tmpfiles and the journal catalog, both run with --root= rather than chrooted. pacman`s own
  # post-transaction hooks try the chrooted form, fail for want of /proc, and pacman treats a failed
  # hook as a warning -- so the build stays green with none of these directories created. The root is
  # SQUASHFS at runtime, so a directory tmpfiles would create on first boot cannot appear at all.
  # Not fatal on non-zero: an offline run legitimately cannot satisfy every line (/proc, /sys, /dev,
  # ACL ops), and systemd-tmpfiles returns non-zero if ANY line failed.
  if ! systemd-tmpfiles --root=/target --create; then
    echo "[novadeck] systemd-tmpfiles --root exited $? (partial offline application; see above)" >&2
  fi
  if ! journalctl --root=/target --update-catalog; then
    echo "[novadeck] journalctl --root --update-catalog exited $? (no message catalog)" >&2
  fi

  # Recorded LAST, so the marker`s presence proves the whole bootstrap ran. A run that died anywhere
  # above leaves none, so the next build re-bootstraps instead of shipping a half-populated root --
  # and install/genlock.sh refuses to lock a tree without it.
  install -Dm0644 /prebuilt/pkgs /target/usr/lib/novadeck/pkgs
' >&2
# ^ the container`s stdout (pacman progress) goes to stderr: this script`s stdout must carry ONLY
#   the rootfs path, which the Makefile and install/mkimage.sh capture.

if [ -z "$SEED_SHA" ]; then
  log "WARNING: no steam-seed pin baked in (NOVADECK_SEED_SHA256= or install/steam-seed.sha256)."
  log "         This image boots, draws consent and carves, and then REFUSES at the seed step."
fi
log "installer root ready ($(du -sh "$DEST" 2>/dev/null | cut -f1) at ${DEST#"$ROOT"/})"
echo "$DEST"
