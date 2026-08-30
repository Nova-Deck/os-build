export interface GameTweaks {
  enabled?: boolean;
  nice?: number;
  cores?: string;
  wineTopology?: boolean;
  gamescopeNice?: number;
  gamescopeRr?: boolean;
  gamescopeCores?: string;
  /** Modifier on `cores`: narrow the selection to exactly ONE cpu (the fastest of those
   *  chosen, ties by lowest cpu number). Meaningful on its own, where it narrows all online
   *  cpus. Never applied to gamescopeCores. */
  singleCore?: boolean;
  /** Per-game only — the system-wide scheduler is PowerStatus.cpuScheduler, not a tweak. */
  scheduler?: string;
  /** Per-game only, same rule: the system-wide profile is PowerStatus.profile. A profile ID
   *  ("eco"/"balanced"/"performance"), never the UI label. */
  powerProfile?: string;
  fexProfile?: string;
  /** EXPLICIT overrides only — an entry pins that thunk at FEX's highest config priority,
   *  over Valve's per-title curation. "As shipped" is NO entry, never `false`. */
  thunks?: Record<string, boolean>;
  env?: Record<string, string | null>;
  [key: string]: any;
}

export interface Tweaks {
  global: GameTweaks;
  games: Record<string, GameTweaks>;
}

export interface PowerStatus {
  /** UI labels, in profile order — the dropdown's options and what `profile` speaks. */
  profiles: string[];
  /** The system-wide choice. */
  profile: string;
  /** What is in force now; differs from profile only under a per-game override. */
  activeProfile: string;
  gpuLevels: string[];
  gpuLevel: string;
  manualGpuClock: number;
  manualGpuClockMin: number;
  manualGpuClockMax: number;
  /** Empty or ["none"] alone on a device without sched_ext — hide the control then. */
  cpuSchedulers: string[];
  /** The system-wide choice. */
  cpuScheduler: string;
  /** What is loaded now; differs from cpuScheduler only under a per-game override. */
  activeCpuScheduler: string;
  /** PWM per stop, for the ACTIVE profile. Same length as fanCurveStops. */
  fanCurve: number[];
  /** The temperatures fanCurve is sampled at. Empty on a powerd too old to serve it. */
  fanCurveStops: number[];
  fanCurveMinPwm: number;
  fanCurveMaxPwm: number;
  /** False while the profile is still on its factory curve — gates the Reset button. */
  fanCurveCustom: boolean;
  fanPwm: number;
  fanRpm: number;
  temperature: number;
  error: string;
}

export interface InstalledGame {
  appid: string;
  name: string;
  nonSteam?: boolean;
}

export interface GameRef {
  appid: string;
  name: string;
}

export interface Config {
  tweaks: Tweaks;
  fexProfiles: Record<string, string>;
  /** Thunk names from the base FEX config's ThunksDB — the namespace the UI may offer.
   *  game-launch ignores any name not in the base, so there is nothing else worth listing. */
  fexThunks: string[];
  power: PowerStatus;
  osVersion: string;
  installedGames?: InstalledGame[];
  game?: GameRef | null;
}

export interface DropdownChoice {
  data: any;
  label: string;
}
