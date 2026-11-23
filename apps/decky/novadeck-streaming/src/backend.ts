import { call } from "@decky/api";
import type { State } from "./types";

// Every mutating call returns the whole new state, with `problem` set when it did not happen.
export const getState = () => call<[], State>("get_state");
export const setHosting = (on: boolean) => call<[boolean], State>("set_hosting", on);
export const pair = (id: string, pin: string) => call<[string, string], State>("pair", id, pin);
export const disconnect = (uuid: string) => call<[string], State>("disconnect", uuid);
export const allow = (uuid: string) => call<[string], State>("allow", uuid);
export const remove = (uuid: string) => call<[string], State>("remove", uuid);
