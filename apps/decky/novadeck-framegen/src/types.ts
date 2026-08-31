/** One installed title, as Steam's own on-disk state describes it. */
export interface Game {
  appid: string;
  name: string;
  nonSteam?: boolean;
}

export interface DropdownChoice {
  data: any;
  label: string;
}

/** Per-game tuning. Mirrors the three keys lsfg-vk hot-reloads from conf.toml; the names are
 *  camelCase across the wire and snake_case in the file, which the backend translates. */
export interface Profile {
  multiplier: number;
  flowScale: number;
  performanceMode: boolean;
}

/** Why frame generation is or is not usable. `reason` is a stable token so the panel picks its
 *  own wording; `detail` is the backend's human sentence for the cases the panel does not
 *  special-case. See py_modules/novadeck_framegen/prereq.py for the four failure modes. */
export interface Prereq {
  ready: boolean;
  reason: "ok" | "no-layer" | "no-guest" | "not-installed" | "no-dll" | "wrong-branch";
  detail: string;
  dll: string | null;
}

export interface Defaults extends Profile {
  /** The devicetree SoC string the flow-scale default was chosen from, shown so a surprising
   *  default is traceable rather than mysterious. */
  soc: string;
}

export interface State {
  prereq: Prereq;
  defaults: Defaults;
  games: Game[];
  profiles: Record<string, Profile>;
  enabled: string[];
  /** appids the control plugin has per-game TUNING enabled for. Separate opt-in from
   *  frame generation; both need the launch wrapper, so it may only be removed when
   *  neither wants it. */
  tweaked: string[];
}
