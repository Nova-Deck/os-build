import { PanelSection } from "@apps/decky/ui";
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

// Profile IDS with their stock labels. Hardcoded for the same reason SCHEDULER_OPTIONS is:
// powerd's AvailableProfiles enumerates LABELS only (an operator may rename them in
// power-profiles.conf), while the tweaks file speaks ids — so there is nothing to derive this
// from. "" is absent-from-the-file, i.e. "follow the Power tab's system-wide profile".
const POWER_PROFILE_OPTIONS = [
  { data: "", label: "(unchanged)" },
  { data: "eco", label: "Eco" },
  { data: "balanced", label: "Balanced" },
  { data: "performance", label: "Performance" },
];

// Tri-state on purpose, and the third state is the default (issue #47). FEX applies ThunksDB
// per library name across every config layer, ours last — so writing an entry PINS that thunk
// over whatever the FEX running the game decided (for native x86 titles that is Valve's compat
// tool and its per-title curation). A plain checkbox would write a value for every thunk and
// silently seize all of it; only the two explicit states may reach game-tweaks.json.
const THUNK_OPTIONS = [
  { data: "", label: "(as shipped)" },
  { data: "on", label: "Force on" },
  { data: "off", label: "Force off" },
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

  const thunkValue = (name: string) => {
    const chosen = settings.thunks ? settings.thunks[name] : undefined;
    return chosen === undefined ? "" : chosen ? "on" : "off";
  };
  const setThunk = (name: string, state: string) => {
    // "(as shipped)" removes the entry, and an emptied map removes the `thunks` key itself —
    // absence is the contract (see THUNK_OPTIONS), and game-launch then emits no ThunksDB at all.
    const next = { ...(settings.thunks || {}) };
    if (state === "") delete next[name];
    else next[name] = state === "on";
    patch({ thunks: Object.keys(next).length > 0 ? next : undefined });
  };

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
      {/* Both of these override a SYSTEM-WIDE setting whose only home is the Power tab, so the
          consumers read them per-game and ignore them in `global` — offering them on the global
          target would be a control that writes a key nothing acts on. */}
      {isGame ? (
        <>
          <PanelSection title="POWER PROFILE">
            <div className="novadeck-field-note">
              Overrides the system-wide profile while this game runs, then restores it. Brings the
              whole profile — CPU and GPU limits and the fan curve.
            </div>
            <SelectEdit label="Profile" value={settings.powerProfile || ""} options={POWER_PROFILE_OPTIONS}
              disabled={!gameEnabled} onChange={(v) => patch({ powerProfile: v || undefined })} />
          </PanelSection>
          <PanelSection title="CPU SCHEDULER">
            <div className="novadeck-field-note">
              Overrides the system-wide scheduler while this game runs, then restores it.
            </div>
            <SelectEdit label="Scheduler" value={settings.scheduler || ""} options={SCHEDULER_OPTIONS}
              disabled={!gameEnabled} onChange={(v) => patch({ scheduler: v || undefined })} />
          </PanelSection>
        </>
      ) : null}
      <PanelSection title="X86 EMULATION">
        <div className="novadeck-field-note">
          FEX profile for x86 titles. Takes effect on next launch.
        </div>
        <SelectEdit label="FEX profile" value={settings.fexProfile || ""} options={fexOptions}
          disabled={!gameEnabled} onChange={(v) => patch({ fexProfile: v || undefined })} />
      </PanelSection>
      {/* Per-game only, though the consumer would honour a global map too: forcing a thunk is a
          known-crashy experiment (see the note below), so it stays scoped to one title. */}
      {isGame && config.fexThunks.length > 0 ? (
        <PanelSection title="FEX THUNKS">
          <div className="novadeck-field-note">
            Routes a guest library to the host driver. Ours ship OFF on purpose — host GPU thunks
            are known to crash native x86-64 Linux games. Forcing one is an experiment, not a fix.
            Takes effect on next launch.
          </div>
          {config.fexThunks.map((name) => (
            <SelectEdit key={name} label={name} value={thunkValue(name)} options={THUNK_OPTIONS}
              disabled={!gameEnabled} onChange={(v) => setThunk(name, v)} />
          ))}
        </PanelSection>
      ) : null}
    </>
  );
}
