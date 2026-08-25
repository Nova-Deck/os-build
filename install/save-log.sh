#!/bin/sh
# novadeck internal install — put the run's log somewhere it can actually be read. Phase 5 of
# .claude/plans/internal-install.plan.md.
#
#   save-log.sh              collect the log to /run/novadeck/install.log and copy it to the ESP
#   save-log.sh --console    also print the end of it to the panel's tty
#
# "That single decision is worth more than the rest of the UI" -- §5, and it is not hyperbole. The
# device has no serial console. If the installer fails on a board with no SSH reachable, the ONLY
# artefact that can leave the machine is a file on the FAT ESP of the installer medium: pull the
# card, put it in a PC, read what happened. Everything else about a failure is unrecoverable.
#
# IT NEVER FAILS THE UNIT. Every step is best-effort and the exit status is always 0: a log that
# could not be saved must not turn a successful install into a failed one, and must not mask the
# real failure of a failed one. Missing journalctl, an ESP that is not mounted, a read-only medium
# -- each is a line in the log about the log, not an error.
set -u

PROG=${0##*/}
log() { printf '[%s] %s\n' "$PROG" "$*" >&2; }

RUNDIR=${NOVADECK_INSTALL_RUNDIR:-/run/novadeck}
LOGFILE=${NOVADECK_INSTALL_LOG:-$RUNDIR/install.log}
# Where the installer medium's own FAT ESP is mounted. Phase 6 fixes this in the image's fstab; it
# is a variable here so the suite can point it at a sandbox and so an operator can redirect it.
ESP=${NOVADECK_INSTALLER_ESP:-/esp}
# Mounting it OURSELVES is the fallback, and both tools are seams so the suite can drive the branch
# without root and without a real filesystem.
MOUNT=${NOVADECK_INSTALLER_MOUNT:-mount}
UMOUNT=${NOVADECK_INSTALLER_UMOUNT:-umount}
UNITS=${NOVADECK_INSTALL_UNITS:-novadeck-installer.service}
JOURNALCTL=${JOURNALCTL:-journalctl}
CONSOLE=${NOVADECK_INSTALL_CONSOLE:-/dev/tty1}
RECORD=${NOVADECK_INSTALL_RECORD:-$RUNDIR/install/record}

mkdir -p "$RUNDIR" 2>/dev/null || true

{
    printf '=== novadeck installer log, %s ===\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)"
    # -b, the CURRENT boot, and never -b -1: the boot index is not trustworthy on these devices,
    # whose RTC comes up stale (see the project's journal notes). This runs inside the boot it is
    # describing, so the current boot is the right question anyway.
    for u in $UNITS; do
        printf '\n--- %s ---\n' "$u"
        if command -v "$JOURNALCTL" >/dev/null 2>&1; then
            "$JOURNALCTL" -b -u "$u" --no-pager 2>&1 || printf '(no journal for %s)\n' "$u"
        else
            printf '(no journalctl on this image)\n'
        fi
    done
    # The spine keeps its own plain-text record of what it did and what the user consented to
    # (§3 rule 10). It is the half of the story the journal does not carry.
    if [ -r "$RECORD" ]; then
        printf '\n--- install record ---\n'
        cat "$RECORD" 2>/dev/null
    fi
} >"$LOGFILE" 2>/dev/null || log "could not write $LOGFILE"

# --- the copy that matters ------------------------------------------------------------------------
# A mountpoint check, not just a directory check: /esp existing as an empty directory on the root
# filesystem is the exact case where a copy "succeeds" and the file is nowhere to be found on the
# card afterwards.
esp_mounted() { command -v mountpoint >/dev/null 2>&1 && mountpoint -q "$ESP" 2>/dev/null; }

# MOUNT IT OURSELVES IF NOBODY ELSE DID. HW 2026-08-25: a clean shutdown produced no log on the ESP
# at all, and from in here the two ways that happens are indistinguishable --
#
#   * the fstab mount never happened. `nofail` plus x-systemd.device-timeout=5s means a device that
#     is not ready inside five seconds is skipped, and NOTHING retries it afterwards.
#   * shutdown already unmounted it. ExecStopPost runs only after gamescope is done with SIGTERM,
#     and the unit's After=esp.mount that now orders those was missing.
#
# Both end with the only artefact that can leave this machine going nowhere, so try rather than
# diagnose. `mount "$ESP"` takes the device and options from the fstab entry, which keeps the FAT
# label in exactly one place (install/mkroot.sh writes both it and this file).
WE_MOUNTED=
if ! esp_mounted; then
    if "$MOUNT" "$ESP" >/dev/null 2>&1 && esp_mounted; then
        WE_MOUNTED=1
        log "$ESP was not mounted -- mounted it to save the log"
    fi
fi

COPIED=
if esp_mounted; then
    if cp -f "$LOGFILE" "$ESP/novadeck-install.log" 2>/dev/null; then
        # FAT has no fsync-on-close guarantee anyone should rely on, and the next thing that happens
        # to this machine is usually a power cut by a person holding it.
        sync 2>/dev/null || true
        COPIED=1
        log "log copied to $ESP/novadeck-install.log -- readable on a PC by pulling the medium"
    else
        log "could not copy the log to $ESP (read-only medium?)"
    fi
else
    log "$ESP is not a mount point and could not be mounted -- the log stays at $LOGFILE"
fi

if [ "${1:-}" = --console ] && [ -w "$CONSOLE" ]; then
    {
        printf '\n=== the NovaDeck installer stopped. The last lines of its log: ===\n\n'
        tail -n 25 "$LOGFILE" 2>/dev/null
        printf '\nFull log: %s' "$LOGFILE"
        # The COPY, not the mount: "something is mounted at /esp" was never the question a person
        # reading this needs answered, and it is now wrong as well -- the unmount below can have
        # already run by the time this line matters.
        if [ -n "$COPIED" ]; then
            printf ' and %s/novadeck-install.log on the installer medium' "$ESP"
        fi
        printf '\n\n'
    } >"$CONSOLE" 2>/dev/null || true
fi

# Only ever the mount THIS script made. A FAT with dirty pages and a person's finger on the power
# button is how the log survives the write but not the trip to a PC, and unmounting is the only
# flush that actually settles it. An fstab mount is left alone: something else owns it, and stealing
# it out from under a still-running installer would be a worse bug than the one this fixes.
if [ -n "$WE_MOUNTED" ]; then
    "$UMOUNT" "$ESP" >/dev/null 2>&1 || log "could not unmount $ESP after saving the log"
fi

exit 0
