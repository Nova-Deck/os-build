import { PanelSection } from "@decky/ui";
import { useState } from "react";
import type { Dispatch, SetStateAction } from "react";
import { SelectEdit, SliderEdit, ToggleRow } from "../components/widgets";
import { editTargetOptions } from "../lib/games";
import { syncLaunchWrapper } from "../lib/launchWrapper";
import { clone } from "../lib/util";
import type { Config, GameTweaks } from "../types";

const CORE_OPTIONS = [
  { data: "", label: "(unchanged)" },
  { data: "all", label: "All cores" },
  { data: "big", label: "Big cores" },
  { data: "prime", label: "Prime cores" },
  { data: "little", label: "Little cores" },
];

// "" is absent-from-the-file, i.e. "follow the system-wide setting in the Power tab" — which is
// why "none" is spelled out separately: it is the only way to force stock for one title on a
// device whose system-wide choice is lavd.
const SCHEDULER_OPTIONS = [
  { data: "", label: "(unchanged)" },
  { data: "none", label: "Stock (EEVDF)" },
  { data: "lavd", label: "lavd" },
];

const NICE_MIN = -20;
const NICE_MAX = 19;

export function Games({ config, setConfig }: { config: Config; setConfig: Dispatch<SetStateAction<Config | null>> }) {
  // Default the editor to the running game — the common case is "tune what I'm playing".
  const [target, setTarget] = useState(config.game?.appid || "");
  const isGame = target !== "";
  const settings: GameTweaks = (isGame ? config.tweaks.games[target] : config.tweaks.global) || {};
  const gameEnabled = !isGame || settings.enabled === true;

  const patch = (changes: Partial<GameTweaks>) => {
    setConfig((current) => {
      if (!current) return current;
      const next = clone(current);
      const section = isGame
        ? (next.tweaks.games[target] = { ...(next.tweaks.games[target] || { enabled: true }) })
        : next.tweaks.global;
      for (const [key, value] of Object.entries(changes)) {
        // undefined is "remove the key": the consumers treat absence as "no opinion",
        // which is different from any concrete value.
        if (value === undefined) delete (section as any)[key];
        else (section as any)[key] = value;
      }
      return next;
    });
  };

  const removeGameEntry = () => {
    setConfig((current) => {
      if (!current || !isGame) return current;
      const next = clone(current);
      delete next.tweaks.games[target];
      return next;
    });
  };

  const fexOptions = [
    { data: "", label: "(unchanged)" },
    ...Object.entries(config.fexProfiles).map(([name, label]) => ({ data: name, label })),
  ];

  return (
    <>
      <PanelSection title="EDIT TARGET">
        <SelectEdit value={target} options={editTargetOptions(config)} onChange={setTarget} />
        {isGame ? (
          <ToggleRow
            label="Enable tweaks for this game"
            description="Off keeps the settings but stops applying them."
            value={settings.enabled === true}
            onChange={(on) => {
              // The launch-options wrapper rides the same switch, because it is what carries the
              // FEX half of these settings to a compat tool we do not own — Valve's arm64 Proton,
              // which Steam now picks by default. Fire-and-forget: it is best effort by contract,
              // and the tweaks themselves must save whether or not Steam accepted the write.
              void syncLaunchWrapper(target, on);
              if (settings.enabled === undefined && !on) removeGameEntry();
              else patch({ enabled: on });
            }}
          />
        ) : null}
      </PanelSection>
      <PanelSection title="GAME PROCESS TREE">
        <div className="novadeck-field-note">
          Applied to the whole running game tree within a few seconds — no relaunch needed.
        </div>
        <ToggleRow
          label="Set nice priority"
          value={settings.nice !== undefined}
          disabled={!gameEnabled}
          onChange={(on) => patch({ nice: on ? -5 : undefined })}
        />
        {settings.nice !== undefined ? (
          <SliderEdit label="Nice" value={settings.nice} min={NICE_MIN} max={NICE_MAX} step={1}
            disabled={!gameEnabled} onChange={(v) => patch({ nice: v })} />
        ) : null}
        <SelectEdit label="CPU cores" value={settings.cores || ""} options={CORE_OPTIONS}
          disabled={!gameEnabled} onChange={(v) => patch({ cores: v || undefined })} />
        {settings.cores ? (
          <ToggleRow
            label="Shape Wine CPU topology"
            description="Wine/Proton reports only the pinned cores. Takes effect on next launch."
            value={settings.wineTopology !== false}
            disabled={!gameEnabled}
            onChange={(on) => patch({ wineTopology: on ? undefined : false })}
          />
        ) : null}
      </PanelSection>
      <PanelSection title="GAMESCOPE">
        <div className="novadeck-field-note">
          Thread policy for the compositor while this target is running.
        </div>
        <ToggleRow
          label="Set gamescope nice"
          value={settings.gamescopeNice !== undefined}
          disabled={!gameEnabled}
          onChange={(on) => patch({ gamescopeNice: on ? -5 : undefined })}
        />
        {settings.gamescopeNice !== undefined ? (
          <SliderEdit label="Gamescope nice" value={settings.gamescopeNice} min={NICE_MIN} max={NICE_MAX} step={1}
            disabled={!gameEnabled} onChange={(v) => patch({ gamescopeNice: v })} />
        ) : null}
        <ToggleRow
          label="Realtime gamescope"
          description="SCHED_RR for the compositor threads."
          value={settings.gamescopeRr === true}
          disabled={!gameEnabled}
          onChange={(on) => patch({ gamescopeRr: on ? true : undefined })}
        />
        <SelectEdit label="Gamescope cores" value={settings.gamescopeCores || ""} options={CORE_OPTIONS}
          disabled={!gameEnabled} onChange={(v) => patch({ gamescopeCores: v || undefined })} />
      </PanelSection>
      <PanelSection title="CPU SCHEDULER">
        <div className="novadeck-field-note">
          Overrides the system-wide scheduler while this game runs, then restores it.
        </div>
        <SelectEdit label="Scheduler" value={settings.scheduler || ""} options={SCHEDULER_OPTIONS}
          disabled={!gameEnabled} onChange={(v) => patch({ scheduler: v || undefined })} />
      </PanelSection>
      <PanelSection title="X86 EMULATION">
        <div className="novadeck-field-note">
          FEX profile for x86 titles. Takes effect on next launch.
        </div>
        <SelectEdit label="FEX profile" value={settings.fexProfile || ""} options={fexOptions}
          disabled={!gameEnabled} onChange={(v) => patch({ fexProfile: v || undefined })} />
      </PanelSection>
    </>
  );
}
