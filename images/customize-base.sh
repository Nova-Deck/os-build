#!/usr/bin/env bash
# novadeck base customization — install the RELEASE runtime into the aarch64 base.
#
# The upstream holo-core base is minimal: no Wi-Fi supplicant, no SSH server, no
# Vulkan/Mesa userspace. This layers the runtime that ships in every build —
#   networkmanager   Wi-Fi manager (release + test); does its own DHCP
#   wpa_supplicant   NM's Wi-Fi WPA backend (optdepend of networkmanager, so installed explicitly)
#   bluez/bluez-utils Bluetooth stack + bluetoothctl (Deck UI pairs controllers/audio)
#   openssh          SSH server (dropbear isn't in the pinned holo repo)
#   wireless-regdb   regulatory database — REQUIRED for 5 GHz (else channels are no-TX)
#   mesa + vulkan-freedreno (Turnip) + vulkan-tools   GPU / Vulkan
# Runtime deps of precompiled packages (e.g. libiio for InputPlumber) are NOT hardcoded here —
# each packages/<name>/prebuilt.pin declares its own `deps:`, aggregated into the install list.
# — by running the pinned base under arm64 emulation and pacman-installing from the
# holo repo, then exporting the augmented rootfs to work/base/ (the directory
# images/assemble-rootfs.sh consumes).
#
# Components NOT in the holo repo (e.g. InputPlumber, the handheld input daemon) ship as
# precompiled-package PINS: each packages/<name>/prebuilt.pin declares a tarball by
# url + sha256 (+ tar strip-components). They are fetched + verified on the host and
# extracted into the base here; add one by dropping a new pin file — no code change.
# Per-component config / service enablement (if any) is injected later by assemble-rootfs.sh.
#
# This installs PACKAGES only — it writes NO network/SSH config and enables NO services.
# First-boot networking is the SteamOS UI's responsibility on release. All Wi-Fi/SSH
# scaffolding (.link/.network, regdom, wpa creds, sshd + host keys, enable-symlinks) is a
# TEST-ONLY injection done later by assemble-rootfs.sh under NOVADECK_TEST=1 (see it).
#
# Unlike fetch-base.sh (a file copy, no qemu), this EXECUTES arm64 userspace, so it
# needs qemu binfmt — registered on demand via tonistiigi/binfmt. Network required.
#
#   images/customize-base.sh
#
# Prints the exported rootfs path on stdout (like fetch-base.sh). FORCE=1 re-runs.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PINFILE="$ROOT/base.digest"
DEST="$ROOT/work/base"

# Release runtime packages — credentials are NEVER installed here (test-only at assemble).
# gamescope + seatd are the Deck-UI session compositor (SteamOS layer B) and its seat manager:
# Phase 2 brings up BARE gamescope on Turnip before the jupiter-* port to isolate the
# Turnip↔gamescope Wayland-WSI question (see docs/bringup-phase2.md). Both are genuine
# release runtime (the gamescope session needs them), not test-only.
# bluez + bluez-utils are the Bluetooth stack (layer C): the Deck UI pairs controllers/audio over
# org.bluez, and the WCN7850 BT firmware already ships (assemble-rootfs.sh block 3b). bluetoothd is
# enabled in the hw-support overlay (60-novadeck-bluetooth.preset); bluez-utils provides bluetoothctl.
# networkmanager is the Wi-Fi manager (the SteamOS gamepadui default; uses wpa_supplicant as its
# backend, already present). NM ships no auto-enable preset, so installing it here leaves it INACTIVE
# in a plain release base — release first-boot networking is the Steam UI's job (Phase-3), which
# drives NM. The TEST card (assemble-rootfs.sh NOVADECK_TEST block) DOES enable NM and drops a
# connection profile, so the throwaway card exercises the same manager as release (no test-vs-release
# stack split). bluez/networkmanager being added busts the install-set reuse marker — intended.
# Audio (SteamOS layer C): PipeWire stack + ALSA UCM2 base. alsa-ucm-conf supplies the
# /codecs/{wcd939x,qcom-lpass,wsa884x} + /lib snippets that the device UCM2 profiles
# (audio/ overlay, cards SM8650-APS2/SM8650-KPF) Include; pipewire-pulse/-alsa give the
# PA/ALSA shims so games + BlueZ (A2DP/HFP) route through PipeWire, wireplumber is the
# session manager. (pipewire-jack omitted — not needed for game/BT audio.)
# unzip: Steam's own first-launch self-update unpacks .zip payloads in /home (the pre-seeded client
# is UI-incomplete and updates itself). curl/tar/xz are already in the base.
# openal: a HOST system lib the native arm64 Steam client links (libopenal.so.1); it IS in the holo
# repo, so install it.
# gtk2: steamui.so links libgtk-x11-2.0.so.0. holo has NO gtk2 (SteamOS itself ships none — verified
# against the SteamOS 3.8.10 rootfs), so we BUILD it from source as a novadeck overlay package
# (packages/gtk2/) and install it HERE from that overlay — the client resolves its UI libs against
# the host base, NOT from inside Steam's bundled SR3 runtime via pressure-vessel as earlier planned.
# gtk2's own deps (gdk-pixbuf2, pango, cairo, …) come along via pacman. (No distro gtk2 package
# exists in holo, so we build from source rather than pulling one.) See packages/gtk2/.
# ffmpeg: the native arm64 Steam client links libav*/libsw* (libavcodec, libavformat, libswscale,
# libswresample) for in-client media/video (store trailers, intro/animated UI). It IS in the holo
# repo, so install it.
# xorg-xwayland: x86 games run under FEX/Proton render through Xwayland inside gamescope (the Deck
# shell is native Wayland, but most Proton titles are X11 clients).
# e2fsprogs: the deck user's /home is a dedicated ext4 partition grown to fill the card on first
# boot (novadeck-grow-home) — resize2fs (+ e2fsck) come from here; sfdisk/partx are in util-linux.
# lsof: the native Steam client's WebUITransport authenticates the loopback websocket from
# steamwebhelper by shelling out to `lsof` to verify the connecting peer's pid/uid. Without it
# GetIPCConnectionDetails fails (exit 127) and steam REJECTS every GamepadUI connection, so the UI
# never binds to the client and renders the 0x3008 "trouble connecting" error (a black panel + popup).
# noto-fonts(+cjk+emoji): the GamepadUI renders text through CEF/fontconfig, NOT only Steam's bundled
# fonts. The base drags in just adwaita-fonts (Latin), so every non-Latin language name on the
# first-boot language-selection screen (简体中文, 日本語, 한국어, Русский, العربية, …) renders as tofu —
# only "English" is readable. Noto gives broad Unicode coverage (noto-fonts: Latin/Cyrillic/Greek/
# Arabic/Thai/…; -cjk: CJK; -emoji: UI emoji), matching SteamOS's font set.
# sddm: the display manager that autologins the deck user into the gamescope shell, giving it a real
# ACTIVE seat0 logind session (SteamOS parity) so stock polkit (allow_active / subject.active
# && wheel) authorizes Wi-Fi + timezone — no "no-active" bypass rule. NOT in the holo repos, so it is
# built from source into the [novadeck] overlay (packages/sddm) and resolves here. The `sddm` system
# user it needs is baked below (the RO root can't run systemd-sysusers at boot to persist /etc/passwd).
# mangohud: the Deck-style FPS/perf overlay, spawned by gamescope's --mangoapp (session/usr/bin/
# novadeck-session passes it) and toggled by SteamUI's Performance settings. NOT cosmetic — the Steam
# client prepends `mangohud` to every game launch command when the Quick-Access perf overlay is on, so
# with no mangohud on the image toggling it CRASHES the launch (HW 2026-07-07). NOT in the holo repos
# (no mango* in the synced core/extra dbs), so it is built from source into the [novadeck] overlay
# (packages/mangohud, with the Qualcomm/Adreno GPU+battery patches) and resolves here.
# python: the interpreter behind our shipped #!/usr/bin/env python3 tools — proton-wrapper (per-game
# FEX tuning, on every Windows-game launch) and proton-unlock (registers user-downloaded arm64 Proton).
# It arrives transitively today, but a launch failing at the shebang would be silent, so declare it.
# python-gobject: PyGObject (the `gi` bindings) for novadeck-powerd + novadeck-steamos-manager, the
# GLib/Gio D-Bus daemons behind SteamUI's Performance/GPU sliders and the fan curve. Without it both
# services fail on import at boot.
# scx-scheds: the sched_ext userspace schedulers (scx_lavd, scx_bpfland, scx_rusty). scx_lavd is the
# gaming-oriented one — latency-critical tasks get priority, which is the point on a handheld. Needs
# the kernel half (CONFIG_SCHED_CLASS_EXT + BTF, kernel/kernel.config). NOT in the holo repos, so it
# is built from source into the [novadeck] overlay (packages/scx-scheds) and resolves here. Installing
# it only PLACES the binaries + scx.service; nothing selects a scheduler yet, so the kernel keeps
# running EEVDF until something enables the unit or launches a scheduler by hand.
PKGS=(wpa_supplicant wireless-regdb openssh vulkan-icd-loader vulkan-freedreno vulkan-tools mesa gamescope seatd sddm mangohud fex-emu bluez bluez-utils networkmanager alsa-ucm-conf pipewire wireplumber pipewire-pulse pipewire-alsa unzip openal gtk2 ffmpeg e2fsprogs xorg-xwayland lsof noto-fonts noto-fonts-cjk noto-fonts-emoji python python-gobject scx-scheds)

# Test-only packages — installed ONLY under NOVADECK_TEST=1, NEVER in a release base.
# On-device bring-up tools: evtest reads raw /dev/input events; usbutils provides lsusb.
TEST_PKGS=(evtest usbutils)

# Precompiled external packages: every packages/<name>/prebuilt.pin (url + sha256 + strip)
# is fetched on the host and extracted into the base. PREBUILT_DIR stages the verified
# tarballs + a manifest; the manifest is also stored in the base as the reuse cache key.
PREBUILT_DIR="$ROOT/work/prebuilt"
# Persistent pacman package cache. The emulated `pacman -Sy` downloads all runtime packages from
# the holo mirror on every base rebuild (a new prebuilt busts the reuse cache even when the package
# SET is unchanged), and that mirror intermittently truncates a transfer. Bind-mounting a host
# cache into /var/cache/pacman/pkg lets a retry reuse the packages that DID land and re-fetch only
# the truncated one, instead of re-rolling the whole 267-package download. It PERSISTS across runs
# like PREBUILT_DIR; docker export excludes bind-mounts, so cached packages never bloat the base
# (which is also why the in-container `pacman -Scc` is dropped — it would only wipe this cache).
PACMAN_CACHE="$ROOT/work/pacman-cache"
mkdir -p "$PACMAN_CACHE"
PREBUILT_PINS=("$ROOT"/packages/*/prebuilt.pin)
pin_field() { sed -n "s/^$2:[[:space:]]*//p" "$1" | head -1; }
# One row per pin, sorted: `name sha256 strip kind dest deps...`. It identifies exactly which
# prebuilts a base carries AND the holo-repo runtime deps they declare, so a deps change also
# busts the reuse cache. The container re-reads this file as its placement list.
#
# `deps` stays LAST because it is the only space-separated (multi-token) field; everything the
# container splits positionally must precede it. `dest` uses '-' rather than an empty field so a
# pin without one cannot shift the columns. The container captures trailing deps tokens into a
# throwaway var (see the placement loop) — they are pacman-installed via INSTALL_PKGS instead.
prebuilt_manifest() {
  local pin kind dest strip
  for pin in "${PREBUILT_PINS[@]}"; do
    [ -e "$pin" ] || continue
    kind="$(pin_field "$pin" kind)";   kind="${kind:-tar}"
    dest="$(pin_field "$pin" dest)";   dest="${dest:--}"
    strip="$(pin_field "$pin" strip)"; strip="${strip:-0}"
    printf '%s %s %s %s %s %s\n' "$(pin_field "$pin" name)" "$(pin_field "$pin" sha256)" \
                                 "$strip" "$kind" "$dest" "$(pin_field "$pin" deps)"
  done | sort
}
EXPECTED_MANIFEST="$(prebuilt_manifest)"

# Aggregate the holo-repo runtime deps each prebuilt declares (deps: in its pin). They ship in
# every base that carries the prebuilt (release), so they extend the release install list —
# e.g. InputPlumber links libiio.so.0, declared `deps: libiio` in its pin, not hardcoded above.
PREBUILT_DEPS=()
for pin in "${PREBUILT_PINS[@]}"; do
  [ -e "$pin" ] || continue
  pin_deps="$(pin_field "$pin" deps)"
  if [ -n "$pin_deps" ]; then PREBUILT_DEPS+=($pin_deps); fi   # word-split: deps is space-separated
done

# The reuse cache must bust whenever the installed package SET changes — a new release
# package, a new prebuilt's declared deps, or the test-only packages toggling in/out. Probing
# for one sentinel file per package doesn't scale (and silently misses any package without a
# sentinel), so instead record the whole sorted install set in ONE marker file
# (/usr/lib/novadeck/pkgs) and compare it. prebuilt.manifest stays a SEPARATE marker because
# the container also reads it verbatim as the tar-extraction list, so it must hold only
# prebuilt rows.
INSTALL_PKGS=("${PKGS[@]}" "${PREBUILT_DEPS[@]}")
if [ "${NOVADECK_TEST:-}" = "1" ]; then
  INSTALL_PKGS+=("${TEST_PKGS[@]}")
fi
# Canonical (sorted, de-duped) install set — the reuse-cache key recorded in the base below.
EXPECTED_PKGS="$(printf '%s\n' "${INSTALL_PKGS[@]}" | sort -u)"

# From-source overlay packages (packages/*/source.pin -> work/repo/<arch>/, built by
# packages/build-overlay.sh) override holo binaries via a higher pkgrel. They don't change the
# install SET, so fold the repo db's content hash into the reuse key — a rebuilt overlay (new
# pkgrel/patch) then busts the cache even though PKGS is unchanged.
# Arch-scoped (aarch64), shared across SoCs — overlay packages are plain aarch64 binaries every
# device reuses, so they are NOT under work/base/. See packages/build-overlay.sh.
OVERLAY_REPO="$ROOT/work/repo/aarch64"
OVERLAY_DB="$OVERLAY_REPO/novadeck.db.tar.zst"
if [ -f "$OVERLAY_DB" ]; then
  EXPECTED_PKGS="$EXPECTED_PKGS
overlay:$(sha256sum "$OVERLAY_DB" | cut -d' ' -f1)"
fi

[ -f "$PINFILE" ] || { echo "no base pin: $PINFILE" >&2; exit 1; }
# Pin = last non-comment, non-blank line: an image ref ending in @sha256:<digest>.
REF="$(grep -vE '^[[:space:]]*(#|$)' "$PINFILE" | tail -1)"
case "$REF" in
  *@sha256:*) ;;
  *) echo "refusing unpinned base ref (need ...@sha256:<digest>): '$REF'" >&2; exit 1 ;;
esac
command -v docker >/dev/null 2>&1 || { echo "docker required for base customization" >&2; exit 1; }

# Already customized? Reuse unless FORCE=1 (the emulated pacman run is slow). Both markers must
# match the current inputs, else a package add/removal or a prebuilt pin bump would be silently
# missed. The pkgs marker is written last in-container, so its presence also proves the
# customization completed (no need for per-package existence sentinels).
if [ -z "${FORCE:-}" ] \
   && [ "$(cat "$DEST/usr/lib/novadeck/pkgs" 2>/dev/null)" = "$EXPECTED_PKGS" ] \
   && [ "$(cat "$DEST/usr/lib/novadeck/prebuilt.manifest" 2>/dev/null)" = "$EXPECTED_MANIFEST" ]; then
  echo "[novadeck] customized base present: ${DEST#"$ROOT"/} (FORCE=1 to rebuild)" >&2
  echo "$DEST"; exit 0
fi

echo "[novadeck] pulling pinned base: $REF" >&2
docker pull "$REF" >&2

# Ensure arm64 binfmt is registered so the base's own pacman runs under emulation.
if ! docker run --rm --platform linux/arm64 "$REF" /usr/bin/true >/dev/null 2>&1; then
  echo "[novadeck] registering arm64 binfmt (qemu) via tonistiigi/binfmt" >&2
  docker run --privileged --rm tonistiigi/binfmt --install arm64 >&2
fi

# Fetch + verify every pinned prebuilt on the host (network here); staged into PREBUILT_DIR,
# mounted read-only into the customization container below so they land in the exported base.
#
# PREBUILT_DIR PERSISTS across runs (it is NOT wiped) so it doubles as the download cache: a
# re-customize — the base cache busts on any package/overlay change — reuses a staged blob whose
# sha still matches instead of re-fetching it. The FEX ArchLinux.ero alone is ~1.9G, so this saves
# that download on every rebuild. The staged name is per-pin (fex-rootfs.blob), so a pin bump
# re-verifies against the NEW sha, misses, and overwrites in place — no orphans, no unbounded growth.
mkdir -p "$PREBUILT_DIR"
for pin in "${PREBUILT_PINS[@]}"; do
  [ -e "$pin" ] || continue
  name="$(pin_field "$pin" name)"; ver="$(pin_field "$pin" version)"
  url="$(pin_field "$pin" url)";  sha="$(pin_field "$pin" sha256)"
  kind="$(pin_field "$pin" kind)"; kind="${kind:-tar}"
  : "${name:?$pin: missing name}"; : "${url:?$pin: missing url}"; : "${sha:?$pin: missing sha256}"
  # `.blob` for a raw file (copied verbatim), `.tar` for an archive (tar autodetects gz/xz/zst).
  case "$kind" in
    tar)  staged="$PREBUILT_DIR/$name.tar" ;;
    file) staged="$PREBUILT_DIR/$name.blob" ;;
    *)    echo "$pin: unknown kind '$kind' (want: tar|file)" >&2; exit 1 ;;
  esac
  # Reuse a cached blob only if its sha already matches the pin (guards against a partial download
  # or a bumped url reusing the old file); otherwise (re)fetch and verify.
  if [ -f "$staged" ] && echo "$sha  $staged" | sha256sum -c --status -; then
    echo "[novadeck] prebuilt $name $ver ($kind): cached ($url)" >&2
    continue
  fi
  echo "[novadeck] fetching prebuilt $name $ver ($kind): $url" >&2
  curl -fsSL "$url" -o "$staged.part"
  echo "$sha  $staged.part" | sha256sum -c - \
    || { echo "$name sha256 mismatch — refusing" >&2; rm -f "$staged.part"; exit 1; }
  mv -f "$staged.part" "$staged"
done
printf '%s\n' "$EXPECTED_MANIFEST" >"$PREBUILT_DIR/prebuilt.manifest"
# Install-set marker (reuse-cache key only; NOT a tar list) — the full sorted package set.
printf '%s\n' "$EXPECTED_PKGS" >"$PREBUILT_DIR/pkgs"

cid="nova-custom-$$"
trap 'docker rm -f "$cid" >/dev/null 2>&1 || true' EXIT

# Mount the from-source overlay repo (if built) read-only so the in-container pacman can install
# our patched packages from it. `pacman -S` resolves a package from the FIRST repo in pacman.conf
# ORDER that provides it (version does NOT override order), so the overlay must be inserted AHEAD
# of the holo repos; the higher pkgrel (e.g. 3.16.17-1.1) then also keeps it across any upgrade.
OVERLAY_MOUNT=()
if [ -f "$OVERLAY_DB" ] && ls "$OVERLAY_REPO"/*.pkg.tar.zst >/dev/null 2>&1; then
  OVERLAY_MOUNT=(-v "$OVERLAY_REPO":/novarepo:ro)
  echo "[novadeck] overlay repo present — patched packages will override holo binaries" >&2
fi

echo "[novadeck] installing runtime under arm64: ${INSTALL_PKGS[*]}" >&2
docker run --name "$cid" --platform linux/arm64 -v "$PREBUILT_DIR":/prebuilt:ro \
  -v "$PACMAN_CACHE":/var/cache/pacman/pkg \
  "${OVERLAY_MOUNT[@]}" "$REF" \
  bash -euo pipefail -c '
  # novadeck overlay: register our local pacman repo AHEAD of the holo repos (right after the
  # [options] section) so patched from-source packages (e.g. gamescope rebuilt for the portrait-
  # panel composite rotation) resolve from it instead of the holo binaries — pacman -S honours
  # repo ORDER, not version. Unsigned (TrustAll): it is our own pinned build artifact.
  if [ -d /novarepo ] && ls /novarepo/*.pkg.tar.zst >/dev/null 2>&1; then
    awk "
      /^\[/ && seen && !ins { print \"[novadeck]\"; print \"SigLevel = Optional TrustAll\"; print \"Server = file:///novarepo\"; print \"\"; ins=1 }
      /^\[options\]/ { seen=1 }
      { print }
    " /etc/pacman.conf > /etc/pacman.conf.nova && mv /etc/pacman.conf.nova /etc/pacman.conf
  fi
  pacman -Sy --noconfirm --needed --disable-download-timeout '"${INSTALL_PKGS[*]}"'

  # Compile the en_US.UTF-8 locale. The holo base ships /etc/locale.conf with
  # LANG=en_US.UTF-8 and /etc/locale.gen with that entry uncommented, but never runs
  # locale-gen — so /usr/lib/locale holds only C.utf8 and anything honouring LANG
  # (native Steam, CEF, games) silently falls back to C. Ensure the entry then compile
  # it into the RO root now. (Arch equivalent of Fedora glibc-langpack-en; not a
  # pressure-vessel need here — pressure-vessel is dropped, we launch raw on host.)
  grep -q "^en_US.UTF-8 UTF-8" /etc/locale.gen || echo "en_US.UTF-8 UTF-8" >>/etc/locale.gen
  locale-gen

  # Precompiled external packages staged + verified by the host (packages/*/prebuilt.pin):
  # place each into the rootfs, then record the manifest in the base so the host reuse-check
  # detects pin changes.
  #   kind=tar  -> extract with the pin'"'"'s strip-components into `dest` (default /). Archive roots
  #                differ, so strip is per-package (InputPlumber is rooted at inputplumber/usr ->
  #                strip 1 lands at /usr; Proton strips its versioned dir into a stable name).
  #   kind=file -> copy verbatim to `dest`, which is the full destination FILE path (the FEX
  #                guest rootfs is a raw erofs image, not an archive).
  if [ -s /prebuilt/prebuilt.manifest ]; then
    while read -r p_name p_sha p_strip p_kind p_dest p_deps; do
      [ -n "$p_name" ] || continue
      : "${p_deps:-}"  # deps are pacman-installed via the host INSTALL_PKGS list, not here
      # NB: `[ ... ] && x=y` would return 1 on a no-op and kill this `set -e` script.
      if [ "$p_dest" = "-" ]; then p_dest=/; fi
      case "${p_kind:-tar}" in
        tar)
          mkdir -p "$p_dest"
          tar -C "$p_dest" --strip-components="${p_strip:-0}" -xf "/prebuilt/$p_name.tar"
          ;;
        file)
          install -Dm0644 "/prebuilt/$p_name.blob" "$p_dest"
          ;;
        *)
          echo "prebuilt $p_name: unknown kind ${p_kind}" >&2; exit 1
          ;;
      esac
    done < /prebuilt/prebuilt.manifest
    install -Dm0644 /prebuilt/prebuilt.manifest /usr/lib/novadeck/prebuilt.manifest
  fi
  # Record the install-set marker (written last) so the host reuse-check can detect any package
  # add/removal — release, prebuilt-dep, or test-only — without re-running the slow emulated pacman.
  install -Dm0644 /prebuilt/pkgs /usr/lib/novadeck/pkgs

  # Release base ships the runtime PACKAGES only — no network/SSH config or service
  # enablement. First-boot networking is the SteamOS UI'\''s responsibility; all Wi-Fi/SSH
  # scaffolding (.link/.network, regdom, wpa creds, sshd + host keys, enable-symlinks) is
  # injected test-only by images/assemble-rootfs.sh under NOVADECK_TEST=1.

  # Headless-boot fix (GENERAL, not network/test): the image ships an empty /etc/machine-id
  # (ConditionFirstBoot=yes), so systemd-firstboot.service runs and, with console=tty0 and no
  # usable console input, prompts for locale/root-password and blocks sysinit.target forever
  # — the device never reaches multi-user. (systemd.firstboot=off on the cmdline only disables
  # PID1'\''s builtin query, NOT this unit.) Mask it; machine-id is still generated on first
  # boot and preset-all still runs, so service enablement is unaffected.
  ln -sf /dev/null /etc/systemd/system/systemd-firstboot.service

  # Network stack is NetworkManager, for every build (release + test) — see PKGS note above.
  # The holo base ships systemd-networkd enabled too, so BOTH run: networkd manages nothing
  # (NM owns the links) yet its wait-online never reaches "configured" and pins
  # network-online.target until it times out EVERY boot, stalling anything ordered after it
  # (e.g. the gamescope session queued behind network-online.target). HW-confirmed 2026-06-27.
  # Mask networkd + its socket + its wait-online so only NetworkManager-wait-online satisfies
  # network-online.target. Masking (not disable) is preset-proof: nothing can socket-activate or
  # Wants= them back. NM provides its own resolved/timesync paths; networkd is pure dead weight.
  ln -sf /dev/null /etc/systemd/system/systemd-networkd.service
  ln -sf /dev/null /etc/systemd/system/systemd-networkd.socket
  ln -sf /dev/null /etc/systemd/system/systemd-networkd-wait-online.service

  # ...and ENABLE NetworkManager for every build. The holo base ships NM installed-but-disabled;
  # with networkd now masked, a release image would have NO active network manager at all, so the
  # Steam gamepadui lists zero Wi-Fi (HW-confirmed). The test block in assemble-rootfs.sh used to be
  # the only place NM got enabled — wrong layer (test-only). Enable it here the preset-proof way:
  # /etc/machine-id is empty so first boot runs preset-all where the stock 99-default.preset says
  # "disable *"; a high-prio preset (60 < 99) keeps NM enabled, and the multi-user.target.wants +
  # dbus-activation symlinks (what systemctl enable NetworkManager makes) are the build-time
  # fallback. NM drives wpa_supplicant directly; no wpa_supplicant.service enable needed.
  # NOTE: this whole block runs inside the single-quoted docker bash -c, and at this stage /usr is
  # pacman-owned + read-only, so the preset goes in /etc (systemd reads /etc/systemd/system-preset/
  # too, at higher priority than /usr/lib). Keep comments apostrophe-free — a bare single-quote
  # closes the -c string and leaks the rest to the host shell (permission-denied on /etc + /usr).
  mkdir -p /etc/systemd/system-preset
  echo "enable NetworkManager.service" >/etc/systemd/system-preset/60-novadeck-network.preset
  mkdir -p /etc/systemd/system/multi-user.target.wants
  ln -sf /usr/lib/systemd/system/NetworkManager.service \
         /etc/systemd/system/multi-user.target.wants/NetworkManager.service
  ln -sf /usr/lib/systemd/system/NetworkManager.service \
         /etc/systemd/system/dbus-org.freedesktop.NetworkManager.service

  # deck user (uid/gid 1000) — owns the session home /home/deck (a dedicated growable partition)
  # and, later, the gamescope session. SteamOS uses uid 1000 "deck"; bake the account into the RO
  # root /etc HERE (the root is read-only at runtime, so a boot-time systemd-sysusers could not
  # persist it). -M: do NOT create a home in the RO root — /home/deck lives on the /home partition,
  # which make-sdcard.sh pre-seeds (deck-owned) with the Steam client at image-build time. Supplementary
  # groups are added only when they already exist in the base (hardware/seat access for the session).
  if ! getent passwd deck >/dev/null 2>&1; then
    useradd -M -u 1000 -U -s /bin/bash -c "Steam Deck User" deck
  fi
  for g in wheel video render input audio seat; do
    if getent group "$g" >/dev/null 2>&1; then usermod -aG "$g" deck; fi
  done

  # sddm system user + its state dir. sddm ships /usr/lib/sysusers.d/sddm.conf and expects the
  # `sddm` user/group to exist, but the RO root cannot run systemd-sysusers at boot to persist it
  # (same reason deck is baked above). Materialize it now from the shipped sysusers config (falls
  # back to a plain system account if the file name ever changes upstream), and pre-create the
  # state dir the tmpfiles.d entry would otherwise make on a writable root.
  if ! getent passwd sddm >/dev/null 2>&1; then
    systemd-sysusers /usr/lib/sysusers.d/sddm.conf 2>/dev/null \
      || useradd -r -U -M -d /var/lib/sddm -s /usr/bin/nologin -c "Simple Desktop Display Manager" sddm
  fi
  install -d -o sddm -g sddm -m 1770 /var/lib/sddm 2>/dev/null || true

  # NB: no `pacman -Scc` here — /var/cache/pacman/pkg is a persistent host bind-mount (the retry
  # cache) and is excluded from `docker export` anyway, so cleaning it would only throw the cache
  # away without shrinking the exported base.
' >&2
# ^ redirect the container'\''s stdout (pacman progress) to stderr: this script'\''s stdout must
#   carry ONLY the exported rootfs path (echo "$DEST" below), which build-image.sh captures.

echo "[novadeck] exporting customized base -> ${DEST#"$ROOT"/}" >&2
# Extract AS ROOT inside a container so the base tree keeps the image's real ownership
# (root + service users). A host-side `tar -x` runs as the unprivileged build user and
# squashes the whole tree to that uid — which makes sshd refuse its non-root privsep dir
# (/usr/share/empty.sshd) and is wrong for everything else too. Remove any prior export as
# root as well (after this fix it is root-owned, so the build user can't unlink it).
mkdir -p "$ROOT/work"
docker run --rm -v "$ROOT/work":/wb "$REF" rm -rf "/wb/base"
mkdir -p "$DEST"
docker export "$cid" | docker run --rm -i -v "$DEST":/dest "$REF" \
  tar -C /dest --numeric-owner -xf -

# du -sh on a root-owned export warns on 0700 dirs (/root, NM system-connections, gnupg keys) when
# run as the host user; the size is just for the log line, so drop those stderr warnings.
echo "[novadeck] customized base ready ($(du -sh "$DEST" 2>/dev/null | cut -f1) at ${DEST#"$ROOT"/})" >&2
echo "$DEST"
