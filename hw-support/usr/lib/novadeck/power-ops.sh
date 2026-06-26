# shellcheck shell=sh
# power-ops.sh — sourced shared library of reversible userspace power-lowering primitives for the
# novadeck SteamOS layer-C suspend stack. Used by BOTH novadeck-rest (fake "rest mode") and
# novadeck-suspend (cgroup-freeze suspend), so the two stay in lock-step instead of drifting copies.
#
# The primitives: offline every CPU but the boot CPU, soft-block all radios, switch every cpufreq
# policy to powersave, and switch the GPU devfreq governor to powersave. Each op records ONLY what it
# actually changed into $POWER_STATE_DIR, so the matching *_leave restores the prior state precisely
# (the prior governor / which CPUs were up / which radios were unblocked) rather than blindly
# onlining/unblocking everything.
#
# Caller contract — set these before calling power_enter / power_leave:
#   POWER_STATE_DIR             dir for the per-op state records (default /run/novadeck/rest.d)
#   POWER_SKIP                  space-separated ops to skip: cpu rfkill governor gpugov
#   NOVADECK_REST_GOVERNOR      target cpufreq governor   (default powersave)
#   NOVADECK_REST_GPU_GOVERNOR  target GPU devfreq governor (default powersave)
# The library does NOT own the panel (that is gamescope, caller-specific) and does NOT log — the
# caller owns logging so each script keeps its own log destination (rest -> stdout, suspend -> file).
#
# NOTE on errors: every write is a best-effort hardware poke. Callers must NOT `set -e` around these —
# a single failed sysfs write (EBUSY on a CPU, a missing knob) must not abort the rest of enter, and
# must NEVER abort leave (resume has to run to completion). Each write records into state only on
# success, so leave restores precisely what enter actually changed.

: "${POWER_STATE_DIR:=/run/novadeck/rest.d}"
: "${POWER_SKIP:=}"
: "${NOVADECK_REST_GOVERNOR:=powersave}"
: "${NOVADECK_REST_GPU_GOVERNOR:=powersave}"

_pow_skip() { case " $POWER_SKIP " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# --- cpus: offline every CPU that has a writable `online` toggle (the boot CPU has none and stays
# up); never touch cpu0. Record what we offlined so leave brings back exactly those.
_pow_cpu_enter() {
  : > "$POWER_STATE_DIR/cpus"
  for f in /sys/devices/system/cpu/cpu[0-9]*/online; do
    [ -w "$f" ] || continue
    n=${f#/sys/devices/system/cpu/cpu}; n=${n%/online}
    [ "$n" = 0 ] && continue
    [ "$(cat "$f" 2>/dev/null)" = 1 ] || continue
    echo 0 > "$f" 2>/dev/null && echo "$n" >> "$POWER_STATE_DIR/cpus"
  done
}
_pow_cpu_leave() {
  [ -r "$POWER_STATE_DIR/cpus" ] || return 0
  while read -r n; do
    f=/sys/devices/system/cpu/cpu$n/online
    [ -w "$f" ] && echo 1 > "$f" 2>/dev/null
  done < "$POWER_STATE_DIR/cpus"
}

# --- radios: soft-block via sysfs (no rfkill binary dependency). Record only those we actually
# blocked (skip already-blocked ones) so leave restores the prior radio state.
_pow_rf_enter() {
  : > "$POWER_STATE_DIR/rfkill"
  for d in /sys/class/rfkill/rfkill*; do
    [ -w "$d/soft" ] || continue
    [ "$(cat "$d/soft" 2>/dev/null)" = 0 ] || continue
    echo 1 > "$d/soft" 2>/dev/null && basename "$d" >> "$POWER_STATE_DIR/rfkill"
  done
}
_pow_rf_leave() {
  [ -r "$POWER_STATE_DIR/rfkill" ] || return 0
  while read -r r; do
    f=/sys/class/rfkill/$r/soft
    [ -w "$f" ] && echo 0 > "$f" 2>/dev/null
  done < "$POWER_STATE_DIR/rfkill"
}

# --- governor: switch each cpufreq policy to powersave, recording the previous governor per policy.
# Only touch a policy that actually advertises the target governor.
_pow_gov_enter() {
  : > "$POWER_STATE_DIR/governors"
  for g in /sys/devices/system/cpu/cpufreq/policy*/scaling_governor; do
    [ -w "$g" ] || continue
    avail=$(cat "${g%scaling_governor}scaling_available_governors" 2>/dev/null || echo)
    case " $avail " in *" $NOVADECK_REST_GOVERNOR "*) ;; *) continue ;; esac
    cur=$(cat "$g" 2>/dev/null) || continue
    [ "$cur" = "$NOVADECK_REST_GOVERNOR" ] && continue
    p=${g#/sys/devices/system/cpu/cpufreq/}; p=${p%/scaling_governor}
    echo "$NOVADECK_REST_GOVERNOR" > "$g" 2>/dev/null && echo "$p $cur" >> "$POWER_STATE_DIR/governors"
  done
}
_pow_gov_leave() {
  [ -r "$POWER_STATE_DIR/governors" ] || return 0
  while read -r p cur; do
    f=/sys/devices/system/cpu/cpufreq/$p/scaling_governor
    [ -w "$f" ] && echo "$cur" > "$f" 2>/dev/null
  done < "$POWER_STATE_DIR/governors"
}

# --- GPU governor: switch the GPU's devfreq governor to powersave, recording the previous one.
# SoC-INDEPENDENT: the GPU's devfreq device is named after its OF node (gpu@<addr> -> "<addr>.gpu"),
# so we select by the ".gpu" suffix rather than any fixed per-SoC address. That matches the Adreno
# GPU on every Qualcomm SoC while skipping the other devfreq devices (UFS, DDR, …). Only touch a
# device that actually advertises the target governor; no ".gpu" devfreq -> clean no-op.
_pow_gpu_gov_enter() {
  : > "$POWER_STATE_DIR/gpu_governors"
  for g in /sys/class/devfreq/*/governor; do
    d=${g%/governor}
    case "${d##*/}" in *.gpu) ;; *) continue ;; esac
    [ -w "$g" ] || continue
    avail=$(cat "$d/available_governors" 2>/dev/null || echo)
    case " $avail " in *" $NOVADECK_REST_GPU_GOVERNOR "*) ;; *) continue ;; esac
    cur=$(cat "$g" 2>/dev/null) || continue
    [ "$cur" = "$NOVADECK_REST_GPU_GOVERNOR" ] && continue
    n=${d##*/}
    echo "$NOVADECK_REST_GPU_GOVERNOR" > "$g" 2>/dev/null && echo "$n $cur" >> "$POWER_STATE_DIR/gpu_governors"
  done
}
_pow_gpu_gov_leave() {
  [ -r "$POWER_STATE_DIR/gpu_governors" ] || return 0
  while read -r n cur; do
    f=/sys/class/devfreq/$n/governor
    [ -w "$f" ] && echo "$cur" > "$f" 2>/dev/null
  done < "$POWER_STATE_DIR/gpu_governors"
}

# power_enter — lower power, recording prior state. Governors first, then offline CPUs, then radios.
# power_leave — restore in REVERSE (radios, CPUs, governors), then drop the state records.
# Both honour POWER_SKIP per-op (keys: cpu rfkill governor gpugov) so bring-up can keep, e.g., the
# Wi-Fi link up over SSH with POWER_SKIP="rfkill".
power_enter() {
  mkdir -p "$POWER_STATE_DIR"
  _pow_skip governor || _pow_gov_enter
  _pow_skip gpugov   || _pow_gpu_gov_enter
  _pow_skip cpu      || _pow_cpu_enter
  _pow_skip rfkill   || _pow_rf_enter
}
power_leave() {
  _pow_skip rfkill   || _pow_rf_leave
  _pow_skip cpu      || _pow_cpu_leave
  _pow_skip gpugov   || _pow_gpu_gov_leave
  _pow_skip governor || _pow_gov_leave
  rm -f "$POWER_STATE_DIR/cpus" "$POWER_STATE_DIR/rfkill" \
        "$POWER_STATE_DIR/governors" "$POWER_STATE_DIR/gpu_governors"
}
