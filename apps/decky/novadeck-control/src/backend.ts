import { call } from "@decky/api";
import type {
  Config,
  InstalledGame,
  PanelCalibrateResult,
  PanelSaveResult,
  PanelStatus,
  PanelValueResult,
  PowerStatus,
  Tweaks,
} from "./types";

export const getConfig = () => call<[], Config>("get_config");
export const getInstalledGames = () => call<[], InstalledGame[]>("get_installed_games");
export const saveTweaks = (data: Tweaks) => call<[Tweaks], Tweaks>("save_tweaks", data);
export const getPowerStatus = () => call<[], PowerStatus>("get_power_status");
export const setCpuScheduler = (scheduler: string) => call<[string], PowerStatus>("set_cpu_scheduler", scheduler);
export const setFanCurve = (pwms: number[]) => call<[number[]], PowerStatus>("set_fan_curve", pwms);
export const resetFanCurve = (every: boolean) => call<[boolean], PowerStatus>("reset_fan_curve", every);
export const getPanelStatus = () => call<[], PanelStatus>("get_panel_status");
/** Blocks for the whole calibration run — ~1.5-3 s. Leaves the value live, unsaved. */
export const calibratePanel = () => call<[], PanelCalibrateResult>("calibrate_panel");
export const setPanel = (rate: number, value: number) => call<[number, number], PanelValueResult>("set_panel", rate, value);
export const savePanel = (rate: number) => call<[number], PanelSaveResult>("save_panel", rate);
export const revertPanel = (rate: number) => call<[number], PanelValueResult>("revert_panel", rate);
