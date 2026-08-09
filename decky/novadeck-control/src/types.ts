export interface GameTweaks {
  enabled?: boolean;
  nice?: number;
  cores?: string;
  wineTopology?: boolean;
  gamescopeNice?: number;
  gamescopeRr?: boolean;
  gamescopeCores?: string;
  /** Per-game only — the system-wide scheduler is PowerStatus.cpuScheduler, not a tweak. */
  scheduler?: string;
  fexProfile?: string;
  env?: Record<string, string | null>;
  [key: string]: any;
}

export interface Tweaks {
  global: GameTweaks;
  games: Record<string, GameTweaks>;
}

export interface PowerStatus {
  profiles: string[];
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

export interface CpuCluster {
  /** The policy's affected_cpus, verbatim ("0-1"). */
  cores: string;
  khz: number;
  /** scaling_max_freq — the cap the active profile really imposes, not the silicon's. */
  maxKhz: number;
  governor: string;
}

export interface Telemetry {
  cpuPercent: number;
  cpuClusters: CpuCluster[];
  gpu: { hz: number; maxHz: number; governor: string };
  /** Hottest CPU and GPU zone, raw. Not powerd's blended curve input — see telemetry.py. */
  temperatures: { cpuC: number; gpuC: number };
  memory: { usedMb: number; totalMb: number; percent: number };
  loadAverage: number[];
  /** Fan and temperature come from powerd, which owns them; see telemetry.py. */
  power: PowerStatus;
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
  power: PowerStatus;
  osVersion: string;
  installedGames?: InstalledGame[];
  game?: GameRef | null;
}

export interface DropdownChoice {
  data: any;
  label: string;
}
