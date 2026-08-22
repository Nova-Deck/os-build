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
if command -v mountpoint >/dev/null 2>&1 && mountpoint -q "$ESP" 2>/dev/null; then
    if cp -f "$LOGFILE" "$ESP/novadeck-install.log" 2>/dev/null; then
        # FAT has no fsync-on-close guarantee anyone should rely on, and the next thing that happens
        # to this machine is usually a power cut by a person holding it.
        sync 2>/dev/null || true
        log "log copied to $ESP/novadeck-install.log -- readable on a PC by pulling the medium"
    else
        log "could not copy the log to $ESP (read-only medium?)"
    fi
else
    log "$ESP is not a mount point -- the log stays at $LOGFILE"
fi

if [ "${1:-}" = --console ] && [ -w "$CONSOLE" ]; then
    {
        printf '\n=== the NovaDeck installer stopped. The last lines of its log: ===\n\n'
        tail -n 25 "$LOGFILE" 2>/dev/null
        printf '\nFull log: %s' "$LOGFILE"
        if mountpoint -q "$ESP" 2>/dev/null; then
            printf ' and %s/novadeck-install.log on the installer medium' "$ESP"
        fi
        printf '\n\n'
    } >"$CONSOLE" 2>/dev/null || true
fi

exit 0
