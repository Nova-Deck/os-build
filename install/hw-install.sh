#!/usr/bin/env bash
# Phase 4 hardware STAGER for install/novadeck-install — the destructive peer of
# install/hw-select-target.sh. Plan verification step 3.
#
#   install/hw-install.sh [options] root@<device>
#
# IT STAGES AND IT PRE-FLIGHTS. IT DOES NOT INSTALL. Everything this script does on the device is
# read-only or confined to /run and /home on the INSTALLER MEDIUM (the dev card); it writes nothing
# to any internal disk and it never invokes the spine's destructive path. The last thing it prints
# is the one command that does, for a human to read and run. That separation is deliberate: a stager
# that also ran the install would put "erase this device's Android" one shell-history arrow-up away,
# and it would have to answer the consent gate itself, which §4d forbids outright.
#
# WHY A STAGER IS NEEDED AT ALL, rather than "scp the scripts and run them". The dev card runs the
# SHIPPED image, and §4c's spine is written against the INSTALLER image, which does not exist yet
# (Phase 6). Four gaps separate the two, and every one of them is a run that dies somewhere useless:
#
#   1. FOUR BINARIES ARE ABSENT — sgdisk, mdir, mkfs.vfat, partprobe. See install/lib-hwstage.sh,
#      which owns the pins and the DT_NEEDED closures. recon() catches all four at second zero, so
#      the failure is cheap, but it is still four round trips to find out by hand.
#   2. THREE FIXED PATHS POINT INTO A READ-ONLY ROOTFS — the consent renderer, the Steam-seed pin
#      and the RAUC post-install handler all default under /usr/lib/novadeck/install/, and the two
#      that are installer-only are not there on a dev card. The generated `run-install` wrapper
#      redirects them, and that wrapper is the only reason the printed command fits on a line.
#   3. THE WORKING TREE MUST WIN OVER THE CARD'S BAKED COPIES. genpart.sh, partition-table.txt and
#      lib-slotwrite.sh all ship into the rootfs, so a dev card carries whatever they looked like
#      when it was flashed. Every component resolves $SELFDIR first, so staging the repo's copies
#      into one flat directory is what makes the gate test the code under review rather than the
#      code under the card.
#   4. /run IS TMPFS. The stage is gone at every reboot, and a hardware gate is several reboots.
#      Re-run this script; it is idempotent and, once the seed is on the device, takes seconds.
#
# THE SEED DOES NOT GO IN /run, AND THAT IS THE ONE PLACE THIS DEPARTS FROM THE RELEASE PATH.
# novadeck-install fetches an http seed straight into $RUNDIR and says in its own comment that this
# is not how the release path should end up. It is worse here than there: ~1 GB of tmpfs is ~1 GB of
# RAM taken from the machine that is about to stream a ~4 GB bundle, and it evaporates at every
# reboot. So by default the tarball is pushed once to the dev card's /home — persistent, roomy, and
# on the installer medium rather than the target — and handed to the spine as a PATH, which
# --home-seed accepts natively. `--seed-mode http` serves it beside the bundle instead, which is
# what §4b will do for real, and is the mode to use when that is what is being tested.
#
# THE BUNDLE IS ALWAYS HTTP. rauc streams it over NBD and needs Range, which is why the server is
# nginx and not `python3 -m http.server`.
set -euo pipefail

PROG=${0##*/}
log()  { printf '[%s] %s\n' "$PROG" "$1" >&2; }
die()  { printf '[%s] ERROR: %s\n' "$PROG" "$1" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib-hwstage.sh
. "$ROOT/install/lib-hwstage.sh"

STAGE=/run/novadeck/install-stage       # tmpfs; rebuilt by every run of this script
SEED_DIR=/home/deck/novadeck-install    # persistent on the dev card; survives the reboots

BUNDLE=""; SEED_SRC=""; SEED_MODE=push; PORT=8088; SERVE=1; PREFLIGHT=1; HTTP_HOST=""
usage() {
  cat >&2 <<EOF
usage: $PROG [options] <user@host>

  --bundle <file>      .raucb to serve; default the newest out/images/*.raucb
  --seed <dir|tar>     Steam seed; default work/steam-seed, repacked to a pinned tarball
  --seed-mode push|http  how the seed reaches the device (default push, see the header)
  --port <n>           port the bundle is served on (default $PORT)
  --http-host <addr>   address the DEVICE should reach this host at; default: asked of the device
  --no-serve           stage only; print the docker command instead of running it
  --no-preflight       skip the read-only checks on the device
EOF
  exit 2
}

HOST=""
while [ $# -gt 0 ]; do
  case "$1" in
    --bundle)     BUNDLE="${2:-}"; shift 2 ;;
    --seed)       SEED_SRC="${2:-}"; shift 2 ;;
    --seed-mode)  SEED_MODE="${2:-}"; shift 2 ;;
    --port)       PORT="${2:-}"; shift 2 ;;
    --http-host)  HTTP_HOST="${2:-}"; shift 2 ;;
    --no-serve)   SERVE=0; shift ;;
    --no-preflight) PREFLIGHT=0; shift ;;
    -h|--help)    usage ;;
    -*)           printf '%s: unknown option %s\n' "$PROG" "$1" >&2; usage ;;
    *)            [ -z "$HOST" ] || usage; HOST="$1"; shift ;;
  esac
done
[ -n "$HOST" ] || usage
case "$SEED_MODE" in push|http) ;; *) die "--seed-mode must be push or http" ;; esac

hwstage_init "$ROOT"
hwstage_ssh_opts

# =================================================================================================
# 1. the binaries the shipped image does not carry
# =================================================================================================
hwstage_fetch sgdisk mdir mkfs.vfat partprobe libparted || die "could not stage the installer binaries"
log "binaries: sgdisk, mdir, mkfs.vfat, partprobe (+ libparted.so.2)"

# =================================================================================================
# 2. the bundle
# =================================================================================================
if [ -z "$BUNDLE" ]; then
  # Newest by mtime rather than by name: the version stamp sorts correctly today but a rebuild of an
  # older tag would not, and picking the wrong bundle here is a whole install spent on it.
  BUNDLE="$(find "$ROOT/out/images" -maxdepth 1 -name '*.raucb' -printf '%T@ %p\n' 2>/dev/null \
            | sort -rn | head -1 | cut -d' ' -f2-)"
  [ -n "$BUNDLE" ] || die "no bundle in out/images -- run 'make bundle', or pass --bundle"
fi
[ -f "$BUNDLE" ] || die "no bundle at $BUNDLE"
# Absolute, because docker's -v refuses a relative source with a message about volume NAMES that
# says nothing about the actual cause.
BUNDLE="$(cd "$(dirname "$BUNDLE")" && pwd)/$(basename "$BUNDLE")"
log "bundle: ${BUNDLE#"$ROOT"/} ($(du -h "$BUNDLE" | cut -f1))"

# =================================================================================================
# 3. the Steam seed, and its pin
# =================================================================================================
# THE PIN IS THE SHA256 OF THE TARBALL'S BYTES, not of the tree, because that is what the spine
# hashes: verify_sources() runs sha256sum over the file it was handed. So the tarball has to be a
# stable artifact rather than something regenerated per run -- repacking on every invocation would
# produce a new hash each time and the pin would be a tautology rather than a check.
SEED_TAR="$HWSTAGE_CACHE/steam-seed.tar.zst"
SEED_SHA_FILE="$HWSTAGE_CACHE/steam-seed.sha256"
[ -n "$SEED_SRC" ] || SEED_SRC="$ROOT/work/steam-seed"

if [ -f "$SEED_SRC" ]; then
  SEED_TAR="$SEED_SRC"                       # already a tarball; take it as given
elif [ -d "$SEED_SRC" ]; then
  # The staleness check is the seed DIRECTORY's mtime, which only moves when its top level does --
  # a refetch that rewrote files deeper in the tree will not trip it. That is the same bargain
  # steam-seed/fetch-steam-seed.sh makes, and the same escape hatch applies: delete the tarball to
  # force a repack. A wrong answer here is loud rather than silent -- the pin is derived from the
  # tarball, so a stale tarball installs a stale seed, it does not fail a hash.
  if [ ! -f "$SEED_TAR" ] || [ "$SEED_SRC" -nt "$SEED_TAR" ]; then
    log "packing $(du -sh "$SEED_SRC" | cut -f1) of Steam seed -> ${SEED_TAR#"$ROOT"/} (minutes)"
    # Contents, not the directory: stage_deck_home unpacks this straight into
    # ~deck/.local/share/Steam. --numeric-owner pairs with the -p on the extract side.
    tar --numeric-owner -C "$SEED_SRC" -cf - . | zstd -T0 -3 -q -o "$SEED_TAR.part" \
      || die "cannot pack the Steam seed"
    mv "$SEED_TAR.part" "$SEED_TAR"
    rm -f "$SEED_SHA_FILE"
  fi
else
  die "no Steam seed at $SEED_SRC (run steam-seed/fetch-steam-seed.sh, or pass --seed)"
fi

if [ ! -f "$SEED_SHA_FILE" ] || [ "$SEED_TAR" -nt "$SEED_SHA_FILE" ]; then
  sha256sum <"$SEED_TAR" | cut -d' ' -f1 >"$SEED_SHA_FILE" || die "cannot hash the Steam seed"
fi
SEED_TAR="$(cd "$(dirname "$SEED_TAR")" && pwd)/$(basename "$SEED_TAR")"   # docker -v, as above
SEED_SHA="$(cat "$SEED_SHA_FILE")"
log "seed: ${SEED_TAR#"$ROOT"/} ($(du -h "$SEED_TAR" | cut -f1), sha256 ${SEED_SHA:0:16}…)"

# =================================================================================================
# 4. the HTTP server
# =================================================================================================
# nginx in docker, not `python3 -m http.server`: rauc streams the bundle over NBD and issues Range
# requests, which http.server answers with a 200 and the whole file -- the install then appears to
# work and is slow, wrong, or both, depending on how rauc reconciles the offsets.
#
# EXPECT `using HTTP/1 for streaming, expect slow installation` FROM RAUC, AND DO NOT CHASE IT.
# Measured 2026-08-21 against the ACE: serving with `http2 on;` (h2c, verified working from the
# host with `curl --http2-prior-knowledge`) does NOT silence it -- rauc does not attempt
# prior-knowledge h2 over cleartext, so h2 arrives via TLS ALPN or not at all. The production OTA
# vhost has both (ota/nginx-novadeck-ota.conf), and giving this lab server TLS would mean a cert
# the device trusts, for a stream that only has to finish once. So the gate runs on HTTP/1 and is
# slower than the release path will be. That is a property of the harness, not a defect.
#
# THE FILES ARE BIND-MOUNTED ONE BY ONE, not assembled into a docroot. An earlier draft hardlinked
# them into a staging directory and that is wrong twice: `make bundle` runs in the container so
# out/images is ROOT-OWNED, and protected_hardlinks refuses a link to a file you do not own, so the
# fallback silently COPIED 4 GB on every run. Binding the individual files also means nothing else
# in out/images is exposed on the LAN, which mounting the directory would have done.
#
# CONSEQUENCE: THIS SERVES FILES, NOT AN OTA CHANNEL, and that is correct for what it is for -- the
# installer fetches ONE bundle by direct URL and verifies it against the device's keyring. But
# `novadeck-update` wants `<url>/<channel>/latest.json` and resolves `bundle` relative to it, which
# is a DIRECTORY shape this server cannot answer: every path under /stable/ is a 404.
#
# So the OTA leg of the hardware gate needs its own server, e.g.
#   docker run -d --name nd-ota-http -p 8089:80 \
#     -v "$PWD/out/images:/usr/share/nginx/html:ro" nginx:alpine
# with out/images/stable/{latest.json, <symlink to the bundle>}. Do not "fix" this one to mount the
# directory -- the two reasons above still hold.
#
# WHEN IT LOOKS LIKE THE SERVER IS BROKEN, IT USUALLY IS NOT. `novadeck-update` exits instantly and
# silently in two very different situations: a 404 on latest.json, and Steam not being signed in
# (it defers on purpose, so OOBE never starts a 4 GB download). `novadeck-update status` separates
# them in one command -- it prints the resolved server URL, `logged in:`, and `available:`. Reach
# for it before touching the server. Cost 20 minutes and a wrong hypothesis on 2026-08-22.
CONTAINER=novadeck-hw-http
BUNDLE_NAME="$(basename "$BUNDLE")"
SEED_NAME="$(basename "$SEED_TAR")"

DOCKER_CMD=(docker run -d --rm --name "$CONTAINER" -p "$PORT:80"
            -v "$BUNDLE:/usr/share/nginx/html/$BUNDLE_NAME:ro")
if [ "$SEED_MODE" = http ]; then
  DOCKER_CMD+=(-v "$SEED_TAR:/usr/share/nginx/html/$SEED_NAME:ro")
fi
DOCKER_CMD+=(nginx:alpine)
if [ "$SERVE" = 1 ]; then
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  "${DOCKER_CMD[@]}" >/dev/null || die "cannot start nginx (is docker up?)"
  served="$BUNDLE_NAME"
  if [ "$SEED_MODE" = http ]; then served="$served, $SEED_NAME"; fi
  log "serving $served on :$PORT as container $CONTAINER"
fi

# The address the DEVICE should call us on, asked of the device rather than guessed from `ip route`:
# a build host with several interfaces, a VPN, or a docker bridge offers several plausible answers
# and only one of them is the one the device's packets actually arrived from.
if [ -z "$HTTP_HOST" ]; then
  HTTP_HOST="$(ssh "${SSHOPTS[@]}" "$HOST" 'echo ${SSH_CONNECTION%% *}' 2>/dev/null | tr -d '\r')"
  [ -n "$HTTP_HOST" ] || die "could not learn this host's address from the device; pass --http-host"
fi
BUNDLE_URL="http://$HTTP_HOST:$PORT/$BUNDLE_NAME"

# =================================================================================================
# 5. onto the device
# =================================================================================================
# ONE FLAT DIRECTORY, because that is what every component's own resolver looks at first
# ($SELFDIR, then /usr/lib/novadeck/install/, then a repo-relative path). Flat therefore means the
# working tree wins over the card's baked copies without a single environment variable -- and it
# means a component that silently fell back to the card's copy would be a resolver bug rather than
# something this script has to police.
ssh "${SSHOPTS[@]}" "$HOST" "rm -rf $STAGE && mkdir -p $STAGE/bin $STAGE/lib" \
  || die "cannot prepare $STAGE on the device"

scp "${SSHOPTS[@]}" -q \
  "$ROOT/install/novadeck-install" \
  "$ROOT/install/select-target.sh" \
  "$ROOT/install/carve.sh" \
  "$ROOT/install/rauc-session.sh" \
  "$ROOT/install/post-install-fresh.sh" \
  "$ROOT/install/confirm-tty" \
  "$ROOT/images/genpart.sh" \
  "$ROOT/images/partition-table.txt" \
  "$ROOT/images/lib-homestage.sh" \
  "$ROOT/fs-overlay/usr/lib/novadeck/install/lib-slotwrite.sh" \
  "$SEED_SHA_FILE" \
  "$HOST:$STAGE/" || die "cannot stage the scripts"

scp "${SSHOPTS[@]}" -q "$HWSTAGE_CACHE/bin/"* "$HOST:$STAGE/bin/" || die "cannot stage the binaries"
scp "${SSHOPTS[@]}" -q "$HWSTAGE_CACHE/lib/"* "$HOST:$STAGE/lib/" || die "cannot stage the libraries"
ssh "${SSHOPTS[@]}" "$HOST" "chmod +x $STAGE/bin/* $STAGE/novadeck-install $STAGE/select-target.sh \
  $STAGE/carve.sh $STAGE/rauc-session.sh $STAGE/post-install-fresh.sh $STAGE/confirm-tty \
  $STAGE/genpart.sh" || die "cannot make the staged components executable"
log "staged $STAGE"

# The seed, pushed once and only if the device does not already hold these exact bytes. It is the
# expensive transfer and the one thing here that outlives a reboot, so re-running this script
# between reboots costs seconds rather than minutes.
SEED_REMOTE=""
if [ "$SEED_MODE" = push ]; then
  SEED_REMOTE="$SEED_DIR/steam-seed.tar.zst"
  if ssh "${SSHOPTS[@]}" "$HOST" \
       "[ -f $SEED_REMOTE ] && [ \"\$(sha256sum <$SEED_REMOTE | cut -d' ' -f1)\" = $SEED_SHA ]"; then
    log "seed: already on the device with the pinned hash"
  else
    log "pushing the seed to $HOST:$SEED_REMOTE (minutes, once)"
    ssh "${SSHOPTS[@]}" "$HOST" "mkdir -p $SEED_DIR" || die "cannot create $SEED_DIR on the device"
    scp "${SSHOPTS[@]}" -q "$SEED_TAR" "$HOST:$SEED_REMOTE" || die "cannot push the Steam seed"
  fi
  SEED_ARG="$SEED_REMOTE"
else
  SEED_ARG="http://$HTTP_HOST:$PORT/$SEED_NAME"
fi

# --- the wrapper -------------------------------------------------------------------------------
# Generated per stage rather than committed, because every value in it is a property of THIS run:
# the URL the bundle is at, the seed's location, and the three fixed paths that have to move because
# the dev card's rootfs is read-only and is not the installer image.
#
# IT SETS PATHS AND NOTHING ELSE. There is no value it could carry that means "consent given" --
# NOVADECK_CONFIRM names WHO renders the screen, which §4d explicitly provides for, and the
# renderer it names still has to display a sequence and read it back. If a variable ever appears
# here that shortcuts the gate, that is the bug, not a convenience.
# shellcheck disable=SC2087  # client-side expansion is the point: every value below is local
ssh "${SSHOPTS[@]}" "$HOST" "cat >$STAGE/run-install && chmod +x $STAGE/run-install" <<EOF
#!/usr/bin/env bash
# GENERATED by install/hw-install.sh -- /run is tmpfs, so this is gone at the next reboot and the
# stager must be re-run. Arguments are passed through to novadeck-install; --bundle and --home-seed
# are already set and can be overridden by passing them again.
set -euo pipefail
export PATH=$STAGE/bin:\$PATH
export LD_LIBRARY_PATH=$STAGE/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}
export NOVADECK_CONFIRM=$STAGE/confirm-tty
export NOVADECK_SEED_PIN=$STAGE/steam-seed.sha256
export POST_INSTALL=$STAGE/post-install-fresh.sh
exec $STAGE/novadeck-install --bundle '$BUNDLE_URL' --home-seed '$SEED_ARG' "\$@"
EOF
log "wrapper: $STAGE/run-install"

# =================================================================================================
# 6. pre-flight — READ ONLY, and every check is one the spine would make later and more expensively
# =================================================================================================
if [ "$PREFLIGHT" = 1 ]; then
  ssh "${SSHOPTS[@]}" "$HOST" "STAGE=$STAGE BUNDLE_URL='$BUNDLE_URL' SEED_ARG='$SEED_ARG' bash -s" <<'REMOTE'
set -u
export PATH="$STAGE/bin:$PATH"
export LD_LIBRARY_PATH="$STAGE/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

echo
echo "== tool inventory (recon()'s list, under the staged PATH) =="
missing=0
for t in sgdisk curl sha256sum mkfs.vfat mkfs.ext4 mkfs.btrfs btrfstune btrfs \
         mount umount tar rauc dbus-daemon gdbus partprobe udevadm mdir sfdisk zstd; do
  if p="$(command -v "$t" 2>/dev/null)"; then printf '  %-14s %s\n' "$t" "$p"
  else printf '  %-14s MISSING\n' "$t"; missing=1; fi
done
# THE LOADER IS THE HALF `command -v` CANNOT SEE. Three of the four staged binaries resolve their
# DT_NEEDED against libraries the image already carries and partprobe pulls libparted.so.2 out of
# $STAGE/lib, so each is actually EXECUTED. A staged binary that resolves on PATH and then dies in
# ld.so is a failure the spine would otherwise meet in the middle of the carve -- mkfs.vfat is
# called after userdata is gone.
for t in sgdisk mdir partprobe; do
  "$t" --version >/dev/null 2>&1 \
    || { echo "  $t resolves but does not RUN -- loader (LD_LIBRARY_PATH?)"; missing=1; }
done
# dosfstools has no --version; 127 is the shell's "could not execute", which is what a failed
# loader looks like from here. Anything else means it ran and rejected the arguments.
mkfs.vfat >/dev/null 2>&1
[ $? -ne 127 ] || { echo "  mkfs.vfat resolves but does not RUN"; missing=1; }
[ "$missing" = 0 ] || echo "  ^ the spine's recon() will refuse on these"

echo
echo "== space (the seed and the bundle both land somewhere) =="
df -h /run /home 2>/dev/null | sed 's/^/  /'

echo
echo "== select-target (read only) =="
out="$("$STAGE/select-target.sh" 2>&1)"; rc=$?
printf '%s\n' "$out" | sed 's/^/  /'
echo "  rc=$rc"

echo
echo "== bundle verify, through the same config the install will use =="
POST_INSTALL="$STAGE/post-install-fresh.sh" "$STAGE/rauc-session.sh" --info "$BUNDLE_URL" 2>&1 \
  | sed 's/^/  /'

echo
echo "== the seed, as the spine will see it =="
case "$SEED_ARG" in
  http*) curl -fsSI "$SEED_ARG" | head -1 | sed 's/^/  /' ;;
  *)     ls -l "$SEED_ARG" 2>&1 | sed 's/^/  /' ;;
esac
REMOTE
fi

# =================================================================================================
cat <<EOF

--------------------------------------------------------------------------------
Staged. Nothing on the device's internal storage has been read or written yet.

THE NEXT COMMAND ERASES ANDROID'S DATA on the target disk. It takes consent at a
terminal (install/confirm-tty), so it needs a tty: -t is not optional.

  ssh -t${SSHOPTS[*]:+ ${SSHOPTS[*]}} $HOST \\
      $STAGE/run-install --intent fresh --userdata-gib <N>

  <N> is how many GiB Android keeps. Pass --disk /dev/sdX to name the target
  explicitly; without it exactly one disk must pass selection.

Afterwards: remove the SD card and reboot. ABL tries internal first.
/run is tmpfs -- re-run this stager after every reboot (seconds; the seed stays).
EOF
if [ "$SERVE" = 1 ]; then
  cat <<EOF

The bundle is served by container $CONTAINER; stop it with
  docker rm -f $CONTAINER
EOF
else
  cat <<EOF

--no-serve: nothing is listening on :$PORT. Start it with
  ${DOCKER_CMD[*]}
EOF
fi
