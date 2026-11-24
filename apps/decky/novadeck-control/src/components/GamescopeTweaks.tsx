import type { GameTweaks } from "../types";
import { SelectEdit, SliderEdit, ToggleRow } from "./widgets";

export const NICE_MIN = -20;
export const NICE_MAX = 19;

// "All cores" is a real choice here, unlike for a game: it lets one game clear a system-wide pin.
const GAMESCOPE_CORE_OPTIONS = [
  { data: "", label: "(unchanged)" },
  { data: "all", label: "All cores" },
  { data: "big", label: "Big cores" },
  { data: "prime", label: "Prime cores" },
  { data: "little", label: "Little cores" },
];

// The compositor's thread policy: system-wide in the Power tab, overridden per game in the Games tab.
export function GamescopeTweaks({ settings, disabled, patch }: {
  settings: GameTweaks;
  disabled?: boolean;
  patch: (changes: Partial<GameTweaks>) => void;
}) {
  return (
    <>
      <ToggleRow
        label="Set gamescope nice"
        value={settings.gamescopeNice !== undefined}
        disabled={disabled}
        onChange={(on) => patch({ gamescopeNice: on ? -5 : undefined })}
      />
      {settings.gamescopeNice !== undefined ? (
        <SliderEdit label="Gamescope nice" value={settings.gamescopeNice} min={NICE_MIN} max={NICE_MAX} step={1}
          disabled={disabled} onChange={(v) => patch({ gamescopeNice: v })} />
      ) : null}
      <SelectEdit label="Gamescope cores" value={settings.gamescopeCores || ""} options={GAMESCOPE_CORE_OPTIONS}
        disabled={disabled} onChange={(v) => patch({ gamescopeCores: v || undefined })} />
    </>
  );
}
