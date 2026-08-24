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
# TEST-ONLY remote access, exactly the split [[wifi-config-is-test-only]] describes for the shipped
# image: a RELEASE installer has no sshd enabled and no key, because a published recovery medium
# that anyone can download must not carry a credential anyone can extract. NOVADECK_DEV=1 turns it
# on for a bring-up medium, and that is the only build that can be logged into.
#
# WHY IT IS WORTH HAVING AT ALL. This image has no UART ([[sm8650-no-uart]]), the panel has no
# keyboard, and install/save-log.sh only writes the ESP once systemd has got far enough to STOP the
# unit. So an early failure — the squashfs not mounting, systemd.volatile=state misbehaving without
# an initrd — is a black panel and no evidence whatsoever. Three assumptions on this medium are
# reasoned rather than measured, and this is what makes the first one that breaks diagnosable.
DEV="${NOVADECK_DEV:-}"
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
  # HW-FOUND 2026-08-24: select-target.sh sources lib-gpt.sh and died with "cannot find lib-gpt.sh"
  # on the first medium that got far enough to look for a disk. gather_preflight() read that
  # non-zero exit as "no install target", which is a NORMAL outcome, so the UI fell back to its
  # idle screen and said nothing at all. install/test-mkroot.sh checked that the four files listed
  # here existed; nothing checked the list was COMPLETE against what the code actually sources.
  "images/lib-gpt.sh:lib-gpt.sh"
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
# InputPlumber's BOARD configs, which are ours and live in the overlay — the prebuilt tarball ships
# the daemon and its generic configs, not the per-board ones. HW-FOUND 2026-08-24: without these the
# daemon comes up, recognises none of the handheld MCU gamepads, SDL sees no mappable controller,
# and the UI stops on §4d's "No controller or keyboard" screen — correctly, having been told the
# truth. The installer ships InputPlumber precisely so its input path is IDENTICAL to the
# HW-validated main-image one, and the configs are most of what makes it identical.
IP_DIR="$ROOT/fs-overlay/etc/inputplumber"
[ -x "$DEVICE_ENV" ] || die "no ${DEVICE_ENV#"$ROOT"/} — every board would draw a generic output"
[ -d "$DEVICES_DIR" ] || die "no ${DEVICES_DIR#"$ROOT"/} — device-env would resolve no board"
[ -d "$IP_DIR/devices.d" ] && [ -d "$IP_DIR/capability_maps.d" ] \
  || die "no ${IP_DIR#"$ROOT"/} — the pad would not be recognised and the UI would stop on 'No controller'"

# ---- firmware: THE SAME TWO TREES THE CARD GETS, wholesale -------------------------------------------
# install/pkgs.list has no `linux-firmware`. The shipped image gets firmware from these two staging
# trees, installed by images/assemble-rootfs.sh (its blocks 3 and 3b) — and this image never runs
# that script, so the first medium had a 16 KB /usr/lib/firmware and no Wi-Fi at all: no ath12k, so
# no wlan interface, so nothing to associate and nothing for a router to show. It read as a hostname
# or DHCP fault and was neither. (The GPU worked regardless, which is what hid it: the Adreno
# SQE/GMU/zap blobs are compiled INTO the kernel via kernel/embed.list, so Turnip came up on an
# Adreno 750 with an essentially empty firmware tree.)
#
# WHOLESALE, NOT CURATED, and the first attempt here got that wrong (user's call, 2026-08-24). I
# shipped a hand-written firmware.list carrying ath12k because the board on the bench was an
# SM8650 — and the SM8250 machines use a QCA6390 on **ath11k**, a different driver whose blobs live
# in the other tree, so those boards would have hit the identical invisible no-Wi-Fi failure. One
# medium serves the whole fleet, and a list that must enumerate every radio across a growing fleet
# goes stale silently, on the one tool you reach for when a device is ALREADY broken.
#
# It is also the principle this image already applies to input: InputPlumber ships here so the
# installer's input path is IDENTICAL to the HW-validated main-image one rather than a second stack.
# Curating firmware by hand was the opposite of that, in the same file. Taking both trees whole
# makes hardware support identical to the image being installed BY CONSTRUCTION, and adding a board
# or a blob to the main image covers the installer with no second edit.
#
# The cost is ~260 MB raw on a medium written to an SD card, which is the cheapest thing being
# traded here.
# ---- kernel modules, without which the firmware above is inert ---------------------------------------
# HW-FOUND 2026-08-24, the boot AFTER the firmware fix: still no Wi-Fi. The whole 802.11 stack is
# MODULAR (CONFIG_CFG80211=m, CONFIG_MAC80211=m, CONFIG_ATH11K=m), and this root had no
# /usr/lib/modules at all -- so the medium carried ath11k/ath12k firmware and no driver to load it.
# Firmware with no driver does exactly nothing, and the symptom is identical to having neither: no
# wlan interface, nothing to associate, nothing on the router.
#
# This is the THIRD thing missing for one reason -- the installer root never runs
# images/assemble-rootfs.sh, so everything that script installs beyond packages has to be repeated
# here. Its stage 2b is this one. Fixing them one symptom at a time is what let the same cause
# produce three separate hardware trips; the remaining stages were audited rather than guessed
# (kernel/dtbs and /boot are on the ESP instead, and the slot/var/home stages have no meaning on a
# medium with no slots).
MODROOT="$ROOT/out/modroot"
KVER="$(ls "$MODROOT/lib/modules" 2>/dev/null | head -1)"
[ -n "$KVER" ] && [ -f "$MODROOT/lib/modules/$KVER/modules.dep" ] \
  || die "no built kernel modules at ${MODROOT#"$ROOT"/} — run: make kernel"

# The overlay's udev rules, ALL of them. Two are input-path (uinput permissions, which InputPlumber
# needs, and the SM8250 gamepad rules); the rest are hardware behaviour that is simply inert when
# the device is absent. Taken whole for the same reason the firmware trees are: hand-picking from a
# hardware-support set is what produced the ath11k hole.
UDEV_DIR="$ROOT/fs-overlay/usr/lib/udev/rules.d"
[ -d "$UDEV_DIR" ] || die "no ${UDEV_DIR#"$ROOT"/} — uinput permissions and the pad rules would be missing"

FW_QCOM_DIR="$ROOT/firmware/qcom-fw"
FW_LINUX_DIR="$ROOT/firmware/linux-fw"
FW_QCOM_STAMP="$FW_QCOM_DIR/sha256sums.txt"
FW_LINUX_STAMP="$FW_LINUX_DIR/.fetched.stamp"
[ -f "$FW_QCOM_STAMP" ]  || die "no device firmware at ${FW_QCOM_DIR#"$ROOT"/} — run: make fw-qcom"
[ -f "$FW_LINUX_STAMP" ] || die "no linux-firmware at ${FW_LINUX_DIR#"$ROOT"/} — run: make fw-linux"
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
esplabel:$ESP_LABEL
firmware:$(sha256sum "$FW_QCOM_STAMP" "$FW_LINUX_STAMP" | sha256sum | cut -d' ' -f1)
inputplumber:$(cat "$IP_DIR"/*/*.yaml 2>/dev/null | sha256sum | cut -d' ' -f1)
udev:$(cat "$UDEV_DIR"/*.rules 2>/dev/null | sha256sum | cut -d' ' -f1)
modules:$KVER:$(sha256sum "$MODROOT/lib/modules/$KVER/modules.dep" | cut -d' ' -f1)
dev:${DEV:-0}
sshkey:$(printf '%s' "${NOVADECK_SSH_PUBKEY:-none}" | sha256sum | cut -d' ' -f1)
wifi:$(printf '%s\n%s\n%s' "${NOVADECK_WIFI:-}" "${NOVADECK_WIFI_SSID:-none}" "${NOVADECK_WIFI_PSK:-none}" | sha256sum | cut -d' ' -f1)"
# The credentials are HASHED into the key, never written to it: this marker is installed into the
# image as /usr/lib/novadeck/pkgs, so a plaintext PSK here would ship on the medium. Hashing still
# busts the cache when either value changes, which is the only thing the key needs to do.
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
# InputPlumber's board configs and the declared firmware, staged with their tree-relative paths
# intact so the container can lay them down without knowing which source tree each came from.
mkdir -p "$STAGE/inputplumber"
cp -a "$IP_DIR/." "$STAGE/inputplumber/"
mkdir -p "$STAGE/udev-rules"
cp -a "$UDEV_DIR/." "$STAGE/udev-rules/"
# The firmware trees are NOT copied into the staging directory: they are ~260 MB and would be
# duplicated on every build. They cross as their own read-only mounts instead (see the docker run).
cp    "$KEYRING_SRC" "$STAGE/keyring.pem"
cp    "$PACMANCONF"  "$STAGE/pacman.conf"
cp    "$OSRELEASE"   "$STAGE/os-release"
if [ -n "$SEED_SHA" ]; then printf '%s\n' "$SEED_SHA" >"$STAGE/steam-seed.sha256"; fi
# The dev credential crosses as a FILE, and its presence is what the container branches on — the
# same idiom images/customize-base.sh uses for dev.pkgs, and for the same reason: it keeps another
# layer of quoting out of the single-quoted bash -c.
if [ -n "$DEV" ]; then
  if [ -n "${NOVADECK_SSH_PUBKEY:-}" ]; then
    printf '%s\n' "$NOVADECK_SSH_PUBKEY" >"$STAGE/authorized_keys"
  else
    log "WARNING: NOVADECK_DEV=1 but NOVADECK_SSH_PUBKEY is unset — sshd is key-only, so it will"
    log "         admit nobody. Source dev.env before building a bring-up medium."
  fi

  # A Wi-Fi profile, and it is what makes the sshd above WORTH having. Joining a network otherwise
  # happens through the UI's §4b network screen — so on the one failure this medium exists to
  # diagnose, a dead GUI, there is no way to drive the join and therefore no network and no shell.
  # USB-C Ethernet covers it, but only if one is to hand. Same NOVADECK_WIFI intent knob and same
  # creds as the dev card (dev.env), so there is one place to set them.
  if [ "${NOVADECK_WIFI:-}" != 0 ] && [ -n "${NOVADECK_WIFI_SSID:-}" ] && [ -n "${NOVADECK_WIFI_PSK:-}" ]; then
    # Written on the HOST and carried in as a file: the PSK must not be interpolated into the
    # container's single-quoted bash -c (a quote in a passphrase would end the string), and a file
    # keeps it off any process command line. umask 077 because NM IGNORES a profile that is not
    # 0600 root-owned, logging only "ignoring due to permissions".
    ( umask 077; cat >"$STAGE/wifi.nmconnection" <<WIFIEOF
[connection]
id=${NOVADECK_WIFI_SSID}
type=wifi
autoconnect=true

[wifi]
mode=infrastructure
ssid=${NOVADECK_WIFI_SSID}

[wifi-security]
key-mgmt=wpa-psk
psk=${NOVADECK_WIFI_PSK}

[ipv4]
method=auto

[ipv6]
method=auto
WIFIEOF
    )
    printf '%s\n' "$NOVADECK_WIFI_SSID" >"$STAGE/wifi.ssid"
    log "TEST BUILD: baking a Wi-Fi profile for '$NOVADECK_WIFI_SSID' (the PSK is never logged)"
  elif [ "${NOVADECK_WIFI:-}" = 1 ]; then
    die "NOVADECK_WIFI=1 requires NOVADECK_WIFI_SSID + NOVADECK_WIFI_PSK"
  else
    log "TEST BUILD: no Wi-Fi profile (set NOVADECK_WIFI_SSID + NOVADECK_WIFI_PSK in dev.env.local)."
    log "            Without one the medium is reachable over USB-C Ethernet only."
  fi
fi
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
  -v "$FW_QCOM_DIR":/fw-qcom:ro \
  -v "$FW_LINUX_DIR":/fw-linux:ro \
  -v "$MODROOT":/modroot:ro \
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

  # Firmware, both trees whole -- the same content images/assemble-rootfs.sh puts on the card, from
  # the same sources, so hardware support is identical to the image being installed BY CONSTRUCTION
  # rather than by a list somebody has to remember to extend. /usr/lib/firmware is where the kernel
  # looks; the shipped image writes /lib/firmware, the same directory through the usr-merge symlink.
  # The two bookkeeping files are excluded: they describe the staging trees, not the device.
  install -d -m0755 /target/usr/lib/firmware
  for src in /fw-qcom /fw-linux; do
    [ -d "$src" ] || continue
    cp -a "$src/." /target/usr/lib/firmware/
  done
  rm -f /target/usr/lib/firmware/sha256sums.txt /target/usr/lib/firmware/.fetched.stamp
  chmod -R u=rwX,go=rX /target/usr/lib/firmware
  echo "[novadeck] firmware: $(find /target/usr/lib/firmware -type f | wc -l) files, $(du -sh /target/usr/lib/firmware | cut -f1)" >&2

  # Kernel modules. The 802.11 stack is modular, so without these the firmware above is inert and
  # there is no wlan interface at all. modroot is the tree kernel/build.sh produced with
  # modules_install, so modules.dep and friends are already generated and correct for this kernel;
  # it is copied verbatim rather than re-depmod-ed in an emulated container.
  if [ -d /modroot/lib/modules ]; then
    install -d -m0755 /target/usr/lib/modules
    cp -a /modroot/lib/modules/. /target/usr/lib/modules/
    echo "[novadeck] modules: $(find /target/usr/lib/modules -name \*.ko | wc -l) for kernel $(ls /target/usr/lib/modules | head -1)" >&2
  else
    echo "no kernel modules mounted at /modroot -- the medium would have no wifi driver" >&2
    exit 1
  fi

  # The overlay udev rules, all of them (see the host half). Without 70-novadeck-uinput.rules
  # InputPlumber cannot get at /dev/uinput.
  if [ -d /prebuilt/udev-rules ]; then
    install -d -m0755 /target/usr/lib/udev/rules.d
    install -m0644 /prebuilt/udev-rules/*.rules /target/usr/lib/udev/rules.d/
    echo "[novadeck] udev: $(ls /prebuilt/udev-rules/*.rules | wc -l) overlay rules" >&2
  fi

  # InputPlumber board configs. Without them the daemon runs but recognises none of the handheld
  # MCU gamepads, and the UI stops on the no-input screen -- HW-found on the first medium that got
  # far enough to draw anything.
  if [ -d /prebuilt/inputplumber ]; then
    install -d -m0755 /target/etc/inputplumber
    cp -a /prebuilt/inputplumber/. /target/etc/inputplumber/
    chmod -R u=rwX,go=rX /target/etc/inputplumber
    # \*.yaml, not the quoted form: a single quote here would end the enclosing bash -c string.
    echo "[novadeck] inputplumber: $(find /target/etc/inputplumber -name \*.yaml | wc -l) board configs" >&2
  fi

  # The RAUC keyring, at the path the spine and /etc/rauc/system.conf both name. 0444: it is a
  # public certificate and nothing on this image should ever rewrite it.
  install -Dm0444 /prebuilt/keyring.pem /target/etc/rauc/keyring.pem

  # The baked seed pin, when the build was given one. Absent, the spine refuses at the seed step --
  # which is the correct behaviour and is checked THERE, not duplicated here.
  if [ -f /prebuilt/steam-seed.sha256 ]; then
    install -Dm0644 /prebuilt/steam-seed.sha256 /target/usr/lib/novadeck/install/steam-seed.sha256
  fi

  # ---- units --------------------------------------------------------------------------------------
  # Named, not globbed: install/units/ also holds novadeck-installer-hostkey.service, which is a
  # TEST-BUILD unit and is installed further down only when a dev credential was staged. A glob
  # here would put it on the released medium too — inert, since nothing pulls it in without the
  # sshd drop-in, but a test artifact on a published image is how the next one stops being inert.
  install -m0644 /prebuilt/units/novadeck-installer.service \
                 /prebuilt/units/novadeck-installer-console.service \
                 /target/usr/lib/systemd/system/
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

  # systemd-timesyncd IS ENABLED, and on these boards it is not optional -- it is the only way this
  # machine can ever know the time. HW-FOUND 2026-08-24: the medium reached the network screen and
  # reported the update server unreachable. It was neither DNS nor the server (which answered 404
  # from the build host, and netcfg correctly treats a 404 as reachable). curl said:
  #
  #   curl: (60) certificate is not yet valid or the system clock is incorrect (9)
  #
  # The clock read Jul 06 with the real date Aug 24, because THERE IS NO /dev/rtc on these boards --
  # the PMIC RTC probe defers forever (issue #38) -- so the clock starts at systemd`s epoch and
  # every TLS certificate is not-yet-valid. The shipped image gets away with more here; a recovery
  # medium that must fetch a multi-gigabyte bundle over HTTPS does not.
  #
  # IT HAS TO BE ENABLED AT BUILD TIME. `timedatectl set-ntp true` fails on this image with
  # "File /etc/systemd/system/dbus-org.freedesktop.timesync1.service: Read-only file system" --
  # the read-only /etc means the runtime path is closed, so the preset and the symlink are the only
  # way in. VERIFIED on the device before shipping: starting the unit by hand moved the clock from
  # Jul 06 to the correct Aug 24, NTPSynchronized=yes, curl returned HTTP 404 and netcfg went from
  # STATE=no-host to STATE=online.
  echo "enable systemd-timesyncd.service" >>/target/etc/systemd/system-preset/60-novadeck-network.preset
  install -d -m0755 /target/etc/systemd/system/sysinit.target.wants
  ln -sf /usr/lib/systemd/system/systemd-timesyncd.service \
         /target/etc/systemd/system/sysinit.target.wants/systemd-timesyncd.service
  # dbus activation, the same pair `systemctl enable` would make. Without it timedatectl and
  # anything else talking to org.freedesktop.timesync1 cannot start the daemon on demand.
  ln -sf /usr/lib/systemd/system/systemd-timesyncd.service \
         /target/etc/systemd/system/dbus-org.freedesktop.timesync1.service

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

  # ---- TEST-ONLY remote access ----------------------------------------------------------------------
  # Present only when the host staged an authorized_keys, i.e. NOVADECK_DEV=1 with a key. A release
  # installer leaves sshd installed but never enabled, so it listens on nothing.
  #
  # HOST KEYS GO IN /run, AND THAT IS THE DIFFERENCE FROM THE MAIN IMAGE. images/assemble-rootfs.sh
  # argues at length for NOT baking host keys and letting openssh`s own sshdgenkeys.service run
  # `ssh-keygen -A` at first start -- correct there, because its /etc is an overlayfs with the upper
  # in /var and therefore writable. Here /etc is squashfs. sshdgenkeys would fail on every boot, and
  # sshd only Wants= it so it would then start with no host key and refuse every connection. The two
  # reasons that block gives for not baking still apply, and are why the key is generated per boot
  # into tmpfs rather than shipped: a baked key is a property of the BUILD, extractable by anyone
  # holding the published image, and identical on every device flashed from it.
  # The Wi-Fi profile. Independent of the SSH block below on purpose -- they are two separate
  # test-only injections and either is useful without the other.
  #
  # IT GOES IN /usr/lib, NOT /etc, and this image forces that rather than preferring it. The
  # keyfile plugin`s `path=` was pointed at /run further up so nmcli can write on a read-only root,
  # and `path=` is the ONE directory NM both reads and writes -- so a profile dropped under
  # /etc/NetworkManager/system-connections would never be looked at. NM ALSO reads
  # /usr/lib/NetworkManager/system-connections and /run/... as read-only sources whatever `path=`
  # says; all three strings are compiled into the NetworkManager binary this image ships, checked
  # with `strings` rather than taken from documentation. /usr/lib is the right one of the two: it is
  # the distro-defaults location, genuinely read-only here, and cannot be clobbered at runtime by a
  # profile nmcli writes into /run.
  if [ -f /prebuilt/wifi.nmconnection ]; then
    install -d -m0755 /target/usr/lib/NetworkManager/system-connections
    install -m0600 /prebuilt/wifi.nmconnection \
      "/target/usr/lib/NetworkManager/system-connections/$(cat /prebuilt/wifi.ssid).nmconnection"
    echo "[novadeck] TEST BUILD: Wi-Fi profile baked (autoconnect at boot)" >&2
  fi

  if [ -f /prebuilt/authorized_keys ]; then
    install -d -m0700 /target/root/.ssh
    install -m0600 /prebuilt/authorized_keys /target/root/.ssh/authorized_keys

    install -d -m0755 /target/etc/ssh/sshd_config.d
    printf "%s\n" \
      "# novadeck installer, TEST BUILD ONLY: the root is read-only squashfs, so the host key" \
      "# cannot live in /etc. It is generated into tmpfs per boot by the drop-in below." \
      "HostKey /run/ssh/ssh_host_ed25519_key" \
      >/target/etc/ssh/sshd_config.d/00-novadeck-installer.conf

    # The key generator is a COMMITTED unit file (install/units/), not text printf-ed from here.
    # A unit generated inside this container is a unit images/test-units.sh never lints, and a
    # misspelled directive is silently IGNORED by systemd rather than rejected
    # ([[systemd-execonfailure-is-not-a-directive]]) — so the one unit whose failure mode is "no
    # remote access on the image whose remote access is the whole point" would have been the one
    # nothing checked. It carries its own reasoning; see the file.
    install -m0644 /prebuilt/units/novadeck-installer-hostkey.service \
                   /target/usr/lib/systemd/system/novadeck-installer-hostkey.service

    install -d -m0755 /target/etc/systemd/system/sshd.service.d
    printf "%s\n" \
      "[Unit]" \
      "Requires=novadeck-installer-hostkey.service" \
      "After=novadeck-installer-hostkey.service" \
      >/target/etc/systemd/system/sshd.service.d/00-novadeck-installer.conf

    # Mask openssh`s own generator rather than leave it failing. sshd only Wants= it, so its failure
    # would not stop the boot -- it would just put a red unit and a misleading "permission denied"
    # on /etc/ssh in the journal of the one image whose journal is the whole diagnostic.
    ln -sf /dev/null /target/etc/systemd/system/sshdgenkeys.service

    echo "enable sshd.service" >>/target/etc/systemd/system-preset/60-novadeck-network.preset
    ln -sf /usr/lib/systemd/system/sshd.service \
           /target/etc/systemd/system/multi-user.target.wants/sshd.service
    echo "[novadeck] TEST BUILD: sshd enabled, key-only root, host key regenerated per boot" >&2
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
