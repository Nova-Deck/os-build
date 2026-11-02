#!/usr/bin/env bash
# novadeck read-only root assembler — stages `dev-wifi-ssh`, `dev-ota-channel` and `dev-usb-gadget`, DEV-ONLY.
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

# STAGE dev-usb-gadget — DEV-ONLY USB Ethernet gadget (NCM): plug the device into a PC and ssh root@10.55.0.1.
#
# A second way in when Wi-Fi is the thing being debugged, or the card has no Wi-Fi profile at all
# (dev_wifi=0 above). NCM, not RNDIS/ECM: Linux, macOS and Windows 11 all bind it with their in-box
# drivers. The kernel side is already there (USB_CONFIGFS_NCM=y, dwc3 dual-role on every board).
#
# DEV-ONLY because sshd ships on EVERY build: a release image would answer on a USB cable to any
# computer it is plugged into. Key-only, but there is no reason to widen a shipped device's surface
# for a bring-up affordance.
#
# Addressing: systemd-networkd, NOT NetworkManager, owns usb0. NM's ipv4.method=shared needs
# dnsmasq, which the base does not carry; networkd has a DHCP server built in. NM is told to leave
# usb0 alone and networkd only touches links its .network files match, so the two never meet.
#
# The UDC can come and go with the dwc3 role switch, so the bind runs from a udev rule on every
# udc add (and is idempotent) rather than once at boot. Once bound, the gadget bus re-binds it by
# UDC name on its own after a host<->device flip.
if [ "${NOVADECK_DEV:-}" = "1" ]; then
  echo "  [DEV] USB Ethernet gadget (NCM): device is 10.55.0.1 on usb0, the PC gets DHCP"

  install -d -m0755 "$stage/usr/local/lib/novadeck"
  cat >"$stage/usr/local/lib/novadeck/usb-gadget-ncm" <<'GADGET'
#!/bin/sh
# DEV CARD ONLY (rootfs/lib-assemble-devcard.sh, STAGE dev-usb-gadget). Idempotent.
set -eu
G=/sys/kernel/config/usb_gadget/novadeck
udc=$(ls /sys/class/udc 2>/dev/null | head -n1)
[ -n "$udc" ] || { echo "usb-gadget-ncm: no UDC yet (host role?), waiting for udev" >&2; exit 0; }

if [ ! -d "$G" ]; then
  # Stable MACs from the machine-id, so the PC keeps one interface (and its settings) per device.
  h=$(sha256sum /etc/machine-id | cut -c1-10)
  mac() { printf '%s:%s:%s:%s:%s:%s' "$1" "$(echo "$h" | cut -c1-2)" "$(echo "$h" | cut -c3-4)" \
          "$(echo "$h" | cut -c5-6)" "$(echo "$h" | cut -c7-8)" "$(echo "$h" | cut -c9-10)"; }
  mkdir -p "$G/strings/0x409" "$G/configs/c.1/strings/0x409" "$G/functions/ncm.usb0"
  echo 0x1d6b > "$G/idVendor"        # Linux Foundation
  echo 0x0104 > "$G/idProduct"       # Multifunction Composite Gadget
  echo 0x0200 > "$G/bcdUSB"
  echo 0xEF   > "$G/bDeviceClass"    # IAD, so Windows binds the NCM function
  echo 0x02   > "$G/bDeviceSubClass"
  echo 0x01   > "$G/bDeviceProtocol"
  echo "$h"          > "$G/strings/0x409/serialnumber"
  echo "novadeck"    > "$G/strings/0x409/manufacturer"
  echo "novadeck dev card" > "$G/strings/0x409/product"
  echo "NCM"         > "$G/configs/c.1/strings/0x409/configuration"
  echo 250           > "$G/configs/c.1/MaxPower"
  mac 06 > "$G/functions/ncm.usb0/dev_addr"
  mac 0a > "$G/functions/ncm.usb0/host_addr"
  ln -s "$G/functions/ncm.usb0" "$G/configs/c.1/"
fi

if [ -z "$(cat "$G/UDC")" ]; then
  echo "$udc" > "$G/UDC"
  echo "usb-gadget-ncm: bound to $udc ($(cat "$G/functions/ncm.usb0/ifname"))"
fi
GADGET
  chmod 0755 "$stage/usr/local/lib/novadeck/usb-gadget-ncm"

  install -d -m0755 "$stage/etc/systemd/system/multi-user.target.wants"
  cat >"$stage/etc/systemd/system/novadeck-usb-gadget.service" <<'UNIT'
# DEV CARD ONLY (rootfs/lib-assemble-devcard.sh, STAGE dev-usb-gadget).
[Unit]
Description=novadeck dev USB Ethernet gadget (NCM)
Requires=sys-kernel-config.mount
After=sys-kernel-config.mount systemd-machine-id-commit.service

[Service]
Type=oneshot
ExecStart=/usr/local/lib/novadeck/usb-gadget-ncm

[Install]
WantedBy=multi-user.target
UNIT
  ln -sf ../novadeck-usb-gadget.service \
    "$stage/etc/systemd/system/multi-user.target.wants/novadeck-usb-gadget.service"

  install -d -m0755 "$stage/etc/udev/rules.d"
  cat >"$stage/etc/udev/rules.d/90-novadeck-usb-gadget.rules" <<'RULE'
# DEV CARD ONLY (rootfs/lib-assemble-devcard.sh, STAGE dev-usb-gadget): (re)bind when a UDC appears.
ACTION=="add", SUBSYSTEM=="udc", TAG+="systemd", ENV{SYSTEMD_WANTS}+="novadeck-usb-gadget.service"
RULE

  install -d -m0755 "$stage/etc/systemd/network"
  cat >"$stage/etc/systemd/network/50-novadeck-usb-gadget.network" <<'NET'
# DEV CARD ONLY (rootfs/lib-assemble-devcard.sh, STAGE dev-usb-gadget).
[Match]
Name=usb0

[Network]
Address=10.55.0.1/24
DHCPServer=yes
LinkLocalAddressing=ipv6
ConfigureWithoutCarrier=yes

# usb0 is the only link networkd manages, and with no cable it has no carrier. Left required, it holds
# networkd's online state at "offline", and timesyncd, which asks networkd whenever networkd runs,
# never polls NTP: the clock stays at the image's build epoch and every TLS download fails with
# "certificate is not yet valid". Wi-Fi is NetworkManager's, invisible to that state.
[Link]
RequiredForOnline=no

[DHCPServer]
PoolOffset=10
PoolSize=20
EmitDNS=no
EmitRouter=no
NET
  # customize-base.sh MASKS networkd (/dev/null links in /etc/systemd/system), and an enable link
  # cannot beat a mask: the gadget enumerates but the PC side sits at NO-CARRIER (f_ncm only reports
  # carrier once usb0 is up on the device). Unmask the daemon and its socket here; wait-online STAYS
  # masked, or network-online.target would wait on a cable that is usually not there.
  rm -f "$stage/etc/systemd/system/systemd-networkd.service" \
        "$stage/etc/systemd/system/systemd-networkd.socket"
  ln -sf /usr/lib/systemd/system/systemd-networkd.service \
    "$stage/etc/systemd/system/multi-user.target.wants/systemd-networkd.service"
  install -d -m0755 "$stage/etc/systemd/system/sockets.target.wants"
  ln -sf /usr/lib/systemd/system/systemd-networkd.socket \
    "$stage/etc/systemd/system/sockets.target.wants/systemd-networkd.socket"

  install -d -m0755 "$stage/etc/NetworkManager/conf.d"
  cat >"$stage/etc/NetworkManager/conf.d/90-novadeck-usb-gadget.conf" <<'NMCONF'
# DEV CARD ONLY (rootfs/lib-assemble-devcard.sh, STAGE dev-usb-gadget): systemd-networkd owns usb0.
[keyfile]
unmanaged-devices=interface-name:usb0
NMCONF
fi
