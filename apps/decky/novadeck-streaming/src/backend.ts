import { call } from "@decky/api";
import type { Host, Hosts, JoinStart, JoinStatus, State } from "./types";

// Every mutating call returns the whole new state, with `problem` set when it did not happen.
export const getState = () => call<[], State>("get_state");
export const setHosting = (on: boolean) => call<[boolean], State>("set_hosting", on);
export const pair = (id: string, pin: string, name: string) => call<[string, string, string], State>("pair", id, pin, name);
export const dismiss = (id: string) => call<[string], State>("dismiss", id);
export const disconnect = (uuid: string) => call<[string], State>("disconnect", uuid);
export const allow = (uuid: string) => call<[string], State>("allow", uuid);
export const remove = (uuid: string) => call<[string], State>("remove", uuid);

export const getHosts = () => call<[], Hosts>("get_hosts");
export const findHosts = () => call<[], { found: Host[] }>("find_hosts");
export const startJoin = (address: string) => call<[string], JoinStart>("start_join", address);
export const joinStatus = () => call<[], JoinStatus>("join_status");
export const cancelJoin = () => call<[], null>("cancel_join");
export const rememberTile = (uuid: string, name: string, appid: number) => call<[string, string, number], Hosts>("remember_tile", uuid, name, appid);
export const forgetHost = (uuid: string) => call<[string], Hosts>("forget_host", uuid);
export const tabMembers = () => call<[], { appids: number[] } | { error: string }>("tab_members");
