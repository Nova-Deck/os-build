import { PanelSection, PanelSectionRow, Field } from "@decky/ui";
import { useEffect, useState } from "react";
import { SelectEdit, SliderEdit, ToggleRow } from "./components/widgets";
import { getState, setEnabled, setSettings } from "./backend";
import { syncLaunchWrapper } from "./lib/launchWrapper";
import { styles } from "./styles";
import type { Profile, State } from "./types";

// Upstream's own bounds (config.cpp): below 2 generates nothing, and flow scale outside
// 0.25-1.0 is rejected. The backend clamps too -- this keeps the slider from offering a value
// that would be silently changed underneath it.
const MULTIPLIER_OPTIONS = [
  { data: 2, label: "2x" },
  { data: 3, label: "3x" },
  { data: 4, label: "4x" },
];

// The prerequisite the user can actually act on gets a headline of its own; everything else
// falls through to the backend's sentence. `wrong-branch` is first because it is the one nobody
// guesses and the one that otherwise fails by naming a shader.
const PREREQ_TITLE: Record<string, string> = {
  "wrong-branch": "Switch Lossless Scaling to the lsfg-vk branch",
  "not-installed": "Lossless Scaling is required",
  "no-dll": "Lossless Scaling looks incomplete",
  "no-guest": "The x86 game environment is not mounted",
  "no-layer": "This image has no frame-generation layer",
};

// MODULE SCOPE ON PURPOSE, not component state.
//
// The selected game did not stick: pick one from the dropdown and the panel forgot it
// immediately (HW 2026-08-30). Decky renders the dropdown as a modal over the Quick Access
// panel, and the panel below it does not reliably stay mounted while that modal is up -- so the
// `target` useState was being discarded between opening the list and choosing from it.
// novadeck-control does not hit this because its panel sets alwaysRender and stays mounted.
//
// Copying alwaysRender here would be the wrong fix twice over: it is a cure for a cause we would
// only be GUESSING at, and it keeps the panel mounted for the whole session, which the second
// plugin was deliberately built not to do. Holding the selection outside the component fixes the
// symptom whatever unmounted it, and costs one module-level string.
//
// The last state is cached alongside it so a remount re-renders the panel it had rather than
// flashing "Loading..." on the way back.
let lastTarget = "";
let lastState: State | null = null;

export function Content() {
  const [state, setState] = useState<State | null>(lastState);
  const [target, setTargetLocal] = useState(lastTarget);
  const [busy, setBusy] = useState(false);

  const setTarget = (value: string) => {
    lastTarget = value;
    setTargetLocal(value);
  };
  const keepState = (next: State | null) => {
    lastState = next;
    setState(next);
  };

  // Still re-read on every mount: game-tweaks.json has another writer (novadeck-control) and
  // conf.toml has two more (the layer, and the user), so the cache is a rendering convenience
  // and never the source of truth.
  useEffect(() => {
    getState().then(keepState).catch(() => { /* keep the cached panel rather than blanking it */ });
  }, []);

  if (!state) {
    return (
      <PanelSection>
        <PanelSectionRow><Field label="Loading…" /></PanelSectionRow>
      </PanelSection>
    );
  }

  const { prereq, defaults, games, profiles } = state;

  if (!prereq.ready) {
    return (
      <div className="novadeck-framegen">
        <style>{styles}</style>
        <PanelSection title="Frame generation">
          <PanelSectionRow>
            <Field
              label={PREREQ_TITLE[prereq.reason] || "Frame generation is unavailable"}
              description={prereq.detail}
              childrenLayout="below"
            />
          </PanelSectionRow>
        </PanelSection>
      </div>
    );
  }

  const enabled = new Set(state.enabled);
  // Games the control plugin has per-game TUNING on for. Tracked here only so the launch
  // wrapper is not pulled out from under it -- see the toggle below.
  const tweaked = new Set(state.tweaked || []);
  // Only games with an entry are listed under "configured", but the picker offers everything:
  // the common case is turning it on for something for the first time.
  const gameOptions = [
    { data: "", label: "Select a game…" },
    ...games.map((game) => ({
      data: game.appid,
      label: enabled.has(game.appid) ? `${game.name}  •  on` : game.name,
    })),
  ];

  const settings: Profile = profiles[target] || {
    multiplier: defaults.multiplier,
    flowScale: defaults.flowScale,
    performanceMode: defaults.performanceMode,
  };
  const isOn = target !== "" && enabled.has(target);

  const toggle = async (on: boolean) => {
    if (!target || busy) return;
    setBusy(true);
    try {
      // The launch wrapper is what makes game-launch run at all, and without it the env this
      // writes is never applied -- the panel would say "on" and nothing would happen. It is
      // best-effort by contract (a game must never fail to launch because we could not write a
      // launch option), so its result is not allowed to block the state change.
      // BOTH features need the wrapper, so it may only be REMOVED when neither wants it.
      // Unwrapping just because frame generation went off would silently stop the user's
      // cores/scheduler/FEX tuning from being applied, with nothing to explain why.
      await syncLaunchWrapper(target, on || tweaked.has(target));
      keepState(await setEnabled(target, on));
    } catch {
      // Re-read rather than guess: something else may have changed the file underneath us.
      try { keepState(await getState()); } catch { /* leave the last good state on screen */ }
    } finally {
      setBusy(false);
    }
  };

  const patch = async (changes: Partial<Profile>) => {
    if (!target || busy) return;
    const next = { ...settings, ...changes };
    // Optimistic locally so the slider tracks the thumb, then reconciled from the backend.
    keepState({ ...state, profiles: { ...profiles, [target]: next } });
    try {
      keepState(await setSettings(target, next));
    } catch {
      try { keepState(await getState()); } catch { /* keep what is on screen */ }
    }
  };

  return (
    <div className="novadeck-framegen">
      <style>{styles}</style>
      <PanelSection title="Frame generation">
        <SelectEdit label="Game" value={target} options={gameOptions} onChange={setTarget} />

        {target === "" ? (
          <PanelSectionRow>
            <Field
              label="Pick a game"
              description="Frame generation is set per game. Nothing is changed for titles you do not turn it on for."
              childrenLayout="below"
            />
          </PanelSectionRow>
        ) : (
          <>
            <ToggleRow
              label="Frame generation"
              value={isOn}
              disabled={busy}
              onChange={toggle}
              description={isOn
                ? "Generated frames are inserted while this game runs."
                : "Off. This game runs unchanged."}
            />

            {isOn && (
              <>
                <SelectEdit
                  label="Multiplier"
                  value={settings.multiplier}
                  options={MULTIPLIER_OPTIONS}
                  onChange={(multiplier: number) => patch({ multiplier })}
                />
                <SliderEdit
                  label="Motion detail"
                  value={settings.flowScale}
                  min={0.25}
                  max={1}
                  step={0.05}
                  onChange={(flowScale: number) => patch({ flowScale })}
                />
                {/* A REAL toggle, defaulted on, not a label that looks like one. It was
                    originally a plain Field stating that the fast model was in use -- which
                    read as a setting that would not change (HW feedback 2026-08-30). Two
                    problems with that: a row styled like every other row should behave like
                    them, and the choice is not actually ours to remove. The quality model is
                    unusable at PANEL resolution on all three parts (23.97ms even on the
                    fastest, against 16.67ms for 60fps) but it fits at 720p on this GPU
                    (12.03ms), so a game rendering internally at a lower resolution is a real
                    case for it. Offer it, default it off, and say what it costs. */}
                <ToggleRow
                  label="Fast model"
                  value={settings.performanceMode}
                  onChange={(performanceMode: boolean) => patch({ performanceMode })}
                  description={settings.performanceMode
                    ? "Recommended. The higher-quality model costs roughly 8x more GPU time on this hardware."
                    : "Higher quality, much slower — measured at 24ms per generated frame at 1080p on this GPU, against 16.7ms for 60fps. Expect well under 60fps unless the game renders at a lower resolution."}
                />
                <PanelSectionRow>
                  <Field
                    description="Enable Vsync in the game's own settings. Frame generation paces itself against it, and without it frames are dropped instead of shown."
                    childrenLayout="below"
                  />
                </PanelSectionRow>
              </>
            )}
          </>
        )}
      </PanelSection>
    </div>
  );
}
