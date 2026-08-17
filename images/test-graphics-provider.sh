#!/usr/bin/env bash
# Offline check for the FEX guest graphics provider.
#
#   images/test-graphics-provider.sh
#
# WHY THIS EXISTS. The fstab entry injected by images/assemble-rootfs.sh carries `nofail` on
# purpose: a missing or unmountable x86 guest must cost native x86 Linux games, never a boot. That
# is the right runtime behaviour and the wrong failure mode to leave unguarded -- it means every
# way this can break breaks QUIETLY, on a device with no serial console.
#
# The sharpest edge is drift between two files that have no reason to be edited together:
# packages/fex-rootfs/prebuilt.pin decides where the .ero lands, and assemble-rootfs.sh names that
# path as a mount source. Bump the pin's `dest` alone -- a one-line, entirely reasonable change --
# and the mount silently sources a path that no longer exists. Nothing else in the tree would
# notice, so this asserts the two agree.
#
# ONE MOUNT, since the 2026-08-11 guest. We used to overlay a manifest of our own onto the guest,
# because the 2026-01-08 image shipped none; upstream now ships /graphics_provider.json at the root
# of the image, so mounting the guest at the probed path is the whole mechanism. The manifest is
# therefore no longer a committed file this can read -- it lives inside a 2 GiB pinned artifact
# that is not in the tree. That check moved to assemble-rootfs.sh, where the image IS present, and
# what this file asserts is that the check still exists and still has a tool to run.
#
# Runs on the host with no root, no device and no build.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASSEMBLE="$ROOT/images/assemble-rootfs.sh"
PIN="$ROOT/packages/fex-rootfs/prebuilt.pin"
KCONFIG="$ROOT/kernel/kernel.config"
DOCKERFILE="$ROOT/build/Dockerfile"
OURS="$ROOT/fs-overlay/usr/share/guestos"

MOUNTPOINT=/usr/share/guestos/fex-mesa

PASS=0; FAIL=0
ok()   { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }

for f in "$ASSEMBLE" "$PIN" "$KCONFIG" "$DOCKERFILE"; do
    [[ -f $f ]] || { echo "missing input: $f" >&2; exit 1; }
done

echo "fstab injection"

# 1. The pin's dest IS the mount source. This is the drift guard.
dest=$(sed -n 's/^dest:[[:space:]]*//p' "$PIN" | tr -d '[:space:]')
if [[ -z $dest ]]; then
    bad "could not read 'dest:' from $(basename "$PIN")"
elif grep -qF -- "$dest  $MOUNTPOINT  erofs" "$ASSEMBLE"; then
    ok "mount source matches fex-rootfs pin dest ($dest)"
else
    bad "fstab source does not match pin dest '$dest' -- the guest mount would source a stale path"
fi

# 2. Mounted read-only, and never able to hold up a boot.
grep -q "erofs  loop,ro,nofail" "$ASSEMBLE" \
    && ok "guest image is loop-mounted read-only, nofail" \
    || bad "no read-only nofail loop mount for the guest image"

# 3. The mountpoint has to exist in the read-only image; it cannot be created at runtime.
grep -q "mkdir -p \"\$stage$MOUNTPOINT\"" "$ASSEMBLE" \
    && ok "mountpoint is created in the image" \
    || bad "$MOUNTPOINT is never created -- /usr is read-only at runtime"

# 4. Nothing of ours may sit under the mountpoint. The guest mount covers that directory whole, so
#    a manifest re-added here would be masked at runtime and read as live in the tree -- the exact
#    shape of a config that looks authoritative and does nothing.
if [[ -e $OURS ]]; then
    bad "fs-overlay${OURS#"$ROOT"/fs-overlay} exists -- the guest mount masks it; it cannot take effect"
else
    ok "we ship nothing under the mountpoint (the guest provides the manifest)"
fi

echo
echo "build-time manifest gate"

# 5. The gate that replaced this file's old manifest checks. Without it, a rootfs bump to an image
#    with no graphics_provider.json produces a card that boots fine and cannot launch an x86 title.
if grep -q 'dump.erofs --cat --path=/graphics_provider.json' "$ASSEMBLE"; then
    ok "assemble-rootfs.sh reads the manifest out of the pinned guest"
else
    bad "no build-time check that the guest still ships /graphics_provider.json"
fi

# 6. And the tool that gate needs. dump.erofs lives in the build image only because of this check,
#    so the two are exactly the kind of pair nothing else would keep in step.
if grep -q 'erofs-utils' "$DOCKERFILE"; then
    ok "the build image installs erofs-utils for that gate"
else
    bad "build/Dockerfile has no erofs-utils -- the manifest gate cannot run"
fi

# 7. Parsing the manifest is what proves it, not dump.erofs's exit status: `dump.erofs --path` exits
#    0 for a path that does not exist and only complains on stderr. A gate rewritten to trust the
#    exit code would pass on an image with no manifest at all.
if grep -A12 'dump.erofs --cat --path=/graphics_provider.json' "$ASSEMBLE" | grep -q 'json.load'; then
    ok "the gate parses the manifest rather than trusting an exit code"
else
    bad "the gate does not parse the manifest -- dump.erofs exits 0 on a missing path"
fi

echo
echo "kernel support"

# 8. The mount is impossible without all three. EROFS_FS_ZIP covers LZ4, which is what the pinned
#    image uses (its superblock sets no COMPR_CFGS bit, so LZ4 is the only algorithm in play).
for sym in CONFIG_EROFS_FS CONFIG_BLK_DEV_LOOP CONFIG_EROFS_FS_ZIP; do
    grep -q "^$sym=y" "$KCONFIG" \
        && ok "$sym=y" \
        || bad "$sym is not =y -- the guest cannot be mounted"
done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
