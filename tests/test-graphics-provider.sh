#!/usr/bin/env bash
# Offline check for the FEX guest graphics provider + the mesa-x86 Turnip overlay.
#
#   tests/test-graphics-provider.sh
#
# WHY THIS EXISTS. The fstab rows injected by rootfs/assemble-rootfs.sh carry `nofail` on
# purpose: a missing or unmountable x86 guest must cost native x86 Linux games, never a boot. That
# is the right runtime behaviour and the wrong failure mode to leave unguarded -- it means every
# way this can break breaks QUIETLY, on a device with no serial console.
#
# The sharpest edges are drift between files that have no reason to be edited together:
#
#   packages/fex-rootfs/prebuilt.pin  decides where the .ero lands; the assembler names that path
#                                     as the lower mount's source.
#   packages/mesa-x86/builder.pin     pins the payload build's snapshot to the SAME guest date;
#                                     build.sh asserts it at build time, this asserts it offline.
#   fs-overlay .../fex-emu/Config.json  points the system FEX's RootFS at the merged mountpoint
#                                     the assembler injects -- two files, one path.
#   the assembler's payload staging   names the dir the overlay row lists as its top lowerdir.
#
# Bump any one of those alone -- each a one-line, entirely reasonable change -- and an x86 title
# silently renders on the wrong driver or stops launching. Nothing else in the tree would notice.
#
# TWO mounts, since the mesa-x86 payload landed: the pinned guest image loop-mounts as a lower
# layer under /run, and an overlayfs lays the payload (our Turnip, built from the host mesa's
# source pin + patches) over it at the path Valve's FEX compat tool probes. The system FEX reads
# the same merged tree. The guest's manifest lives inside a 2 GiB pinned artifact that is not in
# the tree, so the content checks moved to assemble-rootfs.sh, where the image IS present; what
# this file asserts is that those gates still exist and still have a tool to run.
#
# Runs on the host with no root, no device and no build.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASSEMBLE="$ROOT/rootfs/assemble-rootfs.sh"
PIN="$ROOT/packages/fex-rootfs/prebuilt.pin"
BUILDER_PIN="$ROOT/packages/mesa-x86/builder.pin"
BUILD_SH="$ROOT/packages/mesa-x86/build.sh"
KCONFIG="$ROOT/kernel/kernel.config"
DOCKERFILE="$ROOT/build/Dockerfile"
MAKEFILE="$ROOT/Makefile"
FEXCONF="$ROOT/fs-overlay/usr/share/fex-emu/Config.json"
OURS="$ROOT/fs-overlay/usr/share/guestos"

MOUNTPOINT=/usr/share/guestos/fex-mesa
LOWER=/run/novadeck/guestos-lower
PAYLOAD=/usr/share/novadeck/guestos-x86-mesa

PASS=0; FAIL=0
ok()   { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }

for f in "$ASSEMBLE" "$PIN" "$BUILDER_PIN" "$BUILD_SH" "$KCONFIG" "$DOCKERFILE" "$MAKEFILE" "$FEXCONF"; do
    [[ -f $f ]] || { echo "missing input: $f" >&2; exit 1; }
done

pin_field() { sed -n "s/^$2:[[:space:]]*//p" "$1" | head -1; }

echo "fstab injection"

# 1. The pin's dest IS the lower mount's source. This is the original drift guard.
dest=$(pin_field "$PIN" dest | tr -d '[:space:]')
if [[ -z $dest ]]; then
    bad "could not read 'dest:' from $(basename "$PIN")"
elif grep -qF -- "$dest  $LOWER  erofs" "$ASSEMBLE"; then
    ok "lower mount source matches fex-rootfs pin dest ($dest)"
else
    bad "lower mount source does not match pin dest '$dest' -- the guest mount would source a stale path"
fi

# 2. Guest image mounted read-only, and never able to hold up a boot.
grep -q "erofs  loop,ro,nofail" "$ASSEMBLE" \
    && ok "guest image is loop-mounted read-only, nofail" \
    || bad "no read-only nofail loop mount for the guest image"

# 3. The overlay row: merged at the probed path, payload as the TOP lower layer, ordered after
#    the guest mount. One grep because the row only works whole -- a reordered lowerdir silently
#    renders on the guest's stock driver, and a missing requires-mounts-for races the lower mount.
if grep -qF "overlay  $MOUNTPOINT  overlay  ro,nofail,lowerdir=$PAYLOAD:$LOWER,x-systemd.requires-mounts-for=$LOWER" "$ASSEMBLE"; then
    ok "overlay row merges payload over guest at $MOUNTPOINT, ordered after the lower mount"
else
    bad "overlay fstab row missing or reshaped -- expected lowerdir=$PAYLOAD:$LOWER at $MOUNTPOINT"
fi

# 4. The merged mountpoint has to exist in the read-only image; it cannot be created at runtime.
#    ($LOWER lives under /run, which systemd creates mountpoints in by itself.)
grep -q "mkdir -p \"\$stage$MOUNTPOINT\"" "$ASSEMBLE" \
    && ok "mountpoint is created in the image" \
    || bad "$MOUNTPOINT is never created -- /usr is read-only at runtime"

# 5. Nothing of ours may sit under the mountpoint. The overlay covers that directory whole, so
#    a file re-added here would be masked at runtime and read as live in the tree -- the exact
#    shape of a config that looks authoritative and does nothing.
if [[ -e $OURS ]]; then
    bad "fs-overlay${OURS#"$ROOT"/fs-overlay} exists -- the guest mount masks it; it cannot take effect"
else
    ok "we ship nothing under the mountpoint (the merged mount provides everything)"
fi

echo
echo "mesa-x86 payload"

# 6. The assembler stages the payload at the exact dir the overlay row lists first. These are two
#    strings in one file today, but the row is data the image carries and the staging is code --
#    they drift independently the day someone renames one.
grep -q "payload_dest=\"${PAYLOAD#/}\"" "$ASSEMBLE" \
    && ok "payload staged at $PAYLOAD (matches the overlay row's top lowerdir)" \
    || bad "assembler does not stage the payload at $PAYLOAD"

# 7. The payload is REQUIRED at assembly -- both driver arches, both ICDs, the keysyms pair. A
#    half-staged payload shadowing one arch is the quiet failure this whole stage exists against.
if grep -q 'mesa-x86 payload incomplete' "$ASSEMBLE" \
   && grep -q 'usr/lib32/libvulkan_freedreno.so' "$ASSEMBLE" \
   && grep -q 'usr/lib32/libxcb-keysyms.so.1' "$ASSEMBLE"; then
    ok "assembler hard-requires the complete payload"
else
    bad "assembler does not hard-require the complete mesa-x86 payload"
fi

# 8. And the build feeding it is ordered in: the rootfs rule must depend on the mesa-x86 stamp,
#    or a fresh checkout hits the assembler's hard require instead of building the payload.
grep -qE '^\$\(ROOTFS\):.*\$\(MESA_X86_STAMP\)' "$MAKEFILE" \
    && ok "Makefile orders mesa-x86 before the rootfs assembly" \
    || bad "\$(ROOTFS) does not depend on \$(MESA_X86_STAMP) -- assembly would fail on a fresh tree"

# 9. The NEEDED-closure gate: every payload .so must resolve inside the merged guest. Without it
#    pressure-vessel drops an ICD with an unresolvable dep SILENTLY.
grep -q 'readelf -d' "$ASSEMBLE" \
    && ok "assembler checks the payload's NEEDED closure against the guest" \
    || bad "no NEEDED-closure gate -- an unresolvable payload dep would be found by a player"

# 10. Snapshot pairing, asserted offline as well as at build time: the payload's toolchain
#     snapshot must be the guest's date, or the driver links against the wrong glibc generation.
snap=$(pin_field "$BUILDER_PIN" snapshot); ver=$(pin_field "$PIN" version)
if [[ -n $snap && -n $ver && $snap == "${ver//-//}" ]]; then
    ok "mesa-x86 snapshot ($snap) matches the fex-rootfs pin ($ver)"
else
    bad "mesa-x86 snapshot '$snap' does not match fex-rootfs version '$ver' -- bump the pins together"
fi

echo
echo "system FEX shares the merged tree"

# 11. Config.json's RootFS and the assembler's mountpoint are one path in two files.
rootfs_path=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["Config"].get("RootFS",""))' "$FEXCONF" 2>/dev/null)
if [[ $rootfs_path == "$MOUNTPOINT" ]]; then
    ok "system FEX RootFS points at the merged mount ($MOUNTPOINT)"
else
    bad "Config.json RootFS is '$rootfs_path', not $MOUNTPOINT -- system FEX would miss the payload driver"
fi

echo
echo "build-time manifest gate"

# 12. The gate that replaced this file's old manifest checks. Without it, a rootfs bump to an
#     image with no graphics_provider.json produces a card that boots fine and cannot launch an
#     x86 title.
if grep -q 'dump.erofs --cat --path=/graphics_provider.json' "$ASSEMBLE"; then
    ok "assemble-rootfs.sh reads the manifest out of the pinned guest"
else
    bad "no build-time check that the guest still ships /graphics_provider.json"
fi

# 13. And the tool that gate needs. dump.erofs lives in the build image only because of these
#     checks, so the two are exactly the kind of pair nothing else would keep in step.
if grep -q 'erofs-utils' "$DOCKERFILE"; then
    ok "the build image installs erofs-utils for that gate"
else
    bad "build/Dockerfile has no erofs-utils -- the manifest gate cannot run"
fi

# 14. Parsing the manifest is what proves it, not dump.erofs's exit status: `dump.erofs --path`
#     exits 0 for a path that does not exist and only complains on stderr. A gate rewritten to
#     trust the exit code would pass on an image with no manifest at all.
if grep -A12 'dump.erofs --cat --path=/graphics_provider.json' "$ASSEMBLE" | grep -q 'json.load'; then
    ok "the gate parses the manifest rather than trusting an exit code"
else
    bad "the gate does not parse the manifest -- dump.erofs exits 0 on a missing path"
fi

echo
echo "kernel support"

# 15. The mounts are impossible without all four. EROFS_FS_ZIP covers LZ4, which is what the
#     pinned image uses (its superblock sets no COMPR_CFGS bit, so LZ4 is the only algorithm in
#     play); OVERLAY_FS is the merge itself.
for sym in CONFIG_EROFS_FS CONFIG_BLK_DEV_LOOP CONFIG_EROFS_FS_ZIP CONFIG_OVERLAY_FS; do
    grep -q "^$sym=y" "$KCONFIG" \
        && ok "$sym=y" \
        || bad "$sym is not =y -- the guest cannot be mounted"
done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]