/** The read-only slice of powerd the panel renders. novadeck-control owns the full
 *  PowerStatus (capability lists, the fan curve, every setter); this is deliberately the
 *  nine properties the Monitor displays and nothing more — see py_modules/…/powerd.py. */
export interface PowerSnapshot {
  /** The system-wide choice. */
  profile: string;
  /** What is in force now; differs from profile only under a per-game override. */
  activeProfile: string;
  /** The system-wide choice. */
  cpuScheduler: string;
  /** What is loaded now; differs from cpuScheduler only under a per-game override. */
  activeCpuScheduler: string;
  fanPwm: number;
  fanRpm: number;
  /** The ACTIVE profile's curve ceiling — what the fan bar is scaled against. */
  fanCurveMaxPwm: number;
  /** powerd's blended, smoothed curve input. NOT the raw per-zone readings below. */
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
  power: PowerSnapshot;
}
