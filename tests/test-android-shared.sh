#!/usr/bin/env bash
# Offline checks for the SHARED Android container: Google Play, the framework fix, and the names
# that tie novadeck-android, its user unit and gamescope patch 0023 together.
#
# Most of what can go wrong here is a NAME drifting between files that never import each other:
#   rootfs/overlay/usr/bin/novadeck-android          the runtime (service body + Steam title commands)
#   rootfs/overlay/usr/lib/systemd/user/novadeck-android.service
#   packages/gamescope/patches/0023-*.patch          matches the unit name in the client's cgroup, and
#                                                    reads the root property novadeck-android sets
#   packages/lepton-framework/                       the tools novadeck-android builds the framework
#                                                    fix with, staged where it reads them
#   packages/android-gapps/payload.pin               the SDK the Play set is for
#   rootfs/lib-assemble-storage.sh                   stages both payloads OUTSIDE the guestos slot
# None of these fail at build time when they disagree. They fail on a device, silently: focus and
# touch go to the wrong window, or Play is simply absent from the guest.
#
# Runs on the host with no root, no device and no build.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME="$ROOT/rootfs/overlay/usr/bin/novadeck-android"
URLHELPER="$ROOT/rootfs/overlay/usr/bin/novadeck-steam-url"
UNIT="$ROOT/rootfs/overlay/usr/lib/systemd/user/novadeck-android.service"
SETUP_UNIT="$ROOT/rootfs/overlay/usr/lib/systemd/user/novadeck-android-setup.service"
SETUP_WANTS="$ROOT/rootfs/overlay/usr/lib/systemd/user/default.target.wants/novadeck-android-setup.service"
PATCH="$(compgen -G "$ROOT/packages/gamescope/patches/0023-*.patch" | head -n1)"
GS_PIN="$ROOT/packages/gamescope/source.pin"
GAPPS_PIN="$ROOT/packages/android-gapps/payload.pin"
FW_PIN="$ROOT/packages/lepton-framework/framework.pin"
FW_BUILD="$ROOT/packages/lepton-framework/build.sh"
COMPILE="$ROOT/packages/lepton-framework/compile-odex.sh"
RESTORE="$ROOT/packages/lepton-framework/restore-services.py"
REPACK="$ROOT/packages/lepton-framework/repack-jar.py"
ASSEMBLE="$ROOT/rootfs/lib-assemble-storage.sh"
KEYLAYOUT="$ROOT/rootfs/android-shared/system/usr/keylayout/Vendor_28de_Product_11ff.kl"
MAKEFILE="$ROOT/Makefile"

PASS=0; FAIL=0
ok()  { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }

for f in "$RUNTIME" "$URLHELPER" "$UNIT" "$SETUP_UNIT" "$PATCH" "$GS_PIN" "$GAPPS_PIN" "$FW_PIN" \
         "$FW_BUILD" "$COMPILE" "$RESTORE" "$REPACK" "$ASSEMBLE" "$KEYLAYOUT" "$MAKEFILE"; do
    [[ -f $f ]] || { echo "missing input: ${f:-0023 patch}" >&2; exit 1; }
done

pin_field() { sed -n "s/^$2:[[:space:]]*//p" "$1" | head -1; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo "names shared across files"

# 1. The unit name. gamescope flags the Android window by finding it in the client's cgroup path.
unit_name="$(basename "$UNIT")"
grep -q "^UNIT=$unit_name\$" "$RUNTIME" \
    && ok "novadeck-android drives $unit_name" \
    || bad "novadeck-android's UNIT= is not $unit_name"
grep -qF "\"$unit_name\"" "$PATCH" \
    && ok "gamescope 0023 looks for $unit_name in the cgroup" \
    || bad "gamescope 0023 does not match $unit_name -- the shared Android window would never be flagged"

# 2. The root property the runtime sets and gamescope reads.
atom="$(grep -o 'XInternAtom([^)]*"\([A-Z_]*\)"' "$PATCH" | grep -o '"NOVADECK_[A-Z_]*"' | tr -d '"' | head -n1)"
if [[ -n $atom ]] && grep -q -- "-set $atom " "$RUNTIME"; then
    ok "both sides use the $atom root property"
else
    bad "the root property differs between gamescope 0023 (${atom:-none}) and novadeck-android"
fi

# 3. 0023 is actually applied.
grep -qF "$(basename "$PATCH")" "$GS_PIN" \
    && ok "0023 is in gamescope's source.pin" \
    || bad "0023 is not in source.pin -- the runtime would set a property nothing reads"

# 4. The framework-fix tools: staged where the runtime reads them, and every file it reads is one
#    the assembler stages.
tools="$(sed -n 's/^fw_tools="\(.*\)"$/\1/p' "$ASSEMBLE")"
grep -q "^FW_TOOLS=/$tools\$" "$RUNTIME" \
    && ok "the runtime reads the framework tools where the assembler stages them (/$tools)" \
    || bad "novadeck-android's FW_TOOLS differs from the assembler's fw_tools (${tools:-none})"
missing=""
for f in $(grep -o '\${FW_TOOLS}/[A-Za-z0-9._-]*' "$RUNTIME" | sed 's|.*/||' | sort -u); do
    grep -q "$f" <(sed -n '/^fw_tools=/,/^chmod 0644/p' "$ASSEMBLE") || missing+=" $f"
done
[[ -z $missing ]] && ok "every framework tool the runtime uses is staged" \
    || bad "the runtime uses framework tools the assembler never stages:$missing"

# 5. The Lepton edits the runtime makes are all gated on its own variable, so a normal Steam launch
#    of an Android title runs Valve's code unchanged.
gated="$(awk '/^patch_lepton\(\)/,/^EOF$/' "$RUNTIME" | grep -c 'NOVADECK_ANDROID_\(OVERLAY\|PROPS\)')"
[[ $gated -ge 3 ]] \
    && ok "the Lepton edits that change a container are gated on NOVADECK_ANDROID_* ($gated)" \
    || bad "a Lepton edit is not gated on NOVADECK_ANDROID_* -- it would change Valve's own titles"

echo
echo "user units"

grep -q '^ExecStart=/usr/bin/novadeck-android daemon$' "$UNIT" \
    && ok "the service runs the daemon" || bad "novadeck-android.service does not run 'novadeck-android daemon'"
grep -q '^KillMode=mixed$' "$UNIT" \
    && ok "KillMode=mixed, so Lepton stops its own container" \
    || bad "KillMode is not mixed -- systemd would kill podman under Lepton's feet"
grep -q '^ConditionUser=deck$' "$UNIT" && grep -q '^ConditionUser=deck$' "$SETUP_UNIT" \
    && ok "both units run for deck only" || bad "a unit is missing ConditionUser=deck"
[[ -L $SETUP_WANTS && "$(readlink "$SETUP_WANTS")" == /usr/lib/systemd/user/novadeck-android-setup.service ]] \
    && ok "the Play Store title is added at login (default.target.wants)" \
    || bad "novadeck-android-setup.service is not wanted by default.target"
for f in "$RUNTIME" "$URLHELPER"; do
    [[ -x $f ]] && ok "$(basename "$f") is executable" || bad "$(basename "$f") is not executable"
done
bash -n "$RUNTIME" && ok "novadeck-android parses" || bad "novadeck-android has a syntax error"
sh -n "$URLHELPER" && ok "novadeck-steam-url parses" || bad "novadeck-steam-url has a syntax error"
grep -q -- '-ifrunning' "$URLHELPER" \
    && ok "novadeck-steam-url only forwards to a running client (-ifrunning)" \
    || bad "novadeck-steam-url could start a second Steam client"

echo
echo "the Play payload"

sdk="$(pin_field "$GAPPS_PIN" sdk)"
[[ $sdk =~ ^[0-9]+$ ]] && ok "payload.pin names its guest SDK ($sdk)" || bad "payload.pin has no numeric sdk:"
for k in mtg11_sha256 phonesky_sha256 keyboard_sha256; do
    [[ "$(pin_field "$GAPPS_PIN" "$k")" =~ ^[0-9a-f]{64}$ ]] \
        && ok "$k is a sha256" || bad "$k is not a 64-hex sha256"
done
# The props spoof presents an Android 11 build; it must only ever go into the guest SDK it names.
grep -q '\[\[ "\$sdk" == 30 \]\]' "$RUNTIME" && [[ $sdk == 30 ]] \
    && ok "the Pixel 5 / Android 11 identity is applied to an SDK-30 guest only" \
    || bad "the identity spoof and the payload SDK disagree"
# Staged where only the shared container sees it -- never into the guestos slot.
grep -q '^shared_root="usr/share/novadeck-android"$' "$ASSEMBLE" \
    && ok "Play is staged under /usr/share/novadeck-android" || bad "the shared payload root moved"
if grep -rqsl 'Phonesky\|GmsCore\|GoogleServicesFramework' "$ROOT/rootfs/guestos" "$ROOT/rootfs/overlay/usr/share/guestos"; then
    bad "a Google component is in the guestos slot -- it would ride into Valve's own Android titles"
else
    ok "nothing Google-owned is in the guestos slot"
fi
grep -q '^OVERLAY_ROOT=/usr/share/novadeck-android$' "$RUNTIME" \
    && ok "the runtime reads the same root the assembler writes" \
    || bad "novadeck-android's OVERLAY_ROOT differs from the assembler's shared_root"
grep -q 'ANDROID_GAPPS_STAMP) \$(LEPTON_FW_STAMP)' "$MAKEFILE" \
    && ok "both fetches are prerequisites of the rootfs" \
    || bad "the rootfs does not depend on the android-gapps / lepton-framework stamps"
grep -q '^key 304 *BUTTON_A$' "$KEYLAYOUT" && grep -q '^axis 0x02 LTRIGGER$' "$KEYLAYOUT" \
    && ok "the Steam pad layout maps the triggers as triggers" \
    || bad "the Steam pad key layout lost its Xbox 360 mapping"

echo
echo "the framework fix"

for k in r8 smali baksmali; do
    [[ "$(pin_field "$FW_PIN" "${k}_url")" == https://* && "$(pin_field "$FW_PIN" "${k}_sha256")" =~ ^[0-9a-f]{64}$ ]] \
        && ok "framework.pin pins $k by url + sha256" || bad "framework.pin: $k is not pinned by url + sha256"
done
# The runtime builds only for a guest of the SDK the tools target, read from what build.sh writes.
grep -qF '"$(guest_sdk)" == "$(cat "${FW_TOOLS}/api"' "$RUNTIME" && grep -qF '>"$OUT/api"' "$FW_BUILD" \
    && ok "the runtime builds the fix only for the SDK the staged tools target" \
    || bad "the runtime's SDK gate and build.sh's api file disagree"
# The runtime's completeness check counts compile-odex.sh's outputs, plus services.jar itself.
outs="$(grep -oE -- '--(oat-file|output-vdex|app-image-file)=' "$COMPILE" | wc -l)"
want="$(grep -oE '\[\[ "\$n" -eq [0-9]+ \]\]' "$RUNTIME" | grep -oE '[0-9]+')"
[[ -n $want && $want -eq $((outs + 1)) ]] \
    && ok "the runtime expects compile-odex.sh's $outs outputs + services.jar ($want files)" \
    || bad "the runtime expects ${want:-?} files, compile-odex.sh writes $outs + services.jar"
[[ "$(pin_field "$FW_PIN" api)" == "$sdk" ]] \
    && ok "the restore targets the same SDK as the Play payload" \
    || bad "framework.pin api and payload.pin sdk disagree"

# ART_ENV must EXPORT every variable dalvikvm64 needs: a bare newline inside it once ended the
# export after ANDROID_ART_ROOT, and ART died with no boot class path (seen on a device).
art_env="$(awk '/^ART_ENV=\x27/{f=1} f{print} f&&/\x27$/{exit}' "$RUNTIME" | sed "1s/^ART_ENV='//; \$s/'\$//")"
# env by absolute path: ART_ENV exports the guest's PATH, which has no env on the host.
exported="$(sh -c "${art_env} $(command -v env)" 2>/dev/null)"
missing=""
for v in ANDROID_ROOT ANDROID_DATA ANDROID_ART_ROOT ANDROID_I18N_ROOT ANDROID_TZDATA_ROOT BOOTCLASSPATH; do
    grep -q "^$v=" <<<"$exported" || missing+=" $v"
done
[[ -n $art_env && -z $missing ]] && ok "ART_ENV exports everything the guest's ART needs" \
    || bad "ART_ENV does not export:${missing:- (could not extract ART_ENV)}"

# The build steps stop at the first failure. They run as their own process because bash ignores
# errexit under an `if`; here the very first step (reading the staged api file) fails on the host,
# so nothing after it may run.
steps_out="$(HOME="$TMP/home" bash "$RUNTIME" framework-steps "$TMP/w" "$TMP/o" 2>&1)"; steps_rc=$?
if [[ $steps_rc -ne 0 && $steps_out != *"== baksmali"* ]]; then
    ok "framework-steps stops at its first failure"
else
    bad "framework-steps ran on past a failure (rc=$steps_rc)"
fi
grep -qF '"${BASH_SOURCE[0]}" framework-steps' "$RUNTIME" \
    && ok "build_framework runs the steps as their own process (errexit holds)" \
    || bad "build_framework runs the steps in-process, where errexit is ignored under its if"

# restore-services.py inserts before the one anchor, exactly once, and a second run changes nothing.
cat >"$TMP/SystemServer.smali" <<'SMALI'
.method private startOtherServices()V
    const-string v0, "AppServiceManager"
.end method
SMALI
python3 "$RESTORE" "$TMP/SystemServer.smali" && cp "$TMP/SystemServer.smali" "$TMP/once.smali" \
    && python3 "$RESTORE" "$TMP/SystemServer.smali"
if cmp -s "$TMP/once.smali" "$TMP/SystemServer.smali" \
   && [[ "$(grep -c 'restored services' "$TMP/once.smali")" -eq 1 ]]; then
    ok "restore-services.py applies once and is idempotent"
else
    bad "restore-services.py is not idempotent"
fi
for svc in ClipboardService RestrictionsManagerService BiometricService AuthService \
           CrossProfileAppsService NsdService HardwarePropertiesManagerService; do
    grep -q "$svc" "$TMP/once.smali" && ok "restores $svc" || bad "no longer restores $svc"
done
# BiometricService must start before AuthService, which binds to it at start.
bio="$(grep -n 'biometrics/BiometricService;$' "$TMP/once.smali" | head -n1 | cut -d: -f1)"
auth="$(grep -n 'biometrics/AuthService;$' "$TMP/once.smali" | head -n1 | cut -d: -f1)"
[[ -n $bio && -n $auth && $bio -lt $auth ]] \
    && ok "BiometricService starts before AuthService" \
    || bad "AuthService starts before BiometricService -- it binds to it and fails"

# repack-jar.py keeps every entry STORED and 4-byte aligned (ART mmaps dex in place).
python3 - "$TMP" <<'PY'
import sys, zipfile
d = sys.argv[1]
with zipfile.ZipFile(f"{d}/in.jar", "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr("a", b"x" * 3)
    z.writestr("classes.dex", b"dex\n035\0" + b"y" * 5)
    z.writestr("META-INF/MANIFEST.MF", b"Manifest-Version: 1.0\n")
open(f"{d}/new.dex", "wb").write(b"dex\n035\0" + b"z" * 11)
PY
if python3 "$REPACK" "$TMP/in.jar" "$TMP/out.jar" "classes.dex=$TMP/new.dex" >/dev/null \
   && python3 - "$TMP" <<'PY'
import sys, zipfile
d = sys.argv[1]
z = zipfile.ZipFile(f"{d}/out.jar")
assert z.read("classes.dex") == open(f"{d}/new.dex", "rb").read()
for i in z.infolist():
    assert i.compress_type == zipfile.ZIP_STORED
    assert (i.header_offset + 30 + len(i.filename.encode()) + len(i.extra)) % 4 == 0
PY
then
    ok "repack-jar.py replaces the dex and keeps entries stored and 4-byte aligned"
else
    bad "repack-jar.py output is not stored/aligned, or the dex was not replaced"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
