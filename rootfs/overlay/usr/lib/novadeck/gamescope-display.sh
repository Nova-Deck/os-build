# shellcheck shell=sh
# novadeck gamescope-display resolver — sourced by novadeck-rest / novadeck-suspend.
#
# THE DPMS BUG this fixes: gamescopectl connects to $XDG_RUNTIME_DIR/$GAMESCOPE_WAYLAND_DISPLAY and
# defaults that name to "gamescope-0" (src/Apps/gamescopectl.cpp). But gamescope binds the FIRST FREE
# slot — it loops gamescope-0, gamescope-1, ... and stops at the first wl_display_add_socket() that
# succeeds (src/wlserver.cpp). So a stale socket left by a prior UNCLEAN exit (our session unit runs
# Restart=on-failure, and the restart path is documented-contaminated — see docs/archive/bringup-phase2.md 1e)
# pushes the LIVE compositor onto gamescope-1 and leaves a dead gamescope-0 behind. gamescopectl then
# talks to the dead socket, the modeset never happens, and the panel stays on its frozen frame on
# suspend/resume. (Observed exactly that on HW 2026-06-24.)
#
# How we find the LIVE slot: a wayland server creates "<name>.lock" next to its socket and keeps that
# fd OPEN (flock) for the whole life of the display (wl_socket_lock). A stale socket left by an
# unclean exit has the .lock FILE on disk but NO process holding it. So scanning /proc/*/fd for a
# process that holds a "gamescope-N.lock" open pinpoints the live slot — directly, and crucially
# independent of two traps we hit on HW:
#   * process name: gamescope renames its comm to "gamescope-wl", so `pgrep -x gamescope` misses it.
#   * /proc/<pid>/environ: gamescope publishes GAMESCOPE_WAYLAND_DISPLAY via setenv() AFTER launch,
#     and setenv() never reaches /proc/<pid>/environ (that reflects the exec-time env only) — so the
#     compositor's own environ does NOT carry the name.
#
# WHICH RUNTIME DIR (#113). The callers run as ROOT (novadeck-suspend as systemd-suspend.service,
# novadeck-rest over SSH), but the session runs as `deck`, so the socket is /run/user/1000/gamescope-N,
# not under root's runtime dir. This used to default XDG_RUNTIME_DIR to /run/user/0 (from when the
# session ran as root) and search only there, so every strategy missed and every suspend fell back to
# the backlight with the crtc still scanning out. It now searches every /run/user/<uid>/ and EXPORTS
# the directory it found the socket in, together with its name, for gamescopectl to use.
#
# Returns 0 when resolved, with XDG_RUNTIME_DIR and GAMESCOPE_WAYLAND_DISPLAY exported; 1 when nothing
# live was found (GAMESCOPE_WAYLAND_DISPLAY is then the historical gamescope-0 and the caller's own
# XDG_RUNTIME_DIR is left alone — the modeset attempt that follows will most likely fail, and the
# caller must treat that as "panel unchanged"). GS_PROC_ROOT / GS_RUN_ROOT are test seams.
gs_resolve_display() {
  : "${GS_PROC_ROOT:=/proc}"
  : "${GS_RUN_ROOT:=/run/user}"

  # 0) honour an explicit override: a runtime dir AND a display name that together name a socket.
  # A runtime dir alone is NOT one — root's SSH login inherits XDG_RUNTIME_DIR=/run/user/0.
  if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -n "${GAMESCOPE_WAYLAND_DISPLAY:-}" ] \
     && [ -S "$XDG_RUNTIME_DIR/$GAMESCOPE_WAYLAND_DISPLAY" ]; then
    export XDG_RUNTIME_DIR GAMESCOPE_WAYLAND_DISPLAY
    return 0
  fi

  # 1) authoritative: find the process that holds a gamescope-N.lock open under any
  # /run/user/<uid>/, take that slot's socket and that directory.
  for _fd in "$GS_PROC_ROOT"/[0-9]*/fd/*; do
    _t=$(readlink "$_fd" 2>/dev/null) || continue
    case "$_t" in "$GS_RUN_ROOT"/*/gamescope-*.lock) ;; *) continue ;; esac
    _dir=${_t%/*}
    # exactly one level below the run root: /run/user/<uid>, nothing nested
    case "${_dir#"$GS_RUN_ROOT"/}" in ""|*/*) continue ;; esac
    _name=${_t##*/}; _name=${_name%.lock}
    # accept only the bare control socket gamescope-<digits> (reject gamescope-N-ei.lock etc.)
    case "${_name#gamescope-}" in ""|*[!0-9]*) continue ;; esac
    if [ -S "$_dir/$_name" ]; then
      XDG_RUNTIME_DIR=$_dir GAMESCOPE_WAYLAND_DISPLAY=$_name
      export XDG_RUNTIME_DIR GAMESCOPE_WAYLAND_DISPLAY
      return 0
    fi
  done

  # 2) fall back: exactly one bare gamescope-<digits> control socket across all runtime dirs
  # (ignore .lock/-ei/limiter). Two or more is ambiguous without a lock holder, so it is a failure.
  _found=; _count=0
  for _s in "$GS_RUN_ROOT"/*/gamescope-*; do
    [ -S "$_s" ] || continue
    _b=${_s##*/}
    case "${_b#gamescope-}" in ""|*[!0-9]*) continue ;; esac
    _found=$_s; _count=$((_count + 1))
  done
  if [ "$_count" -eq 1 ]; then
    XDG_RUNTIME_DIR=${_found%/*} GAMESCOPE_WAYLAND_DISPLAY=${_found##*/}
    export XDG_RUNTIME_DIR GAMESCOPE_WAYLAND_DISPLAY
    return 0
  fi

  # 3) nothing live: name the historical default for the caller's log line, and report failure.
  GAMESCOPE_WAYLAND_DISPLAY=gamescope-0
  export GAMESCOPE_WAYLAND_DISPLAY
  return 1
}
