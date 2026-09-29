import { ButtonItem, Field, PanelSection, PanelSectionRow } from "@decky/ui";
import { useEffect, useRef } from "react";
import type { Dispatch, SetStateAction } from "react";
import { getPowerStatus, resetFanCurve, setCpuScheduler, setFanCurve } from "../backend";
import { SelectEdit, SliderEdit } from "../components/widgets";
import type { Config, PowerStatus } from "../types";

// The power profile and the GPU clock are not here: Steam's own Performance panel owns both,
// globally and per game. This tab carries what Steam has no control for.
export function Power({ config, setConfig }: { config: Config; setConfig: Dispatch<SetStateAction<Config | null>> }) {
  const power = config.power;
  // A slider drag is dozens of onChange events, and every curve set makes powerd rewrite its
  // drop-in and re-read the whole three-layer config — so trail the drag instead of racing it.
  // The poll below skips while a set is pending so a just-dragged value is not snapped back by
  // a stale read.
  const curveTimer = useRef<number | null>(null);
  const pendingCurve = useRef<number[] | null>(null);

  const adopt = (next: PowerStatus) => {
    setConfig((current) => (current ? { ...current, power: next } : current));
  };

  // The state changes under us — Steam switches the profile at every game launch and exit when
  // per-game settings are on, and the curve shown must follow — so poll while the tab is mounted.
  useEffect(() => {
    let cancelled = false;
    const refresh = async () => {
      if (pendingCurve.current !== null) return;
      try {
        const next = await getPowerStatus();
        if (!cancelled && pendingCurve.current === null) adopt(next);
      } catch (error) {
        // transient bus hiccups just skip a poll
      }
    };
    const timer = window.setInterval(refresh, 2000);
    refresh();
    return () => {
      cancelled = true;
      window.clearInterval(timer);
      if (curveTimer.current !== null) window.clearTimeout(curveTimer.current);
    };
  }, []);

  const selectScheduler = async (scheduler: string) => {
    adopt({ ...power, cpuScheduler: scheduler });
    try {
      adopt(await setCpuScheduler(scheduler));
    } catch (error) {
      // the next poll restores the truth
    }
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
  // Capability by enumeration: powerd serves ["none"] alone when the kernel has no sched_ext or
  // the scx binary is missing, and a lone option is not a choice.
  const schedulers = power.cpuSchedulers || [];
  const hasSchedulerChoice = schedulers.length > 1;
  // powerd reports the loaded scheduler separately, so a per-game override is stated rather than
  // left as a dropdown that silently disagrees with the machine.
  const schedulerOverridden =
    !!power.activeCpuScheduler && power.activeCpuScheduler !== power.cpuScheduler;
  // Same rule again: no stops means a powerd that does not serve the curve, and a fan the daemon
  // cannot see means nothing to edit.
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
      {power.error ? (
        <PanelSection>
          <Field label={power.error} />
        </PanelSection>
      ) : null}
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
      {hasCurve ? (
        <PanelSection title="FAN CURVE">
          <div className="novadeck-field-note">
            Fan speed at each temperature, for the <b>{power.profile}</b> profile — the one selected in
            Steam's Performance panel. Between two points the speed ramps smoothly.
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
