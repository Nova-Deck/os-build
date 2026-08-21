#!/usr/bin/env bash
# Phase 3 hardware validation of install/select-target.sh — READ ONLY, on a real device.
#
#   install/hw-select-target.sh root@<device> > docs/internal-select-target.md
#
# The offline suite (install/test-select-target.sh) drives the same script against GPTs rebuilt
# from the Phase 0 captures, and it is green — but on IMAGE FILES, where sgdisk always reports
# 512-byte sectors because it only asks the kernel for the logical size on a block device. Real
# UFS LUNs report 4096. So the whole sector-size path, the LUN enumeration, and rules 1/2 (the
# running disk is never a candidate) have no coverage until this runs. That is what this is for,
# and it is the only thing Phase 3 still owed after the suites went green.
#
# NOTHING HERE WRITES TO THE DEVICE outside /run/novadeck/probe, which is tmpfs and gone at the
# next boot. select-target.sh is pure by construction; this wrapper adds no writes of its own,
# which is why it is safe to run against any board at any time, including one carrying an install
# somebody cares about.
#
# TWO binaries are staged rather than assumed, because neither is in the shipped image — both are
# installer-image packages (plan Phase 6):
#
#   sgdisk (gptfdisk)  reads the GPT. Its DT_NEEDED closure — libuuid, libpopt, libstdc++,
#                      libgcc_s — is satisfied by packages the image already carries
#                      (util-linux-libs, popt, gcc-libs are all rows in images/manifest.lock).
#   mdir   (mtools)    reads ESP CONTENT at a byte offset, which is how rule 3b decides whether a
#                      foreign ESP is one ABL would boot. Needs libc and nothing else.
#
# Staging mdir is not a convenience. Without it select-target.sh refuses outright (it fails closed
# since 2026-08-21), and before that change its absence made rule 3b answer "not bootable" for
# every ESP on the disk — which is how the FIT's ROCKNIX install went undetected. Rule 3b has no
# hardware coverage at all unless this binary travels with the script.
#
# Re-check both closures after a snapshot bump; a new dependency surfaces on the DEVICE as a loader
# error, not here as a failed fetch.
set -euo pipefail

host="${1:-}"
[ -n "$host" ] || { echo "usage: ${0##*/} <user@host>   (e.g. root@192.168.1.166)" >&2; exit 2; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cache="$ROOT/work/hw-sgdisk"

# The package, pinned by sha256 the same way every other external artifact in this tree is
# (packages/*/prebuilt.pin, the kernel tarball). The repo it comes from is images/manifest.lock's
# snapshot, read from the file rather than duplicated, so a `make relock` cannot leave this
# fetching from a snapshot the image no longer uses. To bump: change VERSION + SHA256 together
# after a relock, and re-check the NEEDED closure noted above.
GPTFDISK_PKG="gptfdisk-1.0.10-1-aarch64.pkg.tar.zst"
GPTFDISK_SHA256="6512d21ab6b504d36f45bec0c4b0f692179ff4a916707e0f050a1c56f4181704"
# mtools carries an EPOCH, so its filename holds a colon: it must be percent-encoded in the URL and
# kept out of tar's argument (tar reads `name:path` as a REMOTE host). Both are handled by fetching
# to a colon-free local name.
MTOOLS_PKG="mtools-1:4.0.49-1-aarch64.pkg.tar.zst"
MTOOLS_SHA256="1dde2158e72277060b0a7722d223985200cc377a8dc1e1d7b8adcfbc474d0aa4"

snapshot="$(sed -n 's|^# repo snapshot: *||p' "$ROOT/images/manifest.lock" | head -1)"
[ -n "$snapshot" ] || { echo "no '# repo snapshot:' line in images/manifest.lock" >&2; exit 1; }

# --- stage 1: the binaries, fetched once and cached under work/ (gitignored) ------------------
# <pkg-filename> <sha256> <member-in-package> <local-name>
fetch_bin() {
  local pkg="$1" sha="$2" member="$3" out="$4" local_pkg url got
  [ -x "$cache/$out" ] && return 0
  mkdir -p "$cache"
  local_pkg="$cache/${out}.pkg.tar.zst"
  # The only character needing encoding in these names is the epoch's colon.
  url="$snapshot/extra/os/aarch64/${pkg//:/%3A}"
  echo "[novadeck] fetching $pkg" >&2
  curl -fsSL -o "$local_pkg" "$url"
  got="$(sha256sum "$local_pkg" | cut -d' ' -f1)"
  [ "$got" = "$sha" ] || { rm -f "$local_pkg"
    echo "sha256 mismatch for $pkg: got $got, pinned $sha" >&2; exit 1; }
  tar -I zstd -C "$cache" -xf "$local_pkg" "$member"
  # mdir ships as a symlink to the multi-call `mtools` binary, which dispatches on argv[0]; copying
  # it under the name we want is what makes a single file enough.
  cp "$cache/$member" "$cache/$out"
  chmod +x "$cache/$out"
}

fetch_bin "$GPTFDISK_PKG" "$GPTFDISK_SHA256" usr/bin/sgdisk sgdisk
fetch_bin "$MTOOLS_PKG"   "$MTOOLS_SHA256"   usr/bin/mtools mdir
sgdisk="$cache/sgdisk"
mdir="$cache/mdir"

# --- stage 2: onto the device ----------------------------------------------------------------
# The dev card's throwaway key (dev.env mints it). IdentitiesOnly, so an agent holding many keys
# cannot spend the server's auth attempts before this one is offered.
key="$ROOT/work/dev-ssh/id_ed25519"
SSHOPTS=(-o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
[ -f "$key" ] && SSHOPTS+=(-i "$key")

ssh "${SSHOPTS[@]}" "$host" 'mkdir -p /run/novadeck/probe'
scp "${SSHOPTS[@]}" -q "$sgdisk" "$mdir" "$ROOT/install/select-target.sh" "$host:/run/novadeck/probe/"
ssh "${SSHOPTS[@]}" "$host" 'chmod +x /run/novadeck/probe/sgdisk /run/novadeck/probe/mdir /run/novadeck/probe/select-target.sh'

# --- stage 3: the run ------------------------------------------------------------------------
# Markdown on stdout, per-board sections that concatenate, exactly like probe-internal.sh's
# capture — for the same reason: boards differ, so the document is a set of sections and never a
# single canonical table.
ssh "${SSHOPTS[@]}" "$host" 'bash -s' <<'REMOTE'
set -u
export PATH=/run/novadeck/probe:$PATH
ST=/run/novadeck/probe/select-target.sh

model="$( { tr -d '\0' < /sys/firmware/devicetree/base/model; } 2>/dev/null )"
echo "# select-target hardware run — ${model:-unknown board}"
echo
echo "Generated by \`install/hw-select-target.sh\` — read-only Phase 3 validation."
echo
echo '| | |'
echo '|---|---|'
echo "| Ran | $(date -u '+%Y-%m-%dT%H:%M:%SZ') |"
echo "| Board | \`${model:-?}\` |"
echo "| Kernel | \`$(uname -r)\` |"
echo "| sgdisk | \`$(sgdisk --version 2>&1 | head -1)\` |"
echo "| mdir | \`$(mdir --version 2>&1 | head -1)\` |"
for k in NOVADECK_VARIANT NOVADECK_MODE NOVADECK_VERSION NOVADECK_BUILD NOVADECK_GIT; do
  v="$(sed -n "s/^$k=//p" /etc/novadeck-release 2>/dev/null | head -1 | tr -d '"')"
  [ -n "$v" ] && echo "| $k | \`$v\` |"
done
root_src="$(findmnt -no SOURCE / 2>/dev/null | sed 's/\[.*//')"
boot_disk="$(lsblk -no PKNAME "$root_src" 2>/dev/null | head -1 | awk '{print $1}')"
echo "| Running root | \`${root_src:-?}\` |"
echo "| Boot medium — never a target | \`${boot_disk:-?}\` |"
echo

# The fact no image fixture can produce: sgdisk asks the KERNEL for the logical size, and only on
# a block device. Every offline case runs at 512 whatever the captured board reported.
echo '## Logical / physical sector size per disk'
echo
echo '| Disk | logical | physical | size |'
echo '|---|---|---|---|'
for d in /sys/block/*; do
  n="$(basename "$d")"
  case "$n" in loop*|ram*|zram*|dm-*) continue ;; esac
  printf '| `%s` | %s | %s | %s |\n' "$n" \
    "$(cat "$d/queue/logical_block_size" 2>/dev/null || echo '?')" \
    "$(cat "$d/queue/physical_block_size" 2>/dev/null || echo '?')" \
    "$(lsblk -dno SIZE "/dev/$n" 2>/dev/null | tr -d ' ' || echo '?')"
done
echo

run() {
  echo '```'
  echo "\$ select-target.sh $*"
  out="$(bash "$ST" "$@" 2>&1)"; rc=$?
  printf '%s\n' "$out"
  echo "rc=$rc"
  echo '```'
  echo
}

echo '## The scan — no argument'
echo
echo 'Rules 1, 2 and 9 reach this path and no other: the explicit-target form below cannot pick a'
echo 'disk, so it cannot exercise "never pick when two are eligible" either.'
echo
run

echo '## Every disk, named explicitly'
echo
for n in $(lsblk -dno NAME | grep -Ev '^(loop|ram|zram|dm-)'); do
  echo "### \`/dev/$n\` — $(lsblk -dno SIZE "/dev/$n" | tr -d ' ')"
  echo
  echo "PARTLABELs: \`$(lsblk -no PARTLABEL "/dev/$n" 2>/dev/null | grep -v '^$' | tr '\n' ' ')\`"
  echo
  run "/dev/$n"
done
REMOTE

echo "[novadeck] staged files remain under /run/novadeck/probe (tmpfs); they vanish at reboot" >&2
