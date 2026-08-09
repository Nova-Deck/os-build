import { ButtonItem, Field, PanelSection, PanelSectionRow } from "@decky/ui";
import { useEffect, useRef } from "react";
import type { Dispatch, SetStateAction } from "react";
import {
  getPowerStatus,
  resetFanCurve,
  setActiveProfile,
  setCpuScheduler,
  setFanCurve,
  setGpuLevel,
  setManualGpuClock,
} from "../backend";
import { SelectEdit, SliderEdit } from "../components/widgets";
import { titleCase } from "../lib/util";
import type { Config, PowerStatus } from "../types";

export function Power({ config, setConfig }: { config: Config; setConfig: Dispatch<SetStateAction<Config | null>> }) {
  const power = config.power;
  // A slider drag is dozens of onChange events and each backend set is a busctl subprocess;
  // trail the drag instead of racing it. The poll below skips while a set is pending so a
  // just-dragged value is not snapped back by a stale read.
  const clockTimer = useRef<number | null>(null);
  const pendingClock = useRef<number | null>(null);
  // Same treatment for the curve, and it needs it more: every set makes powerd rewrite its
  // drop-in and re-read the whole three-layer config.
  const curveTimer = useRef<number | null>(null);
  const pendingCurve = useRef<number[] | null>(null);

  const adopt = (next: PowerStatus) => {
    setConfig((current) => (current ? { ...current, power: next } : current));
  };

  // The state can change under us (powerd, boot defaults, another session), so poll while the
  // tab is mounted. Profile and level sets are deliberate single actions — no debounce.
  useEffect(() => {
    let cancelled = false;
    const refresh = async () => {
      if (pendingClock.current !== null || pendingCurve.current !== null) return;
      try {
        const next = await getPowerStatus();
        if (!cancelled && pendingClock.current === null && pendingCurve.current === null) adopt(next);
      } catch (error) {
        // transient bus hiccups just skip a poll
      }
    };
    const timer = window.setInterval(refresh, 2000);
    refresh();
    return () => {
      cancelled = true;
      window.clearInterval(timer);
      if (clockTimer.current !== null) window.clearTimeout(clockTimer.current);
      if (curveTimer.current !== null) window.clearTimeout(curveTimer.current);
    };
  }, []);

  const selectProfile = async (label: string) => {
    adopt({ ...power, activeProfile: label });
    try {
      adopt(await setActiveProfile(label));
    } catch (error) {
      // the next poll restores the truth
    }
  };

  const selectGpuLevel = async (level: string) => {
    adopt({ ...power, gpuLevel: level });
    try {
      adopt(await setGpuLevel(level));
    } catch (error) {
      // the next poll restores the truth
    }
  };

  const selectScheduler = async (scheduler: string) => {
    adopt({ ...power, cpuScheduler: scheduler });
    try {
      adopt(await setCpuScheduler(scheduler));
    } catch (error) {
      // the next poll restores the truth
    }
  };

  const dragClock = (mhz: number) => {
    adopt({ ...power, manualGpuClock: mhz });
    pendingClock.current = mhz;
    if (clockTimer.current !== null) window.clearTimeout(clockTimer.current);
    clockTimer.current = window.setTimeout(async () => {
      const value = pendingClock.current;
      clockTimer.current = null;
      if (value === null) return;
      try {
        const next = await setManualGpuClock(value);
        if (pendingClock.current === value) {
          pendingClock.current = null;
          adopt(next);
        }
      } catch (error) {
        pendingClock.current = null;
      }
    }, 300);
  };

  const dragCurve = (index: number, pwm: number) => {
    // Enforce the same non-falling rule powerd does, but do it HERE as well so the
    // neighbouring sliders visibly move with the one under the thumb. Letting powerd clamp
    // silently would make a dragged slider snap back on the next poll with no explanation.
    const next = [...(power.fanCurve || [])];
    next[index] = pwm;
    for (let i = index + 1; i < next.length; i += 1) next[i] = Math.max(next[i], pwm);
    for (let i = index - 1; i >= 0; i -= 1) next[i] = Math.min(next[i], pwm);
    adopt({ ...power, fanCurve: next });
    pendingCurve.current = next;
    if (curveTimer.current !== null) window.clearTimeout(curveTimer.current);
    curveTimer.current = window.setTimeout(async () => {
      const value = pendingCurve.current;
      curveTimer.current = null;
      if (value === null) return;
      try {
        const status = await setFanCurve(value);
        if (pendingCurve.current === value) {
          pendingCurve.current = null;
          adopt(status);
        }
      } catch (error) {
        pendingCurve.current = null;
      }
    }, 300);
  };

  const resetCurve = async () => {
    if (curveTimer.current !== null) window.clearTimeout(curveTimer.current);
    curveTimer.current = null;
    pendingCurve.current = null;
    try {
      adopt(await resetFanCurve(false));
    } catch (error) {
      // the next poll restores the truth
    }
  };

  // Defensive on purpose: the backend and frontend normally ship together, but on a dev card a
  // reboot's plugin re-seed can pair an older backend with a newer mirrored frontend for a
  // moment — a missing field must degrade to a hidden section, not take the whole tab down.
  const gpuLevels = power.gpuLevels || [];
  const hasGpu = gpuLevels.length > 0;
  const clockKnown = (power.manualGpuClockMax || 0) > (power.manualGpuClockMin || 0);
  // Same capability-by-enumeration rule as the GPU section: powerd serves ["none"] alone when
  // the kernel has no sched_ext or the scx binary is missing, and a lone option is not a choice.
  const schedulers = power.cpuSchedulers || [];
  const hasSchedulerChoice = schedulers.length > 1;
  // powerd reports the loaded scheduler separately, so a per-game override is stated rather than
  // left as a dropdown that silently disagrees with the machine.
  const schedulerOverridden =
    !!power.activeCpuScheduler && power.activeCpuScheduler !== power.cpuScheduler;
  // Same capability-by-enumeration rule again: no stops means a powerd that does not serve
  // the curve, and a fan the daemon cannot see means nothing to edit.
  const stops = power.fanCurveStops || [];
  const curve = power.fanCurve || [];
  const hasCurve = stops.length > 0 && curve.length === stops.length;
  const pwmMin = power.fanCurveMinPwm || 0;
  const pwmMax = power.fanCurveMaxPwm || 255;
  // PWM is the fan's unit, not a person's, so the sliders speak percent and convert here at
  // the edge — the property, the config file and powerd itself stay in PWM throughout.
  // The round trip is stable because the PWM grid (0-255) is finer than the percent one, so
  // a slider never drifts off the value it was just set to.
  const toPercent = (pwm: number) => Math.round((pwm * 100) / pwmMax);
  const toPwm = (percent: number) => Math.round((percent * pwmMax) / 100);
  return (
    <>
      <PanelSection title="POWER PROFILE">
        {power.error ? <Field label={power.error} /> : null}
        <SelectEdit
          label="Active profile"
          value={power.activeProfile}
          options={(power.profiles || []).map((label) => ({ data: label, label }))}
          onChange={selectProfile}
        />
        <div className="novadeck-field-note">
          Applies immediately, directly to the power daemon.
        </div>
      </PanelSection>
      {hasSchedulerChoice ? (
        <PanelSection title="CPU SCHEDULER">
          <SelectEdit
            label="Scheduler"
            value={power.cpuScheduler}
            options={schedulers.map((name) => ({
              data: name,
              label: name === "none" ? "Stock (EEVDF)" : name,
            }))}
            onChange={selectScheduler}
          />
          <div className="novadeck-field-note">
            {schedulerOverridden
              ? `The running game overrides this — ${
                  power.activeCpuScheduler === "none" ? "Stock (EEVDF)" : power.activeCpuScheduler
                } is loaded until it exits.`
              : "System-wide default. A game can override it from its own settings."}
          </div>
        </PanelSection>
      ) : null}
      {hasGpu ? (
        <PanelSection title="GPU CLOCK">
          <SelectEdit
            label="Frequency control"
            value={power.gpuLevel}
            options={gpuLevels.map((level) => ({ data: level, label: titleCase(level) }))}
            onChange={selectGpuLevel}
          />
          {power.gpuLevel === "manual" && clockKnown ? (
            <SliderEdit
              label="GPU clock (MHz)"
              value={power.manualGpuClock}
              min={power.manualGpuClockMin}
              max={power.manualGpuClockMax}
              step={10}
              onChange={dragClock}
            />
          ) : null}
          <div className="novadeck-field-note">
            Manual pins the GPU frequency; the active profile's limits no longer apply.
          </div>
        </PanelSection>
      ) : null}
      {hasCurve ? (
        <PanelSection title="FAN CURVE">
          <div className="novadeck-field-note">
            Fan speed at each temperature, for the {power.activeProfile} profile. Between
            two points the speed ramps smoothly.
          </div>
          {stops.map((stop, index) => (
            <SliderEdit
              key={stop}
              label={`${stop} °C`}
              value={toPercent(curve[index])}
              min={toPercent(pwmMin)}
              max={100}
              // 1%, even though powerd quantizes the applied PWM to 8/255 (~3%). The step is
              // not wasted precision: a control point also sets the slope of the interpolated
              // span either side of it, so a 1% move changes the speed at every temperature
              // between two stops, not just at the stop itself.
              step={1}
              onChange={(percent) => dragCurve(index, toPwm(percent))}
            />
          ))}
          {/* The only behaviour the sliders do not show for themselves: the curve is FLAT
              below the first stop, so that slider doubles as the idle speed. Deliberately no
              longer mentions the PWM floor — that is just this slider's minimum, which the
              slider already displays, and stating it next to a different number read as a
              contradiction. */}
          <div className="novadeck-field-note">
            {`Idles at ${toPercent(curve[0])}% — below ${stops[0]} °C the fan holds the ${stops[0]} °C speed.`}
          </div>
          {power.fanCurveCustom ? (
            <PanelSectionRow>
              <ButtonItem layout="below" onClick={resetCurve}>
                Reset to factory curve
              </ButtonItem>
            </PanelSectionRow>
          ) : null}
        </PanelSection>
      ) : null}
    </>
  );
}
