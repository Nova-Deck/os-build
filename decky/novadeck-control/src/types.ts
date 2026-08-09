export interface GameTweaks {
  enabled?: boolean;
  nice?: number;
  cores?: string;
  wineTopology?: boolean;
  gamescopeNice?: number;
  gamescopeRr?: boolean;
  gamescopeCores?: string;
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
  power: PowerStatus;
  osVersion: string;
  installedGames?: InstalledGame[];
  game?: GameRef | null;
}

export interface DropdownChoice {
  data: any;
  label: string;
}
