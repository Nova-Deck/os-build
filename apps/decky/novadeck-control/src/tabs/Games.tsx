import { PanelSection } from "@decky/ui";
import { useState } from "react";
import type { Dispatch, SetStateAction } from "react";
import { GamescopeTweaks, NICE_MAX, NICE_MIN } from "../components/GamescopeTweaks";
import { ButtonRow, SelectEdit, SliderEdit, ToggleRow } from "../components/widgets";
import { editTargetOptions, knownGameName } from "../lib/games";
import { syncLaunchWrapper } from "../lib/launchWrapper";
import { applyChanges, clone } from "../lib/util";
import type { Config, GameTweaks } from "../types";

const CORE_OPTIONS = [
  { data: "", label: "(unchanged)" },
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

// "" is absent-from-the-file: the game follows what the session started gamescope with
// (session.conf's gamescope_auto_hdr, off by default). "off" is spelled out for the same reason
// as the scheduler's "none": a session that turns AutoHDR on for everything can exempt one title.
const AUTO_HDR_OPTIONS = [
  { data: "", label: "(unchanged)" },
  { data: "on", label: "On" },
  { data: "off", label: "Off" },
];

export function Games({ config, setConfig }: { config: Config; setConfig: Dispatch<SetStateAction<Config | null>> }) {
  // Default the editor to the running game — the common case is "tune what I'm playing".
  const [target, setTarget] = useState(config.game?.appid || "");
  const isGame = target !== "";
  const settings: GameTweaks = (isGame && config.tweaks.games[target]) || {};
  const gameEnabled = settings.enabled === true;
  // "all" in an older file is no pin, so it shows as none.
  const cores = settings.cores === "all" ? "" : settings.cores || "";

  const patch = (changes: Partial<GameTweaks>) => {
    setConfig((current) => {
      if (!current || !isGame) return current;
      const next = clone(current);
      const section: GameTweaks = { ...(next.tweaks.games[target] || { enabled: true }) };
      next.tweaks.games[target] = section;
      // Cache the display name alongside the settings. Names are otherwise read from Steam's
      // appmanifest, which the uninstall deletes — and these entries outlive the install, so
      // without this the dropdown shows a bare "App <id>" for settings that are still live.
      // Only ever written when a name is actually resolvable: a blank must not overwrite a
      // good cached one, which is what happens when the entry is edited while uninstalled.
      const known = knownGameName(current, target);
      if (known) section.name = known;
      applyChanges(section, changes);
      return next;
    });
  };

  // Keys in a game section that belong to the FRAME GENERATION panel, not to us. We never write
  // either: `framegen` is that panel's opt-in, and `env` carries the DISABLE_LSFGVK tombstone and
  // profile name it applies through. Deleting our settings must leave them alone — the two panels
  // share one file per game, and wiping the other's half from ours would switch frame generation
  // off in a screen the user is not looking at, with nothing to say so.
  const FRAMEGEN_KEYS = ["framegen", "env"];

  // Frame generation's own opt-in, read straight from the shared section. No backend round-trip
  // needed: the section we are editing is the section that holds it.
  const framegenOn = isGame && (settings as any).framegen === true;

  // Drop OUR settings from the section, preserving the frame-generation half, and remove the
  // section only when nothing meaningful is left. `name` is a display cache rather than a
  // setting, so a section reduced to just that counts as empty — the same rule the frame-gen
  // writer applies, so the two cannot disagree about when an entry is litter.
  const removeGameEntry = () => {
    setConfig((current) => {
      if (!current || !isGame) return current;
      const next = clone(current);
      const existing: any = next.tweaks.games[target];
      if (!existing) return next;
      const kept: any = {};
      for (const key of FRAMEGEN_KEYS) {
        if (existing[key] !== undefined) kept[key] = existing[key];
      }
      if (Object.keys(kept).length > 0) {
        if (existing.name) kept.name = existing.name;
        next.tweaks.games[target] = kept;
      } else {
        delete next.tweaks.games[target];
      }
      return next;
    });
  };

  // Does this target actually have stored settings? Selecting a game in the dropdown does not
  // create an entry — only editing one does — so the delete affordance must key on the entry
  // existing, not on a game being selected.
  const hasEntry = isGame && config.tweaks.games[target] !== undefined;

  const deleteGameEntry = () => {
    // Drop the launch-options wrapper too — but ONLY if frame generation does not still want it.
    // BOTH features run through game-launch, so unwrapping because our settings went away would
    // silently stop frame generation from being applied while its own panel still reads "on".
    // This is the mirror of the check that panel already makes before unwrapping on our behalf.
    void syncLaunchWrapper(target, framegenOn);
    removeGameEntry();
    // The entry is gone, so the target it names no longer exists unless the game is installed.
    // Falling back to no target also makes the deletion visible: the row disappears from the list.
    setTarget("");
  };

  const fexOptions = [
    { data: "", label: "(unchanged)" },
    ...Object.entries(config.fexProfiles).map(([name, label]) => ({ data: name, label })),
  ];

  // A profile this image does not ship (an older file may say "default") applies nothing, and shows so.
  const fexProfile = settings.fexProfile && config.fexProfiles[settings.fexProfile] ? settings.fexProfile : "";

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
              //
              // It may only be REMOVED when frame generation does not want it either. Both
              // features run through game-launch, so switching our tuning off used to unwrap
              // unconditionally and silently stop frame generation being applied, while its own
              // panel still read "on". That panel already guards the reverse direction.
              void syncLaunchWrapper(target, on || framegenOn);
              if (settings.enabled === undefined && !on) removeGameEntry();
              else patch({ enabled: on });
            }}
          />
        ) : null}
        {hasEntry ? (
          <ButtonRow
            label="Remove these settings"
            description="Deletes this game's entry and its launch-options wrapper. The toggle above only stops applying the settings; this is what discards them."
            onClick={deleteGameEntry}
          />
        ) : null}
      </PanelSection>
      {/* Every setting below is this game's own. What is system-wide lives in the Power tab. */}
      {isGame ? (
        <>
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
            <SelectEdit label="CPU cores" value={cores} options={CORE_OPTIONS}
              disabled={!gameEnabled} onChange={(v) => patch({ cores: v || undefined })} />
            <ToggleRow
              label="Pin to a single core"
              description="Narrows the selection above to one core, the fastest of those chosen. Fixes older games whose threading breaks across many cores."
              value={settings.singleCore === true}
              disabled={!gameEnabled}
              onChange={(on) => patch({ singleCore: on ? true : undefined })}
            />
            {cores || settings.singleCore ? (
              <ToggleRow
                label="Shape Wine CPU topology"
                description="Wine/Proton reports only the pinned cores. Off: the game sees every core but still runs on the pinned ones. Takes effect on next launch."
                value={settings.wineTopology !== false}
                disabled={!gameEnabled}
                onChange={(on) => patch({ wineTopology: on ? undefined : false })}
              />
            ) : null}
          </PanelSection>
          <PanelSection title="GAMESCOPE">
            <div className="novadeck-field-note">
              Thread policy for the compositor while this game runs. Overrides the Power tab's.
            </div>
            <GamescopeTweaks settings={settings} disabled={!gameEnabled} patch={patch} />
          </PanelSection>
          {/* Overrides a system-wide setting whose only home is the Power tab. There is no per-game
              power profile here: Steam's own per-game performance settings own the profile and the
              GPU clock. */}
          <PanelSection title="CPU SCHEDULER">
            <div className="novadeck-field-note">
              Overrides the system-wide scheduler while this game runs, then restores it.
            </div>
            <SelectEdit label="Scheduler" value={settings.scheduler || ""} options={SCHEDULER_OPTIONS}
              disabled={!gameEnabled} onChange={(v) => patch({ scheduler: v || undefined })} />
          </PanelSection>
          {/* The system-wide value is gamescope's launch value, and only on a board with an HDR panel:
              elsewhere powerd ignores the key, so the control would write a setting nothing acts on. */}
          {config.hdrPanel ? (
            <PanelSection title="HDR">
              <div className="novadeck-field-note">
                AutoHDR expands this game's SDR picture to HDR while it runs, then restores the
                session's setting. Games that output HDR themselves are left alone. Applied within a
                few seconds — no relaunch needed.
              </div>
              <SelectEdit
                label="AutoHDR"
                value={settings.autoHdr === undefined ? "" : settings.autoHdr ? "on" : "off"}
                options={AUTO_HDR_OPTIONS}
                disabled={!gameEnabled}
                onChange={(v) => patch({ autoHdr: v === "" ? undefined : v === "on" })}
              />
            </PanelSection>
          ) : null}
          <PanelSection title="X86 EMULATION">
            <div className="novadeck-field-note">
              FEX profile for x86 titles. Takes effect on next launch.
            </div>
            <SelectEdit label="FEX profile" value={fexProfile} options={fexOptions}
              disabled={!gameEnabled} onChange={(v) => patch({ fexProfile: v || undefined })} />
          </PanelSection>
          {config.fexThunks.length > 0 ? (
            <PanelSection title="FEX THUNKS">
              <div className="novadeck-field-note">
                Routes a guest library to the host driver. Ours ship OFF on purpose — host GPU thunks
                are known to crash native x86-64 Linux games. Forcing one is an experiment, not a fix.
                Takes effect on next launch.
              </div>
              <div className="novadeck-field-note">
                No effect on games running on an arm64 Proton: their graphics calls already go to the
                host driver.
              </div>
              {config.fexThunks.map((name) => (
                <SelectEdit key={name} label={name} value={thunkValue(name)} options={THUNK_OPTIONS}
                  disabled={!gameEnabled} onChange={(v) => setThunk(name, v)} />
              ))}
            </PanelSection>
          ) : null}
        </>
      ) : null}
    </>
  );
}
