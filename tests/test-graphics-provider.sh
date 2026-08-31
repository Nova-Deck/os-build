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
#   rootfs/overlay .../fex-emu/Config.json  points the system FEX's RootFS at the merged mountpoint
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
FEXCONF="$ROOT/rootfs/overlay/usr/share/fex-emu/Config.json"
OURS="$ROOT/rootfs/overlay/usr/share/guestos"

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

# 2. Guest image mounted read-only, never able to hold up a boot, and torn down AFTER the session.
#    x-systemd.before is not redundant with nofail -- it is there BECAUSE of nofail, which drops
#    the unit's Before=local-fs.target along with the Requires=. Both rows need it (the overlay
#    row is checked whole in 3); without it the mounts are stopped in the first shutdown wave,
#    while the session still holds them: the overlay unmount fails EBUSY, and systemd then takes
#    that failed stop job as complete and unmounts this erofs lower out from under the still-
#    mounted overlay. Measured on HW over three reboots; see the comment in the assembler.
#
#    Guarded because losing it degrades QUIETLY -- the mount still works, the boot still comes up,
#    and the only evidence is two lines in a shutdown log nobody reads.
grep -q "erofs  loop,ro,nofail,noatime,x-systemd.before=local-fs.target" "$ASSEMBLE" \
    && ok "guest image is loop-mounted read-only + nofail, ordered before local-fs.target" \
    || bad "guest image row reshaped -- expected erofs loop,ro,nofail,noatime,x-systemd.before=local-fs.target"

# 3. The overlay row: merged at the probed path, payload as the TOP lower layer, ordered after
#    the guest mount. One grep because the row only works whole -- a reordered lowerdir silently
#    renders on the guest's stock driver, and a missing requires-mounts-for races the lower mount.
if grep -qF "overlay  $MOUNTPOINT  overlay  ro,nofail,lowerdir=$PAYLOAD:$LOWER,x-systemd.requires-mounts-for=$LOWER,x-systemd.before=local-fs.target" "$ASSEMBLE"; then
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
    bad "rootfs/overlay${OURS#"$ROOT"/rootfs/overlay} exists -- the guest mount masks it; it cannot take effect"
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

echo
echo "lsfg-vk frame-generation layer"

LSFG_PIN="$ROOT/packages/lsfg-vk-x86/builder.pin"

# 16. The GUEST payload must not acquire a source.pin or prebuilt.pin: either would change where
#     it lands -- build-overlay.sh would build it as a host package, or customize-base.sh would
#     extract it into the BASE -- instead of staging it into the guest tree. Both are silent
#     misplacements; the x86 layer would simply never be where the guest looks.
#
#     The HOST package is the opposite case and is checked separately below: it MUST have a
#     source.pin, because an aarch64 layer only reaches Proton titles by being a real package in
#     the host rootfs, where pressure-vessel imports implicit layers from.
for wrong in source.pin prebuilt.pin; do
    [ -e "$ROOT/packages/lsfg-vk-x86/$wrong" ] \
        && bad "packages/lsfg-vk-x86/$wrong exists -- that reroutes the guest payload into the base/overlay" \
        || ok "no packages/lsfg-vk-x86/$wrong (the payload is staged into the guest, not the base)"
done

# 16b. The two halves cover different Vulkan stacks and neither substitutes for the other: the x86
#      layer serves system FEX and native x86-64 Linux titles (guest Turnip), the aarch64 one
#      serves Proton titles (host driver, imported by pressure-vessel). Losing either silently
#      halves the feature's coverage, which is invisible until someone tries the wrong kind of game.
[ -e "$ROOT/packages/lsfg-vk/source.pin" ] && [ -e "$ROOT/packages/lsfg-vk/PKGBUILD" ] \
    && ok "the host aarch64 layer is a source-built overlay package (what Proton titles need)" \
    || bad "packages/lsfg-vk has no source.pin+PKGBUILD -- Proton titles would get no frame generation"

# 16b-2. A package that is built but never installed is the quietest failure of the lot: the
#        overlay repo carries it, nothing complains, and Proton titles just get no frame
#        generation. It has to be named in customize-base.sh's PKGS.
grep -qE '^PKGS=\(.*[( ]lsfg-vk[ )]' "$ROOT/rootfs/customize-base.sh" \
    && ok "lsfg-vk is in the base package list (built AND installed)" \
    || bad "lsfg-vk is not in customize-base.sh PKGS -- it would build and never ship"

# 16c. CC-BY-NC-ND forbids shipping a modified build. A patches line here would do exactly that,
#      and unlike most licence risks it would be introduced by someone trying to FIX something.
grep -q '^patches:' "$ROOT/packages/lsfg-vk/source.pin" \
    && bad "packages/lsfg-vk/source.pin declares patches -- NoDerivatives forbids shipping a modified lsfg-vk" \
    || ok "the host lsfg-vk build carries no patches (NoDerivatives)"

# 17. ONE upstream version for both arches. The x86 build reads its tag from the HOST package's
#     PKGBUILD rather than carrying its own, so the aarch64 layer and the x86 layer cannot drift to
#     different releases -- which would be invisible until a user with one kind of game saw
#     different behaviour from a user with the other.
grep -q 'packages/lsfg-vk/PKGBUILD' "$ROOT/packages/lsfg-vk-x86/build.sh" \
    && ok "the x86 build takes its upstream tag from the host PKGBUILD (the arches cannot drift)" \
    || bad "packages/lsfg-vk-x86 pins its own version -- the two arches can drift apart"

# 17b. The layer loads INSIDE the FEX guest, so its glibc ceiling is not a detail: a symbol above
#      what the guest ships loads fine in the build container and fails on device, where the only
#      symptom is that frame generation quietly does nothing.
grep -q 'fex-rootfs/prebuilt.pin' "$ROOT/packages/lsfg-vk-x86/build.sh" \
    && ok "the x86 build asserts its snapshot against the fex-rootfs pin (glibc ceiling)" \
    || bad "packages/lsfg-vk-x86 does not gate its snapshot against the guest rootfs pin"

# 17c. NoDerivatives again, on the other half. Same reasoning as the host package.
grep -qE '^\s*(patch|git apply)' "$ROOT/packages/lsfg-vk-x86/container-build.sh" \
    && bad "packages/lsfg-vk-x86 patches the source -- NoDerivatives forbids shipping a modified lsfg-vk" \
    || ok "the x86 lsfg-vk build applies no patches (NoDerivatives)"

# 18. Every artifact fetch.sh promises must be one the assembler requires, and vice versa. These
#     two lists live in different files and have no reason to be edited together, which is the
#     drift this whole suite exists to catch.
for f in usr/lib/liblsfg-vk-layer.so usr/lib/liblsfg-vk-layer.x86.so usr/bin/lsfg-vk-cli \
         usr/share/vulkan/implicit_layer.d/VkLayer_LSFGVK_frame_generation.json \
         usr/share/vulkan/implicit_layer.d/VkLayer_LSFGVK_frame_generation.x86.json; do
    if grep -q "$f" "$ROOT/packages/lsfg-vk-x86/container-build.sh" && grep -q "$f" "$ASSEMBLE"; then
        ok "$f is promised by fetch.sh and required by the assembler"
    else
        bad "$f is not in both fetch.sh and the assembler -- one of them will ship a hole"
    fi
done

# 19. The i686 layer goes in usr/lib, NOT usr/lib32, because upstream's manifest resolves
#     ../../../lib/ relative to itself and CC-BY-NC-ND says we do not rewrite their manifest.
#     "Fixing" this to match our lib32 convention breaks the layer silently.
grep -q 'usr/lib/liblsfg-vk-layer\.x86\.so' "$ROOT/packages/lsfg-vk-x86/container-build.sh" \
    && ok "the i686 layer stays in usr/lib (upstream's relative library_path resolves there)" \
    || bad "the i686 layer is not staged to usr/lib -- the manifest's relative path will not resolve"

# 20. ...which is only safe because the NEEDED gate picks its comparison libdir by ELF class. If
#     that reverts to picking by directory, a 32-bit ELF in usr/lib gets judged against the
#     guest's 64-bit libdir and the gate is right only by luck.
grep -q 'Class:\[\[:space:\]\]\*ELF' "$ASSEMBLE" \
    && ok "the NEEDED gate selects its libdir by ELF class, not by directory" \
    || bad "the NEEDED gate no longer reads ELF class -- a 32-bit .so in usr/lib is checked wrongly"

# 21. Both manifests must keep a manifest-relative library_path. An absolute one resolves against
#     the container's /usr under Valve's /run/gfx republish and the loader drops the layer with no
#     error at all -- indistinguishable from "the user did not turn frame generation on".
grep -q '"library_path": "' "$ASSEMBLE" \
    && ok "the assembler re-asserts the manifest-relative library_path on the staged copy" \
    || bad "nothing checks library_path at stage time -- an absolute path drops the layer silently"

SESSION="$ROOT/rootfs/overlay/usr/bin/novadeck-session"
LAUNCH="$ROOT/rootfs/overlay/usr/lib/novadeck/game-launch"

# 22. The payload and the off-switch are two halves of ONE mechanism, and shipping the first
#     without the second is not a cosmetic gap. lsfg-vk is an IMPLICIT layer, so the loader pulls
#     it into every x86 Vulkan process; and its constructor calls getOrDefault(), which WRITES a
#     default ~/.config/lsfg-vk/conf.toml when none exists. Without this export the first game a
#     user launches drops a config file in their home for a feature they never enabled.
if grep -q '^export DISABLE_LSFGVK$' "$SESSION" && grep -q '{DISABLE_LSFGVK=1}' "$SESSION"; then
    ok "the session defaults DISABLE_LSFGVK=1 and exports it"
else
    bad "novadeck-session does not export DISABLE_LSFGVK=1 -- the layer loads into every x86 Vulkan app"
fi

# 23. `${VAR=1}` (no colon) assigns only when UNSET, so session.conf can set it EMPTY and have that
#     respected. A colon form would silently re-default an empty override and remove the bring-up
#     lever -- the device has to stay operator-reachable.
grep -q ': "${DISABLE_LSFGVK=1}"' "$SESSION" \
    && ok "DISABLE_LSFGVK honours an empty session.conf override (\${VAR=} not \${VAR:=})" \
    || bad "DISABLE_LSFGVK uses a colon default -- an empty session.conf override is silently ignored"

# 24. The per-game opt-in is a TOMBSTONE, not a second variable: game-tweaks.json carries
#     "env": {"DISABLE_LSFGVK": null} and game-launch unsets rather than setting empty. An empty
#     string would NOT disable the layer's disable_environment check -- the layer treats any
#     non-empty value as "off", and "" as unset -- but relying on that is a coin flip, so the
#     tombstone path is what has to keep working.
if grep -q 'if value is None' "$LAUNCH" && grep -q 'os.environ.pop' "$LAUNCH"; then
    ok "game-launch still unsets on a null env tombstone (the per-game opt-in path)"
else
    bad "game-launch no longer treats a null env value as a tombstone -- per-game frame gen cannot turn on"
fi

# 25. `framegen` and `enabled` are SEPARATE opt-ins. They shared `enabled` once, so switching
#     frame generation on announced per-game tuning the user never asked for. The two failure
#     modes are mirror images and both are silent, so assert the shape rather than the wording:
#     a framegen-only entry must contribute its env, and must NOT pull in the tuning keys.
if grep -q 'game.get("framegen") is True' "$LAUNCH"; then
    ok "game-launch honours a framegen-only entry (frame gen no longer needs the tuning flag)"
else
    bad "game-launch reads only 'enabled' -- frame generation would have to claim per-game tuning to work"
fi

# The framegen branch must merge ONLY env. A settings.update(game) there would hand a
# framegen-only game the cores/scheduler it never enabled -- the same conflation, reversed.
if awk '/elif game.get\("framegen"\) is True:/,/^    return settings/' "$LAUNCH" | grep -q 'settings.update(game)'; then
    bad "the framegen branch merges the whole entry -- it would apply tuning the user never enabled"
else
    ok "the framegen branch contributes env only, never the tuning keys"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]