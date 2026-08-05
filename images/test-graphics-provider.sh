#!/usr/bin/env bash
# Offline check for the FEX guest graphics provider.
#
#   images/test-graphics-provider.sh
#
# WHY THIS EXISTS. The two fstab entries injected by images/assemble-rootfs.sh carry `nofail` on
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
# It also pins the pieces the mount depends on but does not itself state: that the manifest is
# well-formed and only names directories the pinned guest actually contains, that the overlay
# really does layer the manifest OVER the guest (lowerdir is leftmost-wins -- reverse the order and
# the manifest is shadowed rather than shadowing), and that the kernel can mount any of it at all.
#
# Runs on the host with no root, no device and no build.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$ROOT/fs-overlay/usr/share/guestos/fex-mesa.d/graphics_provider.json"
ASSEMBLE="$ROOT/images/assemble-rootfs.sh"
PIN="$ROOT/packages/fex-rootfs/prebuilt.pin"
KCONFIG="$ROOT/kernel/kernel.config"

MOUNTPOINT=/usr/share/guestos/fex-mesa
LOWER_PRIV=/run/novadeck/fex-guest
MANIFEST_DIR=/usr/share/guestos/fex-mesa.d

PASS=0; FAIL=0
ok()   { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }

for f in "$MANIFEST" "$ASSEMBLE" "$PIN" "$KCONFIG"; do
    [[ -f $f ]] || { echo "missing input: $f" >&2; exit 1; }
done

echo "graphics provider manifest"

# 1. Well-formed, and the schema version pressure-vessel actually parses.
if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$MANIFEST" 2>/dev/null; then
    ok "graphics_provider.json is valid JSON"
else
    bad "graphics_provider.json is not valid JSON"
fi

gp=$(python3 - "$MANIFEST" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
v = d.get("graphics_provider_v0")
if not isinstance(v, dict):
    print("NO_V0"); raise SystemExit
arches = v.get("architectures")
if not isinstance(arches, dict):
    print("NO_ARCHES"); raise SystemExit
print("root=%s" % v.get("root", "./"))
print("locales=%s" % v.get("locales", True))
print("arches=%s" % ",".join(sorted(arches)))
for tuple_, cfg in sorted(arches.items()):
    for key in ("dri", "gbm", "gconv"):
        if key in cfg:
            print("path=%s" % cfg[key])
    for p in cfg.get("fallback_library_paths", []):
        print("path=%s" % p)
PY
)

case $gp in
    NO_V0)     bad "manifest has no graphics_provider_v0 object"; gp="" ;;
    NO_ARCHES) bad "manifest declares no architectures"; gp="" ;;
    "")        bad "manifest could not be parsed for schema keys" ;;
esac

if [[ -n $gp ]]; then
    ok "manifest uses the graphics_provider_v0 schema"

    # Both guest architectures must be declared: FEX emulates x86_64 AND i386, and Valve's
    # emulator.json names both. Declaring only x86_64 silently breaks every 32-bit title.
    arches=$(sed -n 's/^arches=//p' <<<"$gp")
    [[ $arches == "i386-linux-gnu,x86_64-linux-gnu" ]] \
        && ok "declares both guest architectures" \
        || bad "expected both guest arches, got '$arches'"

    # Every declared path must be absolute -- they are resolved inside the guest root, and a
    # relative path here resolves against the manifest's directory instead.
    badpath=0
    while IFS= read -r p; do
        [[ $p == /* ]] || { bad "declared path is not absolute: $p"; badpath=1; }
    done < <(sed -n 's/^path=//p' <<<"$gp")
    [[ $badpath -eq 0 ]] && ok "all declared driver paths are absolute"
fi

echo
echo "fstab injection"

# 2. The pin's dest IS the mount source. This is the drift guard.
dest=$(sed -n 's/^dest:[[:space:]]*//p' "$PIN" | tr -d '[:space:]')
if [[ -z $dest ]]; then
    bad "could not read 'dest:' from $(basename "$PIN")"
elif grep -qF -- "$dest  $LOWER_PRIV  erofs" "$ASSEMBLE"; then
    ok "mount source matches fex-rootfs pin dest ($dest)"
else
    bad "fstab source does not match pin dest '$dest' -- the guest mount would source a stale path"
fi

# 3. Both halves present. One without the other is useless: the image alone is never surfaced at
#    the probed path, and the overlay alone has no guest underneath it.
grep -q "erofs  loop,ro,nofail" "$ASSEMBLE" \
    && ok "guest image is loop-mounted read-only" \
    || bad "no read-only loop mount for the guest image"

grep -q "overlay  $MOUNTPOINT  overlay" "$ASSEMBLE" \
    && ok "overlay is mounted at the path the compat tool probes" \
    || bad "no overlay mounted at $MOUNTPOINT"

# 4. Layer ORDER. lowerdir is leftmost-wins; reversed, the guest shadows our manifest and the
#    compat tool finds no graphics_provider.json at all -- falling back to a rootfs with no
#    provider, which is exactly the silent failure this file exists to prevent.
if grep -q "lowerdir=$MANIFEST_DIR:$LOWER_PRIV" "$ASSEMBLE"; then
    ok "manifest layer is leftmost (shadows the guest)"
else
    bad "lowerdir order is wrong or missing -- manifest must precede $LOWER_PRIV"
fi

# 5. Ordering dependency. Without this the overlay can be attempted before the erofs is mounted,
#    and it would succeed over an empty directory.
grep -q "x-systemd.requires-mounts-for=$LOWER_PRIV" "$ASSEMBLE" \
    && ok "overlay is ordered after the guest image mount" \
    || bad "overlay does not require $LOWER_PRIV -- it could mount over an empty dir"

# 6. The mountpoint has to exist in the read-only image; it cannot be created at runtime.
grep -q "mkdir -p \"\$stage$MOUNTPOINT\"" "$ASSEMBLE" \
    && ok "mountpoint is created in the image" \
    || bad "$MOUNTPOINT is never created -- /usr is read-only at runtime"

echo
echo "kernel support"

# 7. The mount is impossible without all three. EROFS_FS_ZIP covers LZ4, which is what the pinned
#    image uses (its superblock sets no COMPR_CFGS bit, so LZ4 is the only algorithm in play).
for sym in CONFIG_EROFS_FS CONFIG_OVERLAY_FS CONFIG_BLK_DEV_LOOP CONFIG_EROFS_FS_ZIP; do
    grep -q "^$sym=y" "$KCONFIG" \
        && ok "$sym=y" \
        || bad "$sym is not =y -- the guest cannot be mounted"
done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
