#!/usr/bin/env bash
# novadeck read-only root assembler — stages `dev-wifi-ssh` and `dev-ota-channel`, DEV-ONLY.
#
# SOURCED by rootfs/assemble-rootfs.sh, never executed. Split out of it for issue #43; the code
# and its rationale are unchanged (tests/test-mkroot.sh reads the `# STAGE <name>` banners out of
# this file set, and asserts the roster it was audited against).
#
# NEVER sourced on a release build -- the assembler sources it inside the NOVADECK_DEV gate, so this file is not read at all when building a shippable image. That is the separation issue #43 asked for. 4c-3/4c-4 are NOT here: they run on every build and live in lib-assemble-decky-splash.sh.
#
# Reads the assembler's globals rather than taking arguments -- $stage (the staged tree), $ROOT
# (repo root), $OUT (build outputs). Turning ~20 implicit globals into positional parameters is
# where a verbatim move stops being verbatim, so it is deliberately not done.

# STAGE dev-wifi-ssh — DEV-ONLY Wi-Fi/SSH injection (NOVADECK_DEV=1). NEVER part of a release/RAUC build:
# the release base is packages-only and first-boot networking is the SteamOS UI's job. Here
# we add ALL the scaffolding a throwaway card needs to auto-join the LAN and accept an SSH
# login to run vulkaninfo — a NetworkManager connection profile, regdom, the Wi-Fi PSK + SSH
# key (from the environment, so secrets never touch the repo), service enablement, and host
# keys. The runtime packages (networkmanager + its wpa_supplicant backend, openssh) come from
# the base (customize-base.sh). The test card deliberately uses the SAME manager as release —
# NetworkManager — so this path validates the real release Wi-Fi stack (incl. its unaided recovery
# across a novadeck-suspend cycle) instead of a divergent test-only wpa_supplicant@wlan0 + networkd path.
# Initialised OUTSIDE the dev branch because this script runs under `set -u`: a release build
# never enters the block below, and the Wi-Fi test further down would then dereference an unset
# variable and abort the assembler.
if [ "${NOVADECK_DEV:-}" = "1" ]; then
  # WI-FI IS OPTIONAL, and which way it went is stamped by ROOTFS_MODE so make re-assembles on a
  # flip (see the Makefile). A card with no profile is the SHIPPING first-boot condition — no
  # network until the user joins one in the UI — which is the only honest way to exercise OOBE
  # locally. It is also unreachable: no profile means no SSH, and this device has no UART, so the
  # only debug path left is the offline card-mount (`journalctl -D`).
  #
  # These vars used to be `:?` REQUIRED here, which made a no-network dev card impossible to
  # build. Optional is right, but "absent means skip" alone would trade one footgun for a worse
  # one: forgetting to source dev.env.local would silently hand you an unreachable card. So intent
  # is what decides, and NOVADECK_WIFI=1 is how a caller that depends on SSH states it.
  dev_wifi=1
  if [ "${NOVADECK_WIFI:-}" = "0" ]; then
    dev_wifi=0                                    # explicit: no profile even though creds exist
  elif [ -z "${NOVADECK_WIFI_SSID:-}" ] || [ -z "${NOVADECK_WIFI_PSK:-}" ]; then
    if [ "${NOVADECK_WIFI:-}" = "1" ]; then
      echo "NOVADECK_WIFI=1 requires NOVADECK_WIFI_SSID + NOVADECK_WIFI_PSK" >&2
      echo "  put them in dev.env.local (gitignored), or unset NOVADECK_WIFI for a no-network card" >&2
      exit 1
    fi
    dev_wifi=0
  fi

  if [ "$dev_wifi" = "0" ]; then
    echo "  [DEV] NO Wi-Fi profile — this card will NOT auto-join and is NOT reachable over SSH."
    echo "  [DEV]   first boot starts offline (the shipping OOBE condition); debug via card-mount."
    echo "  [DEV]   for a reachable card, set NOVADECK_WIFI_SSID + NOVADECK_WIFI_PSK in dev.env.local."
  fi
fi

# STAGE dev-ota-channel — DEV-ONLY. A dev card must NEVER be offered a stable release, because taking
# one is a DOWNGRADE that silently destroys whatever the card was built to test.
#
# HW-OBSERVED 2026-08-06: a dev card at NOVADECK_GIT=afabca8 — built specifically to test the
# gamescope 3.16.25 bump — showed an update notification in the Steam UI. Pressing Apply ran
# steamos-update -> novadeck-update -> rauc and began writing stable's novadeck-v0.2.1.raucb (3.7 GB)
# into the inactive slot. v0.2.1 carries gamescope 3.16.23.2, i.e. exactly the build whose bug the
# card existed to test a fix for, and on completion it would have become primary.
#
# WHY it was offered at all: novadeck-update compares the running version to the channel's for
# INEQUALITY, not for ordering, and a dev image stamps NOVADECK_VERSION=dev (see the
# /etc/novadeck-release block above). "dev" != "v0.2.1", so every published stable release looks
# like an update forever. Ordering cannot fix this on its own — "dev" is not comparable to a
# release tag at all — so the channel is the right lever.
#
# WHAT THIS BUYS with no server-side work: novadeck-update's manifest() FAILS CLOSED. A channel
# whose latest.json does not exist cannot be reached, and `check` then exits EXIT_NONE (7) — the
# same "no update available" it returns for a healthy up-to-date device. So a dev card stops being
# offered anything the moment this lands, and publishing a real dev channel later is additive.
#
# This writes the documented override file (novadeck-update's CONFIG_FILE, /etc/novadeck/ota.conf),
# NOT a new code path, so the operator override surface is unchanged and a dev card can still be
# repointed by hand ([[devices-are-operator-reachable]]). A RELEASE image gets no ota.conf at all
# and keeps novadeck-update's own DEFAULT_CHANNEL="stable".
if [ "${NOVADECK_DEV:-}" = "1" ]; then
  echo "  [DEV] pinning the OTA channel to 'dev' — a dev card is never offered a stable release"
  install -d -m 0755 "$stage/etc/novadeck"
  cat >"$stage/etc/novadeck/ota.conf" <<'OTACONF'
# DEV CARD ONLY — written by rootfs/assemble-rootfs.sh under NOVADECK_DEV=1.
# A release image does not ship this file and uses novadeck-update's built-in "stable" default.
#
# A dev build stamps NOVADECK_VERSION=dev, and the update check compares versions for INEQUALITY,
# so every stable release would otherwise read as an available update — and taking it downgrades
# the card to the release it was built to test against. Point it somewhere that is not stable.
#
# If this channel has no latest.json on the server the check fails closed and reports "no update
# available", which is the intended behaviour for a dev card. Set OTA_URL here too to point at a
# different server entirely.
OTA_CHANNEL=dev
OTACONF
  chmod 0644 "$stage/etc/novadeck/ota.conf"
fi
if [ "${NOVADECK_DEV:-}" = "1" ] && [ "$dev_wifi" = "1" ]; then
  echo "  [DEV] injecting Wi-Fi profile for '$NOVADECK_WIFI_SSID' (dev-only)"

  # NetworkManager connection profile (keyfile format). NM binds by SSID, not interface, so no
  # interface rename is needed; NM also runs its own DHCP and drives wpa_supplicant itself (the
  # plain wpa_supplicant.service, NOT the @wlan0 instance). The file MUST be 0600 root-owned or NM
  # ignores it ("ignoring due to permissions"). autoconnect=true joins the LAN at boot.
  install -d -m0755 "$stage/etc/NetworkManager/system-connections"
  ( umask 077; cat >"$stage/etc/NetworkManager/system-connections/${NOVADECK_WIFI_SSID}.nmconnection" <<EOF
[connection]
id=${NOVADECK_WIFI_SSID}
type=wifi
autoconnect=true

[wifi]
mode=infrastructure
ssid=${NOVADECK_WIFI_SSID}

[wifi-security]
key-mgmt=wpa-psk
psk=${NOVADECK_WIFI_PSK}

[ipv4]
method=auto

[ipv6]
method=auto
EOF
  )
  chmod 0600 "$stage/etc/NetworkManager/system-connections/${NOVADECK_WIFI_SSID}.nmconnection"

  # Regulatory domain at the kernel layer: the 85-regulatory.rules udev rule runs
  # set-wireless-regdom when cfg80211 loads; it sources this file and runs `iw reg set`.
  # The packaged file (from wireless-regdb) has every country commented out, so without this
  # the chip stays on the world domain (00) until something sets it. Pin it so 5 GHz is enabled
  # from the moment cfg80211 loads (and the helper stops exiting 1). NM honours the kernel regdom.
  install -d -m0755 "$stage/etc/conf.d"
  printf '\nWIRELESS_REGDOM="BE"\n' >>"$stage/etc/conf.d/wireless-regdom"

  # No resume hook needed: the test card runs NetworkManager (same as release), and NM re-associates
  # Wi-Fi unaided after a novadeck-suspend thaw — HW-validated 2026-06-25, which is why the former
  # 50-nm-reup hook was dropped as moot.
fi

# The rest of the dev scaffolding is NOT conditional on Wi-Fi. The SSH key is useful on a
# no-Wi-Fi card the moment OOBE joins a network, and the smoke helper is a local tool — gating
# either on a profile that may not exist would make a no-network dev card less useful than it
# needs to be, for no reason.
if [ "${NOVADECK_DEV:-}" = "1" ]; then
  # sshd itself is NOT enabled here anymore: it ships always-on for EVERY build via the rootfs/overlay
  # (60-novadeck-sshd.preset + the committed multi-user.target.wants/sshd.service symlink), because
  # release remote access is key-only and a keyless sshd admits nobody. NetworkManager is likewise
  # enabled for every build in customize-base.sh. So this block only adds the TEST credential
  # below — the root key that gives the throwaway card a root@device login for bring-up.

  # HOST KEYS ARE DELIBERATELY *NOT* GENERATED HERE. This block used to run ssh-keygen into
  # $stage/etc/ssh, on the reasoning that "a read-only root cannot generate them at boot". That
  # reasoning is wrong twice over:
  #
  #   - /etc is an overlayfs whose upper lives in /var (see the overlay setup above), so /etc/ssh
  #     IS writable at runtime. openssh's own sshdgenkeys.service (ExecStart=ssh-keygen -A, with
  #     ConditionPathExists=|! on each key) already runs before sshd.service, which Wants= and
  #     After= it. Baking keys only suppressed that unit's condition.
  #   - A key baked into the image is a property of the BUILD, not of the device. Every device
  #     flashed from one image would share one private host key -- extractable by anyone holding
  #     the image -- and every OTA would swap it, so each update looks like a MITM to every client
  #     that has the device in known_hosts. (Observed on hardware 2026-07-28: the slot-b trial boot
  #     changed the host key purely because it came from a different build.)
  #
  # So: leave /etc/ssh alone and let sshdgenkeys generate per-device keys at first sshd start. They
  # land in the /etc overlay upper, i.e. in this slot's /var, and rootfs/overlay/usr/lib/rauc/post-install.sh carries
  # them to the other slot on update so they survive an OTA. That is the same shape as machine-id.

  # SSH authorized key (key-only root; default PermitRootLogin=prohibit-password).
  if [ -n "${NOVADECK_SSH_PUBKEY:-}" ]; then
    install -d -m0700 "$stage/root/.ssh"
    printf '%s\n' "$NOVADECK_SSH_PUBKEY" >"$stage/root/.ssh/authorized_keys"
    chmod 0600 "$stage/root/.ssh/authorized_keys"
  else
    echo "  [TEST] WARNING: NOVADECK_SSH_PUBKEY unset — sshd (key-only root) will reject login"
  fi
fi
