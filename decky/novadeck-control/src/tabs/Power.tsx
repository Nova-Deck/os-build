import { Field, PanelSection } from "@decky/ui";
import { useEffect, useRef } from "react";
import type { Dispatch, SetStateAction } from "react";
import { getPowerStatus, setActiveProfile, setCpuScheduler, setGpuLevel, setManualGpuClock } from "../backend";
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

  const adopt = (next: PowerStatus) => {
    setConfig((current) => (current ? { ...current, power: next } : current));
  };

  // The state can change under us (powerd, boot defaults, another session), so poll while the
  // tab is mounted. Profile and level sets are deliberate single actions — no debounce.
  useEffect(() => {
    let cancelled = false;
    const refresh = async () => {
      if (pendingClock.current !== null) return;
      try {
        const next = await getPowerStatus();
        if (!cancelled && pendingClock.current === null) adopt(next);
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
    </>
  );
}
