#!/usr/bin/env bash
# novadeck read-only root assembler — stage 4g, first-boot storage.
#
# SOURCED by rootfs/assemble-rootfs.sh, never executed. Split out of it for issue #43; the code
# and its rationale are unchanged, and the stage banner below is the same one the assembler
# carried (tests/test-mkroot.sh reads the stage IDs out of this file set).
#
# Carries the grow-home.sh heredoc verbatim -- do not re-indent it.
#
# Reads the assembler's globals rather than taking arguments -- $stage (the staged tree), $ROOT
# (repo root), $OUT (build outputs). Turning ~20 implicit globals into positional parameters is
# where a verbatim move stops being verbatim, so it is deliberately not done.

# 4g. First-boot STORAGE (the deck user's growable home). SteamOS sizes /home to the disk at
# install time; we dd a fixed image to a card, so we grow on first boot instead. Three pieces:
#  - /etc/fstab mounts the dedicated home partition (/dev/novadeck/novadeck-home, ext4) at /home.
#    nofail so a card without that partition (the old 2-partition test image) still boots.
#  - novadeck-grow-home: a oneshot that extends the home partition (systemd-repart) + its ext4
#    (resize2fs from e2fsprogs, in the base) to fill the device on first boot, before /home mounts.
#  - the deck user (uid 1000) is baked into the base /etc (customize-base.sh); the seeder above
#    materializes + chowns /home/deck on first boot. Steam (self-update + games) lives on /home.
#  The shared ESP is also fstab-mounted here, at /esp (Phase 5). It is the partition's only mount
#  definition: GPT bit 63 (partition-table.txt) keeps gpt-auto from auto-mounting it at /efi.
echo "  injecting first-boot storage: /home mount + grow (deck user baked in base)"
mkdir -p "$stage/etc"
#
# BOTH ROWS NAME /dev/novadeck/<GPT name>, NOT PARTLABEL=/LABEL=. Every novadeck medium carries the
# same eight GPT names, so with a card inserted in a device installed to internal storage a label
# names whichever disk udev enumerated first — and udev publishes ONE symlink per duplicate name, so
# the loser gets none at all. /dev/novadeck/* is the same set of links scoped to the disk we booted
# from (usr/lib/udev/rules.d/69-novadeck-bootdisk.rules + usr/lib/novadeck/on-boot-disk), which is
# the only disk either of these mounts can correctly mean. It matters most for the ESP: stage 2
# INCREMENTS boot-attempts on the booted disk's ESP, and mark-good clears it through this mount — on
# the wrong ESP the counter climbs every boot until steamcl's failsafe fires, and the other
# install's A.conf is stamped over. Both confs are named A.conf, so nothing downstream can notice.
if ! grep -q '/dev/novadeck/NOVADECK-ESP' "$stage/etc/fstab" 2>/dev/null; then
  printf '%s\n' \
    '# novadeck shared ESP — SteamOS/conf + steamcl (stage 1). Mounted here at /esp; GPT bit 63' \
    '# keeps gpt-auto away so the initramfs can mount the slot efi partition at /efi instead.' \
    '/dev/novadeck/NOVADECK-ESP  /esp  vfat  defaults,nofail,noatime  0 2' \
    >>"$stage/etc/fstab"
fi
if ! grep -q '/dev/novadeck/novadeck-home' "$stage/etc/fstab" 2>/dev/null; then
  printf '%s\n' \
    '# novadeck shared data partition — the deck user home + Steam library live here.' \
    '# novadeck-grow-home.service grows BOTH the partition (systemd-repart) and the ext4 (resize2fs)' \
    '# before this mounts. x-systemd.growfs stays only as a belt-and-suspenders fallback (a no-op' \
    '# once grow-home has already sized the fs to the partition).' \
    '/dev/novadeck/novadeck-home  /home  ext4  defaults,nofail,x-systemd.growfs  0 2' \
    >>"$stage/etc/fstab"
fi

# 4g-bis. The FEX guest rootfs + our x86 Turnip payload, surfaced as ONE merged tree.
#
# Valve publishes FEX as a Steam Play compat tool (app 3127680). On its public branch the tool
# ships the emulator and thunks only — its rootfs depot is empty — and it expects the OS to
# provide the x86 guest at a fixed path, /usr/share/guestos/fex-mesa. Our pinned ArchLinux.ero
# satisfies that contract in full (both arches carry a complete Mesa, dri/, gbm/, gconv/,
# both interoperable linkers, ld.so.cache, ldconfig, merged-/usr) — see .claude/plans/. The tool
# PROBES that fixed path for /graphics_provider.json, which the guest ships at its root, and the
# same path is what the tool hands FEX as `RootFS`.
#
# TWO mounts, since the mesa-x86 payload landed. The guest's own libvulkan_freedreno.so (both
# arches) is a mesa git snapshot owned by NO guest package — whatever the FEX rootfs pipeline
# happened to build — and under our THUNKLESS system-FEX config it is the driver that actually
# renders every native x86 Linux title. So the pinned image loop-mounts read-only as a LOWER
# layer at /run/novadeck/guestos-lower, and an overlayfs lays the payload staged below (the
# Turnip built by packages/mesa-x86 from the host mesa's exact source pin + patch list) over it
# at /usr/share/guestos/fex-mesa. The guest tree every consumer sees carries OUR driver; the
# pinned artifact itself stays byte-identical to its pin.
#
# BOTH x86 consumers read the merged mountpoint: the compat tool probes it, and rootfs/overlay's
# Config.json points the system FEX's `RootFS` at the same path — one tree for every x86
# consumer, and FEXServer no longer erofsfuse-mounts the image per-user. (Mechanism adopted from
# a peer distro's guestos mount for the same guest image; see the commit that added it.)
#
# systemd itself creates missing mountpoints under /run, and x-systemd.requires-mounts-for on
# the overlay row orders it after the lower mount — no unit, no tmpfiles.
#
# nofail on both, deliberately: this feeds native x86 Linux games only. A missing or corrupt
# guest must cost x86 Linux titles, never a boot. That makes every failure here a quiet one --
# hence the gates below, and tests/test-graphics-provider.sh for the parts visible in
# committed files.
#
# x-systemd.before=local-fs.target ON BOTH ROWS, and it is not decoration: `nofail` does TWO
# things, and the second one is a shutdown bug. Besides demoting local-fs.target's dependency
# from Requires= to Wants= (which is what we want), it also DROPS the unit's
# Before=local-fs.target ordering. Without that ordering these two mounts are torn down in the
# FIRST shutdown wave, concurrently with the session that is still using them, instead of after
# local-fs.target stops like every other filesystem on the box.
#
# MEASURED on HW (dev card, three consecutive reboots, 2026-08-27), each one identical:
#
#   [44.716] Unmounting /usr/share/guestos/fex-mesa...     <- session still up
#   [44.755] umount: /usr/share/guestos/fex-mesa: target is busy.
#   [44.759] Failed unmounting /usr/share/guestos/fex-mesa.
#   [44.844] Unmounting /run/novadeck/guestos-lower...     <- overlay STILL MOUNTED
#   [44.877] Unmounted /run/novadeck/guestos-lower.        <- and it SUCCEEDS
#   [44.941] session-1.scope: Deactivated successfully.    <- the holder, 185ms too late
#
# The busy is Decky's PluginLoader: it is an x86 binary run under system FEX, so its guest libs
# are mapped out of the merged tree and it holds the overlay until the session scope dies. The
# real damage is the line after it -- a FAILED stop job is still a COMPLETED job, so the ordering
# between the two mounts is satisfied and systemd pulls the erofs lower out from under a live
# overlay. The superblock survives (the overlay pins it), so this has cost us nothing visible
# yet, but "lowerdir is a detached mount" is not a state to leave a shutdown in.
#
# Restoring the ordering moves both unmounts into the late wave, next to /tmp and the offload
# binds, by which time the session scope is long gone. It does NOT re-arm the boot hazard nofail
# exists to prevent: Wants= is untouched, so a missing or corrupt guest still cannot fail the
# boot, and neither row can hang local-fs.target waiting -- both mount a file that is already on
# the mounted root (no device probe, no network), and the overlay Requires= the lower via
# requires-mounts-for, so a missing guest fails both rows immediately instead of stalling.
#
# THE GATE IS NOT OPTIONAL, and its exit code is not the signal. `dump.erofs --path` returns 0 for
# a path that does not exist (it only prints "read inode failed" to stderr), so the check has to be
# on the CONTENT: pipe the file out and parse it. A rootfs bump to an image without a manifest
# would otherwise be discovered by a user, at x86 game launch, as a game that does not start.
echo "  injecting FEX guest graphics-provider mount (/usr/share/guestos/fex-mesa)"
guest_ero="$stage/usr/share/fex-emu/RootFS/ArchLinux.ero"
[ -f "$guest_ero" ] || { echo "ERROR: FEX guest rootfs missing at ${guest_ero#"$stage"}" >&2; exit 1; }

# A LISTING'S LENGTH IS NOT ITS COMPLETENESS, and both gates below read listings off this image.
# `[ -n "$guest_libs" ]` proves only that the read returned SOMETHING, and a short read of a 2 GB
# image returns a non-empty PREFIX: the libraries before the truncation point resolve, the ones
# after it do not, and the NEEDED gate then reports the first casualty as a missing dependency.
#
# MEASURED 2026-08-22: two release builds in a row failed with "libvulkan_freedreno.so NEEDs
# libdrm.so.2", both immediately after work/base's ArchLinux.ero had been rewritten by the dev ->
# release base switch -- while that same libdrm.so.2 was demonstrably present in the source AND in
# a hand-made copy of the staged image, listed with the same command. The third build passed with
# nothing changed. An hour went into hunting a dependency break that did not exist, and the error
# message pointed at mesa the whole time.
#
# So establish that the staged image IS the source image before trusting anything read out of it.
# Size is the entire check: cp either brought all 2 GB across or it did not, and a mismatch is a
# short copy rather than anything about drivers -- which is what the message has to say, because
# the failure it replaces was convincing and wrong.
src_ero="$BASE/usr/share/fex-emu/RootFS/ArchLinux.ero"
if [ -f "$src_ero" ]; then
  staged_bytes="$(stat -c %s "$guest_ero")"
  src_bytes="$(stat -c %s "$src_ero")"
  [ "$staged_bytes" = "$src_bytes" ] || {
    echo "ERROR: the staged FEX guest is $staged_bytes bytes against $src_bytes at the source --" >&2
    echo "       a short copy, NOT a dependency problem. Do not go looking at mesa." >&2
    exit 1; }
fi
dump.erofs --cat --path=/graphics_provider.json "$guest_ero" 2>/dev/null | python3 -c '
import json, sys
try:
    manifest = json.load(sys.stdin)["graphics_provider_v0"]
except (ValueError, KeyError, TypeError) as exc:
    sys.exit(f"the pinned FEX guest ships no usable /graphics_provider.json ({exc}) -- "
             "the FEX compat tool probes that path and would find nothing")
# Both arches or 32-bit titles break silently; the schema allows a list or an object.
arches = manifest.get("architectures", {})
for arch in ("x86_64-linux-gnu", "i386-linux-gnu"):
    if arch not in arches:
        sys.exit(f"the guest manifest does not declare {arch}")
' || { echo "ERROR: FEX guest graphics-provider manifest check failed (see above)" >&2; exit 1; }

# The x86 Turnip payload (make mesa-x86). REQUIRED, not best-effort: the Makefile orders the
# build so it always exists here, and a partial payload shadowing half the driver pair is the
# exact quiet failure this stage exists to prevent.
payload="$ROOT/work/mesa-x86/out"
payload_dest="usr/share/novadeck/guestos-x86-mesa"
echo "  staging FEX guest x86 Turnip payload (/$payload_dest)"
for f in usr/lib/libvulkan_freedreno.so usr/lib32/libvulkan_freedreno.so \
         usr/share/vulkan/icd.d/freedreno_icd.x86_64.json \
         usr/share/vulkan/icd.d/freedreno_icd.i686.json \
         usr/lib/libxcb-keysyms.so.1 usr/lib32/libxcb-keysyms.so.1; do
  [ -s "$payload/$f" ] || { echo "ERROR: mesa-x86 payload incomplete: missing $f (make mesa-x86)" >&2; exit 1; }
done
mkdir -p "$stage/$payload_dest"
cp -a "$payload/usr" "$stage/$payload_dest/"

# The lsfg-vk frame-generation Vulkan layer (make lsfg-vk), into the SAME payload so it rides the
# same overlay and the same NEEDED gate below. REQUIRED for the same reason the Turnip is: half a
# layer pair is worse than none, and the Makefile orders the fetch so this always exists here.
#
# It is INERT unless three things line up: the user owns Lossless Scaling, has switched it to the
# `lsfg-vk` Steam beta branch (the only place the v2 shader DLL is published), and has enabled
# frame generation for a specific game. It is an implicit layer, so it would otherwise load into
# every x86 Vulkan app on the device -- DISABLE_LSFGVK=1 in the session env is what keeps it off,
# and the per-game env tombstone is what lifts it. See packages/lsfg-vk/payload.pin.
lsfg_payload="$ROOT/work/lsfg-vk-x86/out"
echo "  staging FEX guest lsfg-vk frame-generation layer (/$payload_dest)"
for f in usr/lib/liblsfg-vk-layer.so usr/lib/liblsfg-vk-layer.x86.so usr/bin/lsfg-vk-cli \
         usr/share/vulkan/implicit_layer.d/VkLayer_LSFGVK_frame_generation.json \
         usr/share/vulkan/implicit_layer.d/VkLayer_LSFGVK_frame_generation.x86.json; do
  [ -s "$lsfg_payload/$f" ] \
    || { echo "ERROR: lsfg-vk payload incomplete: missing $f (make lsfg-vk)" >&2; exit 1; }
done
cp -a "$lsfg_payload/usr" "$stage/$payload_dest/"

# Re-assert the manifest-relative library_path on the STAGED copy, not just where fetch.sh checked
# it. An absolute path here resolves against the container's /usr under Valve's /run/gfx republish
# and the Vulkan loader drops the layer with NO error -- the same silent-drop class the mesa ICDs
# are rewritten for above, and a silent drop is indistinguishable from "frame generation is off".
for m in "$stage/$payload_dest"/usr/share/vulkan/implicit_layer.d/VkLayer_LSFGVK_*.json; do
  grep -q '"library_path": "\.\./\.\./\.\./lib/' "$m" \
    || { echo "ERROR: ${m#"$stage"} lost its manifest-relative library_path between fetch and stage" >&2; exit 1; }
done

# NEEDED-closure gate: every DT_NEEDED of every payload .so must resolve inside the merged guest
# (the guest's own libdir, or the payload itself, which overlays it). An ICD with an unresolvable
# dep is dropped SILENTLY by pressure-vessel's dlopen inspection and dies quietly under system
# FEX, so this is the same class of check as the manifest gate above — a build-time answer to a
# question that otherwise reaches a player first. readelf is arch-agnostic, so the aarch64 build
# container reads these x86 ELFs fine.
# `2>/dev/null` USED TO BE ON THE dump.erofs BELOW, and it hid the only evidence that mattered.
# When the listing comes back short, every NEEDED after the cut looks unresolvable and the gate
# blames the first one -- a message naming mesa for a fault that has nothing to do with it. Keep
# the tool's own complaint and print it with the refusal, along with how much of a listing we
# actually got, so the next reader can tell "the guest does not ship this" from "the read failed".
# ASK ABOUT ONE FILE AT A TIME. This used to list the whole directory once and grep the result,
# and that instrument is not reliable here: release builds failed intermittently -- five runs went
# fail, fail, pass, fail, pass with nothing changed -- each time naming a DIFFERENT library the
# guest demonstrably ships (libdrm.so.2 on three runs, libX11-xcb.so.1 on another). The listing was
# not short when it happened: 2067 entries off the full-size image, dump.erofs silent. So the fault
# was in matching against a 2000-entry blob, not in the read, and the error it produced sent the
# reader to mesa for a fault that had nothing to do with mesa.
#
# A per-path query has no such failure mode and is exact: present prints the entry, absent prints
# nothing (and "read inode failed" on stderr, which is why the EXIT CODE is not the signal here --
# same reason as the manifest gate above). Forty-odd invocations at build time is a fair price for
# a gate that means what it says.
guest_has() {  # <libdir> <soname> -> 0 if the pinned guest ships it
  [ -n "$(dump.erofs --ls --path="/$1/$2" "$guest_ero" 2>/dev/null)" ]
}
for libdir in usr/lib usr/lib32; do
  # The instrument itself is checked once per libdir, against a file every guest must have: if this
  # cannot find libc, the query is broken and every answer below is worthless.
  guest_has "$libdir" libc.so.6 \
    || { echo "ERROR: cannot read /$libdir/libc.so.6 out of the pinned FEX guest -- the guest image or dump.erofs is unusable, and no dependency verdict below can be trusted" >&2; exit 1; }
  for so in "$stage/$payload_dest/$libdir"/*.so*; do
    [ -e "$so" ] || continue   # a libdir with no .so at all must not match the glob literally
    # THE LIBDIR TO COMPARE AGAINST IS CHOSEN BY ELF CLASS, NOT BY DIRECTORY, and that is not
    # pedantry: since lsfg-vk, usr/lib holds a 32-bit ELF on purpose. Upstream's Vulkan layer
    # manifests carry a manifest-relative library_path (`../../../lib/liblsfg-vk-layer.x86.so`),
    # which is exactly what makes them resolve under both our overlay and Valve's /run/gfx
    # republish -- so the i686 layer has to sit in usr/lib beside the 64-bit one, and the licence
    # (CC-BY-NC-ND) says we do not rewrite their manifest to move it. Judging that file against
    # the guest's 64-bit /usr/lib would still PASS, because the sonames it needs (libstdc++.so.6,
    # libm, libgcc_s, libc) exist in both libdirs -- so the gate would be right by luck and would
    # stay right by luck until the day some payload needed a soname present in only one arch.
    case "$(readelf -h "$so" | sed -n 's/.*Class:[[:space:]]*ELF\(32\|64\).*/\1/p')" in
      32) needdir=usr/lib32 ;;
      64) needdir=usr/lib   ;;
      *)  echo "ERROR: ${so#"$stage"}: cannot read ELF class -- not an ELF, or readelf failed" >&2; exit 1 ;;
    esac
    for need in $(readelf -d "$so" | sed -n 's/.*(NEEDED).*\[\(.*\)\].*/\1/p'); do
      if ! guest_has "$needdir" "$need" \
         && [ ! -e "$stage/$payload_dest/$needdir/$need" ] \
         && [ ! -e "$stage/$payload_dest/$libdir/$need" ]; then
        echo "ERROR: ${so#"$stage"} NEEDs $need, which neither the guest /$needdir nor the payload provides" >&2
        exit 1
      fi
    done
  done
done

mkdir -p "$stage/usr/share/guestos/fex-mesa"
if ! grep -q '/usr/share/guestos/fex-mesa' "$stage/etc/fstab" 2>/dev/null; then
  printf '%s\n' \
    '# FEX x86 guest: the pinned guest image, loop-mounted as the LOWER layer of the merged' \
    '# guest tree below. nofail: a missing or corrupt guest must never hold up a boot.' \
    '/usr/share/fex-emu/RootFS/ArchLinux.ero  /run/novadeck/guestos-lower  erofs  loop,ro,nofail,noatime,x-systemd.before=local-fs.target  0 0' \
    '# The merged FEX guest, for BOTH x86 consumers: Valve'"'"'s FEX compat tool (Steam app' \
    '# 3127680) probes this path for graphics_provider.json, and the system FEX Config.json' \
    '# points RootFS here. Our x86 Turnip payload overlays the guest'"'"'s stock driver.' \
    'overlay  /usr/share/guestos/fex-mesa  overlay  ro,nofail,lowerdir=/usr/share/novadeck/guestos-x86-mesa:/run/novadeck/guestos-lower,x-systemd.requires-mounts-for=/run/novadeck/guestos-lower,x-systemd.before=local-fs.target  0 0' \
    >>"$stage/etc/fstab"
fi

# Grow the home PARTITION to fill the device with systemd-repart (declarative, online — it issues
# a BLKPG resize so it works while the disk is in use, and relocates the GPT backup header for us).
# The stock systemd-repart.service is initrd-only (no [Install], Before=initrd-root-fs.target) and
# our initramfs carries no systemd to run it, so ship our own unit running the same tool early in
# real-root boot, before /home mounts. repart matches our partition by its discoverable "Linux
# /home" GUID (typecode 8302 in image/partition-table.txt), so it can never touch the root
# partition. That same GUID would make systemd's gpt-auto generator synthesize a competing
# home.mount, so the partition also carries GPT bit 63 ("no-auto") — /etc/fstab below is the one
# and only definition of home.mount.
#
# The ext4 grow used to ride SOLELY on x-systemd.growfs (mount-time). That RACED home.mount: on HW
# the mount+growfs ran before repart's enlargement was visible, so the fs was sized to the flashed
# ~1G while the partition became 8.7G — /home then filled instantly and the Steam seed died with
# ENOSPC (SteamUI never started). Fix: novadeck-grow-home now runs a wrapper that does repart THEN
# resize2fs, ordered Before=home.mount so the fs grow is a race-free OFFLINE resize (partition
# already enlarged, /home not yet mounted). Idempotent — resize2fs is a no-op once the fs fills the
# partition, so it is safe to run every boot; x-systemd.growfs remains only as a fallback.
install -d -m0755 "$stage/usr/lib/repart.d"
cat >"$stage/usr/lib/repart.d/50-novadeck-home.conf" <<'REPART'
[Partition]
# Match the existing /home partition (Linux /home GUID) and grow it to claim free space at the end
# of the disk. No SizeMinBytes/SizeMaxBytes -> repart expands it to take everything available.
Type=home
REPART

install -d -m0755 "$stage/usr/lib/novadeck"
cat >"$stage/usr/lib/novadeck/grow-home.sh" <<'GROW'
#!/bin/sh
# novadeck first-boot grow: enlarge the /home partition to fill the device, THEN grow its ext4.
# Runs from novadeck-grow-home.service, ordered Before=home.mount, so the fs grow is a race-free
# offline resize2fs (partition already enlarged, /home not yet mounted) rather than the mount-time
# x-systemd.growfs that lost a race to home.mount and left the ext4 at the flashed ~1G. Idempotent.
set -eu

# /dev/novadeck/, NOT /dev/disk/by-label/: this script resolves the partition and then hands its
# PARENT DISK to systemd-repart, which writes the GPT. With two novadeck media attached, by-label
# names an arbitrary one, so the by-label version of this line could grow the internal install's
# home partition — and rewrite the internal disk's GPT — while booted off a card. The scoped link
# only ever names a partition on the disk we booted from (69-novadeck-bootdisk.rules).
HOME_DEV=/dev/novadeck/novadeck-home

# Wait for udev to publish the home partition's symlink. Even ordered After systemd-udev-trigger,
# the probe that creates the symlink is async, so settle the queue and then poll briefly. A card
# without a home partition (nofail / old 2-partition test image) never shows it, so time out after
# ~10s and no-op (x-systemd.growfs covers any fs at mount) rather than hang boot.
udevadm settle --timeout=30 2>/dev/null || true
i=0
while [ ! -b "$HOME_DEV" ] && [ "$i" -lt 50 ]; do
  sleep 0.2
  i=$((i + 1))
done
if [ ! -b "$HOME_DEV" ]; then
  echo "[novadeck-grow-home] no ${HOME_DEV} after settle — nothing to grow (x-systemd.growfs covers any fs)"
  exit 0
fi
HOME_PART=$(readlink -f "$HOME_DEV")

# 1. Grow the partition to fill the disk (systemd-repart, declarative via /usr/lib/repart.d). Pass the
#    parent DISK EXPLICITLY: with no device argument, repart auto-detects the disk from the ROOT fs,
#    which fails on our btrfs root (mounted as the pseudo-device /dev/root — no initramfs) with
#    "Cannot determine correct backing block device". That was the flaky red boot error ("Failed to
#    start ... grow of /home"); deriving the disk from the home partition sidesteps root entirely.
#    Non-fatal: log and press on to resize2fs rather than throwing a boot error if it ever fails.
DISK=$(lsblk -no pkname "$HOME_PART" 2>/dev/null | head -n1)
if [ -n "${DISK:-}" ] && [ -b "/dev/${DISK}" ]; then
  systemd-repart --dry-run=no "/dev/${DISK}" \
    || echo "[novadeck-grow-home] systemd-repart on /dev/${DISK} failed (non-fatal; resize2fs still runs)" >&2
else
  echo "[novadeck-grow-home] could not resolve parent disk of ${HOME_PART} — skipping partition grow" >&2
fi

# Let udev settle so the enlarged partition's size is current before resize2fs.
udevadm settle 2>/dev/null || true

# 2. Grow the ext4 to fill the (now enlarged) partition. No-op once it already fills it; non-fatal so
#    a not-cleanly-unmounted fs can't block boot (x-systemd.growfs is the fallback).
resize2fs "$HOME_PART" || echo "[novadeck-grow-home] resize2fs skipped/failed (non-fatal)" >&2
GROW
chmod 0755 "$stage/usr/lib/novadeck/grow-home.sh"

install -d -m0755 "$stage/usr/lib/systemd/system"
cat >"$stage/usr/lib/systemd/system/novadeck-grow-home.service" <<'UNIT'
[Unit]
Description=novadeck first-boot grow of /home to fill the storage device (systemd-repart + resize2fs)
Documentation=man:systemd-repart(8)
DefaultDependencies=no
ConditionDirectoryNotEmpty=/usr/lib/repart.d
# After systemd-udev-trigger (block coldplug), else the home partition's by-label symlink isn't
# published yet when we run and the grow no-ops (HW: grow-home ran 1s before "Found device" and
# bailed). Before home.mount (not just local-fs-pre.target): the ext4 resize must complete while
# /home is still unmounted, else it races the mount-time x-systemd.growfs (see grow-home.sh).
After=systemd-udevd.service systemd-udev-trigger.service
Before=home.mount local-fs-pre.target shutdown.target
Conflicts=shutdown.target

[Service]
Type=oneshot
RemainAfterExit=yes
# Wrapper: systemd-repart (grow partition) THEN resize2fs (grow ext4). 76/77 tolerance is inside it.
ExecStart=/usr/lib/novadeck/grow-home.sh

[Install]
WantedBy=sysinit.target
UNIT

# Enable on release: higher-priority preset (60 < 99 stock "disable *") + a build-time symlink
# fallback. The unit runs early (Before=local-fs-pre.target), pulled in via sysinit.target.
install -d -m0755 "$stage/usr/lib/systemd/system-preset"
echo "enable novadeck-grow-home.service" \
  >"$stage/usr/lib/systemd/system-preset/60-novadeck-storage.preset"
install -d -m0755 "$stage/etc/systemd/system/sysinit.target.wants"
ln -sf /usr/lib/systemd/system/novadeck-grow-home.service \
       "$stage/etc/systemd/system/sysinit.target.wants/novadeck-grow-home.service"

# Mask the stock systemd-repart.service. It's static but WantedBy=sysinit.target, so it also auto-runs
# in real-root boot and FAILS the same way our old unit did: with no device argument it can't resolve
# the btrfs /dev/root backing disk ("Cannot determine correct backing block device"), throwing a red
# "Failed to start Repartition Root Disk" every boot. novadeck-grow-home replaces it (explicit disk +
# resize2fs), so silence the duplicate. It STAYS masked now that the initramfs exists: the stock unit
# is initrd-only, and our initramfs is a plain shell script with no systemd in it to run the unit.
ln -sf /dev/null "$stage/etc/systemd/system/systemd-repart.service"
