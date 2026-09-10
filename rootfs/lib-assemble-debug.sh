#!/usr/bin/env bash
# novadeck read-only root assembler — stage `debug-capture`.
#
# SOURCED by rootfs/assemble-rootfs.sh, never executed. Split out of it for issue #43; the code
# and its rationale are unchanged (tests/test-mkroot.sh reads the `# STAGE <name>` banners out of
# this file set, and asserts the roster it was audited against).
#
# NEVER sourced unless NOVADECK_DEBUG=1. Independent of NOVADECK_DEV -- it applies to release builds too.
#
# Reads the assembler's globals rather than taking arguments -- $stage (the staged tree), $ROOT
# (repo root), $OUT (build outputs). Turning ~20 implicit globals into positional parameters is
# where a verbatim move stops being verbatim, so it is deliberately not done.

# STAGE debug-capture — journald log capture (NOVADECK_DEBUG=1). INDEPENDENT of NOVADECK_DEV, applies to release too.
# This device has no UART and is usually powered off abruptly, and journald's default
# SyncIntervalSec=5min means a short boot's system logs (kernel/NetworkManager/wpa_supplicant/
# regulatory) never reach disk before the power is cut — that is why a released card's persistent
# journal held only the late gamescope session and none of the Wi-Fi bring-up. Under DEBUG, force
# persistent storage, sync every few seconds so logs survive a power-yank, drop the rate limit so
# gamescope's chatter cannot evict other units, and cap size generously. Diagnostic builds only —
# never ship: the frequent fsync + unbounded logging beat on the SD card. See wifi diagnosis thread.
if [ "${NOVADECK_DEBUG:-}" = "1" ]; then
  echo "  [DEBUG] enabling persistent journald + live journal streamer to /home"
  # Runtime debug marker: NOVADECK_DEBUG is a build-time var, so bake a sentinel that on-device
  # tools can key off. novadeck-steam checks this to enable Steam CEF remote-debugging (DevTools).
  install -d -m0755 "$stage/usr/lib/novadeck"
  : >"$stage/usr/lib/novadeck/debug"
  # (a) Nudge journald toward persistence too (belt for anything that DOES reach /var).
  install -d -m0755 "$stage/etc/systemd/journald.conf.d"
  cat >"$stage/etc/systemd/journald.conf.d/60-novadeck-debug.conf" <<'DBG'
# NOVADECK_DEBUG build only — capture system logs on a no-UART, power-yanked device.
[Journal]
Storage=persistent
SyncIntervalSec=5s
RateLimitIntervalSec=0
RateLimitBurst=0
SystemMaxUse=500M
DBG

  # (b) The real capture: journald reliably RECEIVES system logs into its runtime journal but on
  # this RO-root device it does not persist them to /var before power is cut (a released card kept
  # only the late gamescope session). So stream the live journal to the ext4 /home partition, which
  # IS writable and survives a power-yank. `journalctl -b -f` first dumps the WHOLE boot backlog
  # (kernel/NM/wpa/regulatory, even though this unit starts at multi-user) then follows live — so it
  # captures the OOBE Wi-Fi connect attempt on the RELEASE path. Plus a one-shot regdom/dmesg snapshot.
  cat >"$stage/usr/lib/systemd/system/novadeck-debug-log.service" <<'UNIT'
[Unit]
Description=novadeck DEBUG log capture to /home (streams the journal + regdom snapshot)
After=systemd-journald.service
RequiresMountsFor=/home
[Service]
Type=simple
ExecStartPre=/usr/bin/sh -c 'mkdir -p /home/novadeck-debug; { echo "== iw reg get =="; iw reg get; echo "== dmesg (wifi) =="; dmesg | grep -iE "ath12k|cfg80211|regulatory|wcn|wlan"; } >/home/novadeck-debug/snapshot.log 2>&1 || true'
ExecStart=/usr/bin/sh -c 'exec journalctl -b -f -o short-precise --no-hostname >>/home/novadeck-debug/journal.log 2>&1'
Restart=always
RestartSec=1
[Install]
WantedBy=multi-user.target
UNIT

  # Enable preset-proof: /etc/machine-id is empty so first boot runs preset-all where 99-default is
  # "disable *"; a high-prio preset (60 < 99) keeps us enabled, plus the wants symlink as fallback.
  install -d -m0755 "$stage/usr/lib/systemd/system-preset"
  echo "enable novadeck-debug-log.service" >"$stage/usr/lib/systemd/system-preset/60-novadeck-debug.preset"
  install -d -m0755 "$stage/etc/systemd/system/multi-user.target.wants"
  ln -sf /usr/lib/systemd/system/novadeck-debug-log.service \
         "$stage/etc/systemd/system/multi-user.target.wants/novadeck-debug-log.service"
fi
