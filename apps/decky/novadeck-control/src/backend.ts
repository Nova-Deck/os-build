import { call } from "@decky/api";
import type { Config, InstalledGame, PowerStatus, Tweaks } from "./types";

export const getConfig = () => call<[], Config>("get_config");
export const getInstalledGames = () => call<[], InstalledGame[]>("get_installed_games");
export const saveTweaks = (data: Tweaks) => call<[Tweaks], Tweaks>("save_tweaks", data);
export const getPowerStatus = () => call<[], PowerStatus>("get_power_status");
export const setCpuScheduler = (scheduler: string) => call<[string], PowerStatus>("set_cpu_scheduler", scheduler);
export const setFanCurve = (pwms: number[]) => call<[number[]], PowerStatus>("set_fan_curve", pwms);
export const resetFanCurve = (every: boolean) => call<[boolean], PowerStatus>("reset_fan_curve", every);
