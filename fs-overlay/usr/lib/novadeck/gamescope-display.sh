# shellcheck shell=sh
# novadeck gamescope-display resolver — sourced by novadeck-rest / novadeck-suspend.
#
# THE DPMS BUG this fixes: gamescopectl connects to $XDG_RUNTIME_DIR/$GAMESCOPE_WAYLAND_DISPLAY and
# defaults that name to "gamescope-0" (src/Apps/gamescopectl.cpp). But gamescope binds the FIRST FREE
# slot — it loops gamescope-0, gamescope-1, ... and stops at the first wl_display_add_socket() that
# succeeds (src/wlserver.cpp). So a stale socket left by a prior UNCLEAN exit (our session unit runs
# Restart=on-failure, and the restart path is documented-contaminated — see docs/bringup-phase2.md 1e)
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
# Returns 0 when resolved from a live source, 1 when it fell through to the historical default
# (caller may warn/log but should still attempt the modeset — best-effort, like every other poke).
gs_resolve_display() {
  : "${XDG_RUNTIME_DIR:=/run/user/0}"

  # 0) honour an explicit override / inherited value if its socket is actually present.
  if [ -n "${GAMESCOPE_WAYLAND_DISPLAY:-}" ] && [ -S "$XDG_RUNTIME_DIR/$GAMESCOPE_WAYLAND_DISPLAY" ]; then
    export GAMESCOPE_WAYLAND_DISPLAY
    return 0
  fi

  # 1) authoritative: find the process that holds a gamescope-N.lock open, take that slot's socket.
  for _fd in /proc/[0-9]*/fd/*; do
    _t=$(readlink "$_fd" 2>/dev/null) || continue
    case "$_t" in "$XDG_RUNTIME_DIR"/gamescope-*.lock) ;; *) continue ;; esac
    _name=${_t##*/}; _name=${_name%.lock}
    # accept only the bare control socket gamescope-<digits> (reject gamescope-N-ei.lock etc.)
    case "${_name#gamescope-}" in ""|*[!0-9]*) continue ;; esac
    if [ -S "$XDG_RUNTIME_DIR/$_name" ]; then
      GAMESCOPE_WAYLAND_DISPLAY=$_name
      export GAMESCOPE_WAYLAND_DISPLAY
      return 0
    fi
  done

  # 2) fall back: exactly one bare gamescope-<digits> control socket present (ignore .lock/-ei/limiter).
  _found=; _count=0
  for _s in "$XDG_RUNTIME_DIR"/gamescope-*; do
    [ -S "$_s" ] || continue
    _b=${_s##*/}
    case "${_b#gamescope-}" in ""|*[!0-9]*) continue ;; esac
    _found=$_b; _count=$((_count + 1))
  done
  if [ "$_count" -eq 1 ]; then
    GAMESCOPE_WAYLAND_DISPLAY=$_found
    export GAMESCOPE_WAYLAND_DISPLAY
    return 0
  fi

  # 3) last resort: the historical default, so a single-session boot still works.
  GAMESCOPE_WAYLAND_DISPLAY=gamescope-0
  export GAMESCOPE_WAYLAND_DISPLAY
  return 1
}
