#!/usr/bin/env bash
# Offline check for the Android guest's /usr/share/guestos/android slot + the mesa-android payload.
#
#   tests/test-android-guestos.sh
#
# WHY THIS EXISTS. Nothing on the device tells you this slot is wrong. Valve's Lepton compat tool
# (Steam app 3029110) reads it with a bare `find . -type f` and bind-mounts whatever it finds at
# the matching absolute path inside Android; a file staged one directory off is not an error, it
# is a file the guest never looks at. And the consequence of the guest not finding a driver is
# that libEGL aborts and takes surfaceflinger with it -- so the process that would have logged
# the problem is the one that dies. Issue #58 cost two hardware sessions to that shape.
#
# The sharp edges are all drift between files with no reason to be edited together:
#
#   liblepton/properties.sh's defaults   decide the FILENAMES Android's loader opens
#                                        (libEGL_${ro.hardware.egl}.so, hw/vulkan.${...}.so).
#   packages/mesa-android/container-build.sh  installs to those filenames, and bakes the gbm
#                                        backends path that must be the vendor libdir.
#   rootfs/assemble-rootfs.sh            stages the tree into the slot Lepton walks.
#   packages/mesa/source.pin             is the source of truth all three mesa builds share.
#
# What this file CANNOT check is the payload itself: work/mesa-android/out is a build output, not
# a committed file, so the content gates live in container-build.sh where the objects exist. What
# is asserted here is that those gates still exist, and that the paths on both sides still agree.
#
# Runs on the host with no root, no device and no build.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASSEMBLE="$ROOT/rootfs/assemble-rootfs.sh"
BUILDER_PIN="$ROOT/packages/mesa-android/builder.pin"
BUILD_SH="$ROOT/packages/mesa-android/build.sh"
CONTAINER_SH="$ROOT/packages/mesa-android/container-build.sh"
MESA_PIN="$ROOT/packages/mesa/source.pin"
MAKEFILE="$ROOT/Makefile"
KCONFIG="$ROOT/kernel/kernel.config"

SLOT=usr/share/guestos/android
VENDOR_LIB=vendor/lib64

PASS=0; FAIL=0
ok()  { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }

for f in "$ASSEMBLE" "$BUILDER_PIN" "$BUILD_SH" "$CONTAINER_SH" "$MESA_PIN" "$MAKEFILE" "$KCONFIG"; do
    [[ -f $f ]] || { echo "missing input: $f" >&2; exit 1; }
done

pin_field() { sed -n "s/^$2:[[:space:]]*//p" "$1" | head -1; }

echo "the slot Lepton walks"

# 1. The directory itself. mounting.sh `pushd`es it under `set -e`, so an ABSENT directory kills
#    the launch before any container is built -- measured on a Pocket ACE, issue #58. /usr is
#    read-only at runtime, so it cannot be created later.
grep -q "mkdir -p \"\$stage/\$android_slot\"" "$ASSEMBLE" \
    && ok "the slot directory is created in the image" \
    || bad "/$SLOT is never created -- Lepton's pushd would abort every launch"

# 2. The slot path is the one Lepton hardcodes. There is no configuration for this on either
#    side; it is a literal in liblepton/mounting.sh and a literal here.
grep -q "android_slot=\"$SLOT\"" "$ASSEMBLE" \
    && ok "slot staged at /$SLOT (the path liblepton/mounting.sh walks)" \
    || bad "assembler does not stage the slot at /$SLOT"

# 3. Relative layout. Lepton mounts each file at "/${path-relative-to-the-slot}", so the payload
#    has to be rooted at vendor/, not usr/ and not an extra directory level. This is the failure
#    that produces no message at all: the files are there, the guest never sees them.
grep -q 'cp -a "\$android_payload/vendor" "\$stage/\$android_slot/"' "$ASSEMBLE" \
    && ok "payload is staged rooted at vendor/ (so files land at /vendor/... in the guest)" \
    || bad "payload is not staged as \$slot/vendor -- the bind-mount targets would be wrong"

echo
echo "the filenames Android's loader opens"

# 4-6. Android's EGL and Vulkan loaders match on FILENAME, not soname: libEGL_${ro.hardware.egl}.so
#      and hw/vulkan.${ro.hardware.vulkan}.so. properties.sh defaults those to `mesa` and
#      `freedreno`, so these exact names are the contract. Both sides must name them: the build
#      installs them, the assembler requires them.
for f in "$VENDOR_LIB/egl/libEGL_mesa.so" \
         "$VENDOR_LIB/egl/libGLESv2_mesa.so" \
         "$VENDOR_LIB/egl/libGLESv1_CM_mesa.so" \
         "$VENDOR_LIB/hw/vulkan.freedreno.so"; do
    if grep -qF "$f" "$CONTAINER_SH" && grep -qF "$f" "$ASSEMBLE"; then
        ok "$f is built and hard-required at assembly"
    else
        bad "$f is missing from container-build.sh or assemble-rootfs.sh -- the guest's loader opens it by this exact name"
    fi
done

# 7. The gallium/gbm libraries the trio above pulls in. Less visible than the loader-facing names
#    and just as fatal: without libgallium_dri.so there is no GL driver behind libEGL_mesa, and
#    without the gbm pair gralloc cannot initialise.
for f in "$VENDOR_LIB/libgallium_dri.so" "$VENDOR_LIB/libgbm_mesa.so" "$VENDOR_LIB/dri_gbm.so"; do
    if grep -qF "$f" "$CONTAINER_SH" && grep -qF "$f" "$ASSEMBLE"; then
        ok "$f is built and hard-required at assembly"
    else
        bad "$f is missing from container-build.sh or assemble-rootfs.sh"
    fi
done

# 8. And the require is a hard one. A half-staged driver set is the quiet failure the whole stage
#    exists against -- the same reasoning as the mesa-x86 payload's gate.
grep -q 'mesa-android payload incomplete' "$ASSEMBLE" \
    && ok "assembler hard-requires the complete payload" \
    || bad "assembler does not hard-require the mesa-android payload"

echo
echo "the driver-selection init script"

# Lepton forces mesa.loader.driver.override=zink, which cannot create a DRI2 screen with our build:
# SurfaceFlinger aborts and the guest dies ~4s in, surfacing as an APK install that fails with
# "adb: device offline" -- nowhere near the cause. The .rc that overrides it back to freedreno is
# the difference between a rendering guest and a dead one, and it arrives from rootfs/overlay rather
# than the mesa build, so nothing in packages/ would notice if it vanished.
RC="$ROOT/rootfs/overlay/$SLOT/vendor/etc/init/novadeck-gfx.rc"
if [[ -s $RC ]]; then
    ok "rootfs/overlay ships vendor/etc/init/novadeck-gfx.rc"
else
    bad "no novadeck-gfx.rc in rootfs/overlay -- the guest would run on zink and die 4s into boot"
fi
grep -q 'setprop mesa.loader.driver.override msm' "$RC" 2>/dev/null \
    && ok "it overrides the mesa loader onto freedreno (msm)" \
    || bad "novadeck-gfx.rc does not setprop mesa.loader.driver.override msm"

# Android init only parses this from a path Lepton will bind-mount, i.e. under the slot.
case "$RC" in
    */rootfs/overlay/"$SLOT"/vendor/etc/init/*.rc) ok "it sits under the slot, so Lepton mounts it at /vendor/etc/init/" ;;
    *) bad "the .rc is not under $SLOT/vendor/etc/init -- Android init would never see it" ;;
esac

# The assembler merges rootfs/overlay and the mesa payload into one tree. If that merge ever becomes a
# clobber, the .rc disappears silently -- so the assembler has to check it survived.
grep -q 'rootfs/overlay.s copy was clobbered by the payload merge' "$ASSEMBLE" \
    && ok "assembler verifies the .rc survived the payload merge" \
    || bad "no build-time check that the .rc is still in the staged slot"

echo
echo "the logcat capture (dev cards only)"

# A debugging instrument, not a feature: it writes continuously to the SD card for the life of
# every Android title. The whole reason it lives in rootfs/guestos/ instead of rootfs/overlay/ is that
# rootfs/overlay is copied into EVERY image unconditionally -- there is no gate to be had there, so a
# copy in that tree ships to users. These three checks are what keep it out of a release image.
LOGRC="$ROOT/rootfs/guestos/novadeck-logcat.rc"
if [[ -s $LOGRC ]]; then
    ok "rootfs/guestos ships novadeck-logcat.rc"

    [[ ! -e $ROOT/rootfs/overlay/$SLOT/vendor/etc/init/novadeck-logcat.rc ]] \
        && ok "it is NOT in rootfs/overlay, where it would ship in release" \
        || bad "novadeck-logcat.rc is in rootfs/overlay -- that tree is unconditional, so it would ship to users"

    # The staging must be inside a NOVADECK_DEV branch. Checking that the filename appears is not
    # enough: an unguarded install line would match that and ship the file anyway.
    awk '/NOVADECK_DEV/ { dev = NR }
         /rootfs\/guestos\/novadeck-logcat\.(rc|sh)/ { if (dev && NR - dev < 14) found++ }
         END { exit !(found >= 2) }' "$ASSEMBLE" \
        && ok "the assembler stages it only under NOVADECK_DEV=1 (both files)" \
        || bad "novadeck-logcat.{rc,sh} is not staged behind a NOVADECK_DEV gate -- it would ship in release images"

    # The .rc execs a script from the slot's vendor/bin. Two files that must agree on one path,
    # with the failure being a service that never starts and a capture that is simply absent.
    LOGSH="$ROOT/rootfs/guestos/novadeck-logcat.sh"
    [[ -s $LOGSH ]] \
        && ok "rootfs/guestos ships the novadeck-logcat.sh writer" \
        || bad "novadeck-logcat.sh is missing -- the service would exec a script that is not there"
    grep -qF '/vendor/bin/novadeck-logcat.sh' "$LOGRC" \
        && ok "the .rc execs the script at its bind-mounted slot path" \
        || bad "the .rc does not reference /vendor/bin/novadeck-logcat.sh"

    # Lepton deletes compatdata/<appid>/baked/ -- and data_overlay inside it -- on an early app
    # exit, which destroyed one capture between the run and reading it. Only external/ (the guest's
    # /data/media/0) and internal/ survive that. Writing anywhere else under /data looks durable
    # and is not.
    grep -qF '/data/media/0' "$LOGSH" \
        && ok "the capture writes to /data/media/0, which survives Lepton's baked/ clear" \
        || bad "the capture does not write to /data/media/0 -- Lepton's cleanup deletes anything else under /data"
    # Comments in this file discuss the paths it must NOT use, so strip them before looking.
    sed 's/#.*//' "$LOGSH" | grep -qE '/data/local|/data/novadeck' \
        && bad "the capture still writes under /data/local or /data/novadeck -- both are inside baked/ and get deleted" \
        || ok "it writes nowhere that Lepton's cleanup removes"

    # A shell read loop cannot keep pace with boot spew: unfiltered, it captured 2s of a 90s run.
    # The filter is what makes the durable stream viable, so its absence is a real regression.
    grep -qF '*:S' "$LOGSH" \
        && ok "the line-durable stream is tag-filtered, so it can keep up" \
        || bad "the durable stream is unfiltered -- the shell loop falls behind and loses everything after boot"
fi

echo
echo "the freeform windowing shadow"

# Lepton's rootfs declares android.software.freeform_window_management unconditionally, with none of
# stock waydroid's gating on persist.waydroid.multi_windows. Declared-but-single-window is the state
# that puts the title in a floating 824x464 window on the launcher wallpaper instead of filling the
# screen. We shadow the declaration with an empty one at the same path; there is no runtime override
# (the feature is ORed with the developer setting, and --windowingMode does not stick).
FREEFORM_XML=android.software.freeform_window_management.xml
FFSRC="$ROOT/rootfs/guestos/$FREEFORM_XML"

[[ -s $FFSRC ]] \
    && ok "rootfs/guestos ships $FREEFORM_XML" \
    || bad "$FREEFORM_XML is missing -- the guest keeps Valve's declaration and titles open freeform"

# The whole point is that it declares NOTHING. A copy of Valve's file, or any <feature> line, would
# stage cleanly, bind-mount cleanly, and change nothing at all.
if [[ -s $FFSRC ]]; then
    grep -q '<permissions' "$FFSRC" \
        && ok "it is a well-formed <permissions> document" \
        || bad "$FREEFORM_XML has no <permissions> element -- PackageManager would not parse it"
    sed 's/<!--.*-->//' "$FFSRC" | grep -q '<feature' \
        && bad "$FREEFORM_XML still declares a <feature> -- shadowing it with a declaration is a no-op" \
        || ok "it declares no feature, which is what takes freeform away"
fi

# Path has to be exact: Lepton walks the slot with a bare `find . -type f` and bind-mounts each file
# at the matching absolute path, so one directory off is a file the guest never opens.
grep -qF "\$android_slot/system/etc/permissions/$FREEFORM_XML" "$ASSEMBLE" \
    && ok "the assembler stages it at system/etc/permissions/ inside the slot" \
    || bad "the assembler does not stage $FREEFORM_XML at /$SLOT/system/etc/permissions/"

# Unlike the logcat instrument, this one must NOT be dev-gated -- every image wants it.
# Only a real `if [ NOVADECK_DEV ]` counts as a gate. The comment above the install line names
# NOVADECK_DEV to say it is deliberately NOT gated, so prose has to be skipped or it reads as one.
awk -v xml="$FREEFORM_XML" '
    /NOVADECK_DEV/ && $0 !~ /^[[:space:]]*#/ { dev = NR }
    index($0, xml) && dev && NR - dev < 14 { found++ }
    END { exit(found ? 0 : 1) }' "$ASSEMBLE" \
    && bad "$FREEFORM_XML is staged behind a NOVADECK_DEV gate -- release images would keep freeform" \
    || ok "it is staged unconditionally, not only on dev cards"

echo
echo "build recipe"

# 9. ZINK. Lepton sets mesa.loader.driver.override=zink alongside ro.hardware.egl=mesa, so GLES in
#    the guest is zink-over-Turnip. A libgallium_dri.so built without zink loads and then cannot
#    find the overridden driver -- indistinguishable from shipping nothing.
grep -q 'gallium-drivers=freedreno,zink' "$CONTAINER_SH" \
    && ok "gallium build includes zink (Lepton overrides the loader to it)" \
    || bad "zink is not in -Dgallium-drivers -- mesa.loader.driver.override=zink would find nothing"
if grep -q 'libzink.a' "$CONTAINER_SH" && grep -q "grep -cx 'zink'" "$CONTAINER_SH"; then
    ok "build gates that zink compiled AND that its loader-table name is in the shipped megadriver"
else
    bad "no post-build check that zink is present in libgallium_dri.so"
fi

# 9b. And that check must not be a `grep -q` pipeline. container-build.sh runs under `set -o
#     pipefail`; grep -q closes the pipe on its first match, `strings` on a 26 MB object dies of
#     SIGPIPE, and pipefail turns that into a FAILURE THAT FIRES EXACTLY WHEN THE STRING IS THERE.
#     It cost a build, and its error message said the opposite of what was true.
if grep -qE '(strings|readelf)[^|]*\| *grep -q' "$CONTAINER_SH"; then
    bad "a gate pipes into 'grep -q' under pipefail -- it will fail when it MATCHES (SIGPIPE -> 141)"
else
    ok "no gate pipes a long stream into 'grep -q' (the pipefail/SIGPIPE trap)"
fi

# 10. The gbm backends path is baked in at build time and its default (/usr/local/lib/gbm) does
#     not exist in Android. It has to name the vendor libdir the payload is mounted at.
grep -q "gbm-backends-path=/$VENDOR_LIB" "$CONTAINER_SH" \
    && ok "gbm backends path is baked to /$VENDOR_LIB" \
    || bad "gbm-backends-path does not match the vendor libdir -- gralloc would fail to init"

# 11. BIONIC, NOT GLIBC -- the entire reason this package exists separately from packages/mesa.
#     A payload that links glibc cannot load in an Android process at all.
grep -q 'it cannot load in the bionic guest' "$CONTAINER_SH" \
    && ok "build gates the payload against linking glibc" \
    || bad "no gate that the payload is bionic-linked -- a glibc build would load nowhere"

# 12. NEEDED closure, same class of gate as the mesa-x86 payload's: an unresolvable DT_NEEDED is
#     not reported usefully by Android's linker, it is a driver that silently never loads.
grep -q 'nor shipped in the payload' "$CONTAINER_SH" \
    && ok "build checks the payload's NEEDED closure against the NDK sysroot" \
    || bad "no NEEDED-closure gate for the Android payload"

# 13. ONE mesa source for all three drivers. The host driver, the FEX guest's and this one are
#     built from the same tarball and the same patch list; the day they diverge is the day a bug
#     is fixed on one Adreno path and not the others.
if grep -q 'packages/mesa/PKGBUILD' "$CONTAINER_SH" && grep -q 'packages/mesa/patches' "$CONTAINER_SH"; then
    ok "source + patches come from packages/mesa (no separate pin to keep in step)"
else
    bad "mesa-android does not read packages/mesa's source and patch list -- the drivers can drift"
fi
if grep -q 'source.pin' "$BUILD_SH"; then
    ok "patch list is read from packages/mesa/source.pin, in declared order"
else
    bad "build.sh does not read the patch list from source.pin"
fi

echo
echo "API level"

# 14. The one number in builder.pin that is not a free choice. Bionic resolves the NDK's versioned
#     symbols at load time, so a driver built above the guest's own SDK level can reference
#     symbols its libc does not export -- which surfaces as the same silent no-GLES abort this
#     whole payload exists to fix. MEASURED over adb on the Lepton guest: SDK 30 / Android 11.
api=$(pin_field "$BUILDER_PIN" android_api)
if [[ $api =~ ^[0-9]+$ ]] && (( api <= 30 )); then
    ok "android_api is $api (at or below the guest's measured SDK 30)"
else
    bad "android_api is '$api' -- the Lepton guest is SDK 30; a higher target can reference symbols its bionic does not export"
fi

# 15. And the API level reaches the COMPILER TRIPLE, not just the meson option. That is what makes
#     the toolchain turn an out-of-range symbol into a link error here instead of a load failure
#     on the device.
grep -q 'aarch64-linux-android${ANDROID_API}-clang' "$CONTAINER_SH" \
    && ok "the API level is part of the clang target triple" \
    || bad "clang is not invoked as aarch64-linux-android\${ANDROID_API} -- bionic symbol availability would go unchecked"

echo
echo "build ordering"

# 16. The rootfs rule must depend on the payload stamp, or a fresh checkout hits the assembler's
#     hard require instead of building the payload.
grep -qE '^\$\(ROOTFS\):.*\$\(MESA_ANDROID_STAMP\)' "$MAKEFILE" \
    && ok "Makefile orders mesa-android before the rootfs assembly" \
    || bad "\$(ROOTFS) does not depend on \$(MESA_ANDROID_STAMP) -- assembly would fail on a fresh tree"

# 17. A mesa patch add/drop must re-trigger this build too, not only the host overlay's.
grep -q 'MESA_ANDROID_SRC.*\\' "$MAKEFILE" && grep -qF 'packages/mesa/patches/*.patch' "$MAKEFILE" \
    && ok "the payload rebuilds when the shared mesa patch list changes" \
    || bad "MESA_ANDROID_SRC does not track packages/mesa/patches -- a patch change would not rebuild the Android driver"

echo
echo "the fossilize stub layer (Lepton enables it unconditionally)"

LAYER_JSON="$ROOT/packages/fossilize-stub-android/layer.json"
LAYER_C="$ROOT/packages/fossilize-stub-android/layer.c"
SLOT_LAYER_PATH="/usr/share/guestos/android/vendor/vulkan_layers/libVkLayer_fossilize.so"

# 18. The package exists and the assembler hard-requires its payload. Lepton calls
#     enable_vulkan_layer for fossilize with NO env guard (unlike the RPO/FDM layers beside it) and
#     runs under `set -e`, so an absent layer is a fatal launch failure for EVERY Android title --
#     not a rendering degradation. A best-effort staging here would reintroduce exactly that.
[[ -f $LAYER_C && -f $LAYER_JSON ]] \
    && ok "packages/fossilize-stub-android ships the layer source and its manifest" \
    || bad "the fossilize stub package is incomplete -- no Android title can launch without it"

grep -q 'fossilize stub payload missing' "$ASSEMBLE" \
    && ok "the assembler hard-requires the stub payload (not best-effort)" \
    || bad "the assembler does not hard-require the fossilize payload -- a missing layer would ship silently"

# 19. The manifest is the OTHER half. get_vulkan_layer_id maps the .so basename to a layer ID via
#     `find /usr/share/vulkan -name '*.json' | xargs jq … .name` and needs EXACTLY ONE match, so a
#     manifest whose library_path stops matching the staged .so fails the launch just as hard as a
#     missing library. Two files, one path, no compiler to catch the drift.
grep -qF "$SLOT_LAYER_PATH" "$LAYER_JSON" \
    && ok "layer.json's library_path names the slot path the assembler stages to" \
    || bad "layer.json does not point at $SLOT_LAYER_PATH -- the layer ID lookup would find nothing"

grep -q 'the staged vulkan layer manifest does not point at the staged layer' "$ASSEMBLE" \
    && ok "the assembler re-checks that pairing at build time" \
    || bad "nothing verifies the manifest still matches the staged layer"

# 20. It must NOT land in a directory the HOST's vulkan loader scans. The manifest points at an
#     Android/bionic .so; if the host loader finds it, every host vulkan app tries to load a
#     library it cannot possibly use. Lepton's find is recursive, so a sibling dir serves both.
if grep -qE 'usr/share/vulkan/(implicit|explicit)_layer\.d/[^"]*fossilize' "$ASSEMBLE"; then
    bad "the stub manifest is staged into a *_layer.d/ dir -- the HOST loader would try to load a bionic .so"
else
    ok "the manifest avoids implicit_layer.d/explicit_layer.d (invisible to the host loader)"
fi
grep -q 'usr/share/vulkan/novadeck-guest-layer.d' "$ASSEMBLE" \
    && ok "it is staged somewhere Lepton's recursive find still reaches" \
    || bad "the manifest is not staged under /usr/share/vulkan -- Lepton could not find the layer ID"

# 21. jq is what runs that lookup. Absent, the pipeline is empty, the ID lookup fails, and it is
#     indistinguishable from a missing layer -- the same class of bug as `which` and inotify-tools.
#
#     RELEASE cards need it as much as dev ones, so PKGS is where it belongs. It is parked in
#     DEV_PKGS only to let the fossilize-stub HW test build without a relock first (a PKGS entry
#     with no lock row fails the build outright: `unsatisfied: jq`). This check passes either way
#     but SAYS which, so the release obligation cannot be forgotten silently -- a release card built
#     while it sits in DEV_PKGS has no jq, and every Lepton launch dies.
CB_SH="$ROOT/rootfs/customize-base.sh"
if grep -qE '^PKGS=\(.*\bjq\b' "$CB_SH"; then
    ok "jq is in PKGS (release-safe; the layer-ID lookup shells out to it)"
elif grep -qE '^DEV_PKGS=\(.*\bjq\b' "$CB_SH"; then
    ok "jq is present, but PARKED IN DEV_PKGS -- move it to PKGS + 'make relock' before release"
else
    bad "jq is in neither PKGS nor DEV_PKGS -- get_vulkan_layer_id would fail for every layer"
fi

# 22. The build must gate what it produces: a host-arch or glibc-linked .so cannot load in the
#     bionic guest, and Android's loader reports nothing useful when it fails.
CB="$ROOT/packages/fossilize-stub-android/container-build.sh"
grep -q 'AArch64' "$CB" && grep -q 'links glibc' "$CB" \
    && grep -q 'vkNegotiateLoaderLayerInterfaceVersion is not exported' "$CB" \
    && ok "the build gates arch, libc and the exported loader entry point" \
    || bad "the container build does not gate the payload -- a wrong-arch or glibc layer could ship"

echo
echo "kernel support"

# 18. The guest is a rootless podman container; binder is what Android's whole IPC layer runs on
#     and its absence was the original total boot failure. Listed here because a kernel bump that
#     dropped it would present as this slot's symptom (a dark guest), not as a kernel problem.
for sym in CONFIG_ANDROID_BINDER_IPC CONFIG_ANDROID_BINDERFS; do
    grep -q "^$sym=y" "$KCONFIG" \
        && ok "$sym=y" \
        || bad "$sym is not =y -- the Android guest cannot boot at all"
done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
