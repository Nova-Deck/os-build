#!/usr/bin/env bash
# Offline verification of a BUILT installer medium — out/images/installer.img.
#
#   docker run --rm -v "$PWD":/src -w /src novadeck-build install/verify-image.sh
#   make verify-image
#
# Same doctrine as image/verify-card.sh: assert the ARTIFACT, not the source diff. The suites that
# run in `make test` read the SCRIPTS — tests/test-mkimage.sh greps mkimage.sh, test-mkroot.sh
# greps mkroot.sh — and a script that says the right thing while producing the wrong image passes
# both. This is the only thing that opens the image.
#
# WHY IT MATTERS MORE HERE THAN FOR A CARD. A card is flashed by someone holding the device, who
# finds out within a minute. This medium is downloaded by a stranger, booted on a handheld with no
# serial console, and asked to repartition the disk their Android install lives on. Its two failure
# modes are silent: a grub.cfg naming a PARTUUID the GPT does not carry (an unbootable medium, and
# the panel says nothing), and a root that boots fine and then cannot install — a missing tool, a
# Steam seed that does not match its pin, a dev medium published by accident.
#
# Everything here is unprivileged — read the GPT with sgdisk, the FAT with mtools, and the root with
# `unsquashfs -o <offset>`, which reads the squashfs straight out of the image at its partition
# offset. No loop mounts, no root, nothing mounted at all.
#
# EXIT 1 ON ANY FAILURE, and it prints every one rather than stopping at the first: the answer to
# "is this medium publishable" is the whole list, not the earliest item on it.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMG="${1:-$ROOT/out/images/installer.img}"
TABLE="$ROOT/install/medium-table.txt"
GENCFG="$ROOT/install/gen-grub-cfg.sh"
# A DEV medium bakes sshd with a root key and a Wi-Fi profile carrying a PSK. That is correct for the
# builder's own hardware and must never be published, so it FAILS here unless the caller says it is
# what they asked for — the same shape as ota/publish-bundle.sh's mode gate, which exists because a
# dev image signed with the real key is indistinguishable from a release one to every other check.
ALLOW_DEV="${NOVADECK_INSTALLER_ALLOW_DEV:-0}"

[ -f "$IMG" ] || { echo "no installer image: $IMG (run make installer)" >&2; exit 1; }
for t in sgdisk mdir mtype minfo unsquashfs; do
  command -v "$t" >/dev/null 2>&1 || { echo "$t not found — run inside novadeck-build" >&2; exit 1; }
done

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export MTOOLS_SKIP_CHECK=1
FAIL=0
ok()  { printf '    ok  %s\n' "$1"; }
bad() { printf '    !!  %s\n' "$1"; FAIL=1; }

field() { sgdisk -i "$1" "$IMG" | sed -n "s/^$2: \(.*\)/\1/p"; }
start() { field "$1" 'First sector' | sed 's/ .*//'; }
part_uuid() { field "$1" 'Partition unique GUID' | tr '[:upper:]' '[:lower:]'; }
part_name() { field "$1" 'Partition name' | tr -d "'"; }
part_type() { field "$1" 'Partition GUID code' | sed 's/ .*//'; }

echo "[novadeck] verifying ${IMG#"$ROOT"/}"

# ----------------------------------------------------------------------------------------------
echo "  1. the partition table"
# TWO PARTITIONS, NO MORE. The medium's whole shape argument is that it has one root and therefore
# no slot chooser (install/mkimage.sh's header): a third partition here means something laid the
# SHIPPED eight-partition table by mistake, which is a medium that cannot boot and a table that
# looks plausible in a photograph of gdisk.
n_parts=$(sgdisk -p "$IMG" | awk '/^Number/{f=1;next} f&&NF{n++} END{print n+0}')
[ "$n_parts" = 2 ] && ok "two partitions" \
  || bad "$n_parts partitions — this is not the medium's table (install/medium-table.txt has 2)"

# THE BOOT PARTITION IS 0700, NOT ef00, AND ONLY ON THIS MEDIUM. An ESP is hidden from users by
# Windows and macOS, and this partition is both where the operator writes wifi.conf and where the
# install log comes out. ABL boots by CONTENT, not by type GUID — measured against a working ROCKNIX
# card, which is `PTTYPE=dos` with an 0xc FAT32 partition and no EFI System Partition anywhere.
# Retyping it back to ef00 would make the medium's two operator-facing files invisible on the two
# operating systems most likely to be used to write them.
# sgdisk REPORTS THE GUID AND THE TABLE NAMES THE SHORT CODE, so the two have to be mapped rather
# than compared. Only the three that can appear on this medium are listed, and an unmapped code is a
# failure rather than a skip: a table row nobody translated here would otherwise verify as correct.
type_guid() {  # <sgdisk short code>
  case "$1" in
    0700) echo "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7" ;;  # Microsoft basic data — visible on Windows/macOS
    8300) echo "0FC63DAF-8483-4772-8E79-3D69D8477DE4" ;;  # Linux filesystem
    ef00) echo "C12A7328-F81F-11D2-BA4B-00A0C93EC93B" ;;  # EFI System — the one this medium must NOT use
    *)    echo "" ;;
  esac
}
check_type() {  # <partnum> <name in the table>
  local p="$1" row="$2" want got guid
  want=$(awk -v r="$row" '/^[[:space:]]*#/||/^[[:space:]]*$/{next} $1==r{print $3; exit}' "$TABLE")
  guid=$(type_guid "$want")
  got=$(part_type "$p")
  if [ -z "$guid" ]; then
    bad "the table gives p$p type '$want', which this script has no GUID for — add it"
  elif [ "${got^^}" = "$guid" ]; then
    ok "p$p is type $want ($got)"
  elif [ "$got" = "$(type_guid ef00)" ]; then
    bad "p$p is an EFI System Partition. Windows and macOS HIDE those, and this is the partition the
        operator writes wifi.conf to and reads the install log from. The table says $want."
  else
    bad "p$p is type $got, the table says $want ($guid)"
  fi
}
check_type 1 esp
check_type 2 root
[ "$(part_name 1)" = "$(awk '$1=="esp"{print $5}' "$TABLE")" ] \
  && ok "p1 is named $(part_name 1)" || bad "p1 is named '$(part_name 1)'"
[ "$(part_name 2)" = "$(awk '$1=="root"{print $5}' "$TABLE")" ] \
  && ok "p2 is named $(part_name 2)" || bad "p2 is named '$(part_name 2)'"

ESP_OFF=$(( $(start 1) * 512 ))
ROOT_OFF=$(( $(start 2) * 512 ))
ROOT_UUID=$(part_uuid 2)

# ----------------------------------------------------------------------------------------------
echo "  2. the boot partition"
minfo -i "$IMG@@$ESP_OFF" >"$T/minfo" 2>/dev/null \
  && ok "p1 is a readable FAT filesystem" || bad "p1 is not readable as FAT"
# THE FAT WIDTH MUST MATCH THE SECTOR SIZE, and a card can never show the failure: every removable
# medium is 512e, so a FAT12/16 laid here works on a card and fails on the 4Kn internal disk the
# same code path writes. -F 32 is forced in mkimage.sh; this is the assertion that it stayed.
grep -q 'FAT32' "$T/minfo" && ok "FAT32 (forced, not negotiated from the geometry)" \
  || bad "p1 is not FAT32: $(grep -i 'fat' "$T/minfo" | head -1)"
label=$(mlabel -i "$IMG@@$ESP_OFF" -s :: 2>/dev/null | sed 's/^ *Volume label is *//')
case "$label" in
  *NDINSTALLER*) ok "labelled NDINSTALLER — deliberately not a novadeck-* name, so /esp cannot collide with the TARGET's ESP" ;;
  *) bad "p1's label is '$label', not NDINSTALLER — install/units mounts it by LABEL" ;;
esac

# The byte ABL actually loads, and the three files the boot depends on.
for f in ::/EFI/BOOT/bootaa64.efi ::/EFI/steamos/grub.cfg ::/EFI/steamos/fonts/dejavu-mono.pf2 ::/Image; do
  mtype -i "$IMG@@$ESP_OFF" "$f" >/dev/null 2>&1 && ok "$f present" || bad "$f MISSING"
done
# No steamcl: it is the A/B slot chooser and this medium has one root, so its conf files would be
# fiction. A steamcl here means the card's ESP layout was copied onto a medium that cannot use it.
mtype -i "$IMG@@$ESP_OFF" ::/EFI/BOOT/steamcl.efi >/dev/null 2>&1 \
  && bad "steamcl.efi on a single-root medium — there is nothing for it to choose" \
  || ok "no steamcl (one root, no slot to choose)"
# NOTHING REMEMBERED. The medium travels between boards, so a saved board choice is a card that
# installed a Pocket S2 preselecting its devicetree on an ACE — and a wrong DTB is worse than
# re-picking.
mtype -i "$IMG@@$ESP_OFF" ::/EFI/steamos/grubenv >/dev/null 2>&1 \
  && bad "a grubenv is on the medium — it would remember a board choice between boards" \
  || ok "no grubenv (this medium remembers nothing)"
# The file the no-Wi-Fi screen tells the operator to copy. It told them to for weeks while no such
# file existed anywhere (HW 2026-08-24), which reads as a fault in the person following it.
mtype -i "$IMG@@$ESP_OFF" ::/novadeck/wifi.conf.example >"$T/wifi.example" 2>/dev/null \
  && ok "/novadeck/wifi.conf.example present, where the screen says to look" \
  || bad "the template the no-Wi-Fi screen names is not on the medium"
grep -q '^#*[[:space:]]*SSID=' "$T/wifi.example" 2>/dev/null && grep -q 'PSK=' "$T/wifi.example" \
  && ok "and it shows both keys install/netcfg parses" \
  || bad "the template does not show SSID= and PSK="

# ----------------------------------------------------------------------------------------------
echo "  3. the boot config addresses THIS image"
# THE SILENT BRICK. install/gen-grub-cfg.sh is handed the partition uuid sgdisk assigned moments
# earlier, so a mismatch here means the config was generated against a different image — a medium
# that reaches GRUB, times out on rootwait and sits at a black panel with nothing to read.
mtype -i "$IMG@@$ESP_OFF" ::/EFI/steamos/grub.cfg >"$T/grub.cfg" 2>/dev/null || true
grep -q "root=PARTUUID=$ROOT_UUID" "$T/grub.cfg" \
  && ok "root=PARTUUID=$ROOT_UUID matches p2's own GUID" \
  || bad "the config's root=PARTUUID is not p2's ($ROOT_UUID) — this medium would not find its root"
grep -q 'rootfstype=squashfs' "$T/grub.cfg" \
  && ok "rootfstype=squashfs" || bad "the kernel is not told the root is a squashfs"
grep -q 'systemd.volatile=state' "$T/grub.cfg" \
  && ok "systemd.volatile=state (a tmpfs /var over the read-only root)" \
  || bad "no systemd.volatile=state — journald and NetworkManager have nowhere to write"
# Every menuentry names a dtb, and every one of those has to be ON the medium. A missing dtb is a
# board that picks itself out of the menu and then fails to boot, on the tool someone reaches for
# when their device is already broken.
entries=$(grep -c '^menuentry ' "$T/grub.cfg")
[ "$entries" -gt 0 ] && ok "$entries board entries" || bad "the config has no menu entries"
missing=""
while read -r dtb; do
  mtype -i "$IMG@@$ESP_OFF" "::/dtbs/$dtb" >/dev/null 2>&1 || missing="$missing $dtb"
done < <(sed -n 's|^[[:space:]]*devicetree /dtbs/\(.*\)$|\1|p' "$T/grub.cfg" | sort -u)
[ -z "$missing" ] && ok "every devicetree the menu names is on the medium" \
  || bad "the menu names dtbs that are not there:$missing"

# ----------------------------------------------------------------------------------------------
echo "  4. the root filesystem"
# `-o` reads the squashfs at its offset inside the image, so nothing is extracted, mounted or copied.
sqfs() { unsquashfs -o "$ROOT_OFF" -q -cat "$IMG" "$1" 2>/dev/null; }
unsquashfs -o "$ROOT_OFF" -s "$IMG" >"$T/sqfs" 2>/dev/null \
  && ok "p2 is a squashfs" || bad "p2 does not read as a squashfs at offset $ROOT_OFF"
grep -q 'zstd' "$T/sqfs" && ok "compressed with zstd (the kernel has CONFIG_SQUASHFS_ZSTD=y)" \
  || bad "the root is not zstd-compressed: $(grep -i compression "$T/sqfs" | head -1)"

sqfs etc/os-release >"$T/os-release"
grep -qx 'ID=novadeck-installer' "$T/os-release" \
  && ok "the root identifies as novadeck-installer, not as an install of the thing it installs" \
  || bad "etc/os-release does not say ID=novadeck-installer"

# ----------------------------------------------------------------------------------------------
echo "  5. identity"
# Until install/mkimage.sh started stamping one, every medium ever built answered "which image is
# this" identically — and that is the first question asked at the fallback console, which exists for
# the moment something has already gone wrong.
sqfs etc/novadeck-release >"$T/release"
for f in NOVADECK_VARIANT NOVADECK_BUILD NOVADECK_VERSION NOVADECK_GIT NOVADECK_MODE; do
  grep -q "^$f=" "$T/release" && ok "$f=$(sed -n "s/^$f=//p" "$T/release")" \
    || bad "/etc/novadeck-release carries no $f"
done
# The same fields under the names other software reads. os-release(5) is where anything that is not
# ours looks, and shipping it blank is how the main image's Settings screen once rendered empty.
for f in VERSION_ID BUILD_ID VARIANT_ID; do
  grep -q "^$f=" "$T/os-release" && ok "os-release carries $f" \
    || bad "os-release carries no $f — the stamp did not reach it"
done
# The two must agree, because they are written from the same values in one place and a divergence
# means something re-derived one of them.
r_ver=$(sed -n 's/^NOVADECK_VERSION=//p' "$T/release")
o_ver=$(sed -n 's/^VERSION_ID=//p' "$T/os-release")
[ -n "$r_ver" ] && [ "$r_ver" = "$o_ver" ] \
  && ok "novadeck-release and os-release name the same version ($r_ver)" \
  || bad "version mismatch: novadeck-release says '$r_ver', os-release says '$o_ver'"
# The sidecar a publisher reads instead of opening a squashfs out of the middle of a GPT.
side="$(dirname "$IMG")/installer.release"
if [ -f "$side" ]; then
  cmp -s "$side" "$T/release" \
    && ok "installer.release beside the image is byte-identical to the one inside it" \
    || bad "installer.release does not match the image's own /etc/novadeck-release"
else
  bad "no installer.release sidecar beside the image"
fi

mode=$(sed -n 's/^NOVADECK_MODE=//p' "$T/release")
if [ "$mode" = release ]; then
  ok "mode: release"
elif [ "$ALLOW_DEV" = 1 ]; then
  ok "mode: dev (NOVADECK_INSTALLER_ALLOW_DEV=1 — sshd and a baked Wi-Fi PSK are on this medium)"
else
  bad "mode: dev — this medium carries an authorized_keys and a Wi-Fi PSK. Rebuild without
        NOVADECK_DEV, or pass NOVADECK_INSTALLER_ALLOW_DEV=1 if a dev medium is what you asked for."
fi

# ----------------------------------------------------------------------------------------------
echo "  6. it can actually install"
# A MEDIUM THAT BOOTS AND CANNOT INSTALL is the failure this section exists for. Everything below
# is resolved by ABSOLUTE PATH at runtime, where a miss is a screen or a `die` rather than a build
# error, so nothing earlier fails loudly for any of it — the image is produced happily and the
# operator finds out on hardware.
#
# THE DISK IS NOT AT RISK FROM ANY OF IT. The spine verifies sources BEFORE take_consent and
# therefore before the first sgdisk (plan §3 rule 11), so a medium that is missing something stops
# with Android intact. That is the point of checking here anyway: the cost is a wasted trip to the
# hardware, not a wasted device — and for the seed it is a ~2 GiB download per person who tries.
#
# THE LIST IS STATED HERE, not read out of install/mkroot.sh: a verifier that derives its
# expectations from the builder can only ever agree with it. tests/test-mkimage.sh asserts the
# other direction — that everything mkroot ships is named here — so a new file on the medium cannot
# quietly go unchecked.
for f in novadeck-install carve.sh select-target.sh rauc-session.sh post-install-fresh.sh \
         verify-install.sh netcfg release-info \
         ui uiflow.py uipad.py uiview.py confirm-ui confirm-tty installer-session save-log.sh \
         lib-slotwrite.sh genpart.sh partition-table.txt lib-gpt.sh lib-homestage.sh; do
  sqfs "usr/lib/novadeck/install/$f" >/dev/null 2>&1 \
    && ok "install/$f" || bad "usr/lib/novadeck/install/$f is MISSING"
done
# The consent gate's fixed path. $CONFIRM names WHO renders, and the spine dies rather than
# installing if it cannot run one.
sqfs usr/lib/novadeck/install/confirm >/dev/null 2>&1 \
  && ok "the confirm symlink the gate's fixed path names" \
  || bad "no usr/lib/novadeck/install/confirm — the spine cannot take consent"
# THE STEAM SEED, AND ITS PIN, AND THAT THEY AGREE. The medium carries the tree /home is built
# from, so this is the one check that can be made completely: extract the file from the squashfs,
# hash it, and compare against the sha256 staged beside it — exactly what the spine does on the
# device, before consent. A medium that fails here would carve a disk and then refuse.
#
# AND THAT IT IS A STEAM TREE, not merely self-consistent bytes. The pin is computed by mkimage from
# the file it stages, so a pin and its seed agree BY CONSTRUCTION -- point NOVADECK_SEED_TARBALL at
# the wrong file and the medium carries a perfectly self-consistent non-seed. Nothing downstream
# catches it either: the spine hashes it before consent, the hash matches, the disk is carved, and
# the install dies at seed_home AFTER the point of no return. That is exactly the window the
# pre-consent verification exists to close. steam-seed/pack-seed.sh makes this check on its own
# output; this is the one that looks at what actually landed on the medium.
#
# It reads ~1.4 GiB out of the image to do it, and the listing rides along in the same pass: the
# bytes are already streaming past to be hashed. Nothing else between this and a stranger's /home
# looks at them at all, because the seed carries no signature.
if unsquashfs -o "$ROOT_OFF" -q -cat "$IMG" usr/lib/novadeck/install/steam-seed.sha256 >"$T/pin" 2>/dev/null \
   && [ -s "$T/pin" ]; then
  pin=$(tr -d '[:space:]' <"$T/pin")
  if [ "${#pin}" -eq 64 ]; then
    ok "a 64-character Steam-seed pin is staged"
    # tee, so one decompress feeds both the hash and the listing. `zstd -dc | tar -t` reads the
    # archive without unpacking 3.3 GB of it.
    got=$(unsquashfs -o "$ROOT_OFF" -q -cat "$IMG" usr/lib/novadeck/install/steam-seed.tar.zst 2>/dev/null \
          | tee >(zstd -dc 2>/dev/null | tar -tf - >"$T/seed.list" 2>/dev/null) \
          | sha256sum | cut -d' ' -f1)
    if [ "$got" = "$pin" ]; then
      ok "and the seed on the medium hashes to it — /home can actually be built from this image"
      # The two files stage_deck_home's output is useless without. `.installed` is what stops Steam
      # re-installing itself over the user's network on first boot, which is the whole point of the
      # offline bake.
      if grep -qx './steamrtarm64/steamui.so' "$T/seed.list" 2>/dev/null; then
        ok "and it IS the Steam tree ($(wc -l <"$T/seed.list") entries), not just bytes that agree with a hash"
      else
        bad "THE SEED IS NOT A STEAM TREE. It hashes to its pin — which proves nothing, since mkimage
        computes the pin from whatever it was given — but carries no ./steamrtarm64/steamui.so.
        A medium like this passes 'verify sources', CARVES THE DISK, and then fails at seed_home.
        Rebuild with a real out/steam-seed/steam-seed.tar.zst (make steam-seed-artifact)."
      fi
      grep -q '^\./package/.*\.installed$' "$T/seed.list" 2>/dev/null \
        && ok "with the completeness marker, so first boot needs no self-heal over the user's network" \
        || bad "the seed carries no package/*.installed — this /home would re-install Steam on first boot"
    else
      bad "THE SEED DOES NOT MATCH ITS PIN. staged: $pin
        actual: ${got:-<no seed on the medium>}
        The spine checks this before consent, so the medium refuses rather than half-installing —
        but it is a medium that cannot install at all. Rebuild it."
    fi
  else
    bad "the staged seed pin is not a sha256: '$pin'"
  fi
else
  bad "NO STEAM SEED PIN. This medium carries no Steam tree to build /home from: it boots, reaches
        pre-flight and stops at 'verify sources' before consent. Build it with
        'make steam-seed-artifact' available (make installer does that for you)."
fi
# The session unit has to be ENABLED, and the console unit must NOT be: the second is started by
# OnFailure= and enabling it would put a getty on the panel beside the installer.
#
# /etc, not /usr/lib: install/mkroot.sh makes the wants symlink where `systemctl enable` would, and
# this image's /etc is inside the squashfs (read-only, with writers redirected to /run at runtime).
# A unit FILE under /usr/lib/systemd/system is installed, not enabled — checking there would report
# every medium as enabled, including one that boots to nothing.
#
# LISTED ONCE INTO A FILE, and the greps read the FILE. `unsquashfs -l | grep -q` is a pipeline, and
# under this script's `set -o pipefail` grep -q exits at the first match, SIGPIPEs unsquashfs, and
# the pipeline reports 141 — a MATCH read as a failure. Measured here on a medium that really did
# have the symlink; install/netcfg carries the same warning for the same reason.
unsquashfs -o "$ROOT_OFF" -l "$IMG" >"$T/list" 2>/dev/null || true
enabled() { grep -qx "squashfs-root/etc/systemd/system/multi-user.target.wants/$1" "$T/list"; }
enabled novadeck-installer.service \
  && ok "novadeck-installer.service is enabled" \
  || bad "novadeck-installer.service is not enabled — the medium boots to nothing"
enabled novadeck-installer-console.service \
  && bad "the console unit is enabled — it is the OnFailure= fallback, not a second session" \
  || ok "the console fallback is not enabled (it is activated by failure)"
# The device registry both the pre-flight screen and the session derive from. Both fall back if it
# is absent, and the fallback is a generic 1920x1080 panel calling itself "this device" — the kind
# of degradation nobody notices until a user reports it.
sqfs usr/lib/novadeck/device-env >/dev/null 2>&1 \
  && ok "device-env (the board registry the screen and the session read)" \
  || bad "no usr/lib/novadeck/device-env — every board would draw a generic output"

echo
if [ "$FAIL" = 0 ]; then
  echo "[novadeck] installer image OK: ${IMG#"$ROOT"/}"
else
  echo "[novadeck] installer image FAILED verification: ${IMG#"$ROOT"/}" >&2
fi
exit "$FAIL"
