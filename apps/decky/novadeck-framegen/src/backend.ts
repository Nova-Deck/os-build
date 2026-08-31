import { call } from "@decky/api";
import type { Profile, State } from "./types";

// Every mutating call returns the WHOLE new state, not an acknowledgement: two files back this
// panel (lsfg-vk's conf.toml and game-tweaks.json), novadeck-control writes one of them and the
// layer itself writes the other, so re-reading beats trusting an optimistic local update.
export const getState = () => call<[], State>("get_state");
export const setEnabled = (appid: string, on: boolean) => call<[string, boolean], State>("set_enabled", appid, on);
export const setSettings = (appid: string, settings: Profile) => call<[string, Profile], State>("set_settings", appid, settings);
