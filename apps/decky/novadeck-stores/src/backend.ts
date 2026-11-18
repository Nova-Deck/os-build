import { call } from "@decky/api";
import type {
  AccountResult,
  ConnectStart,
  DosVersions,
  InstallEvent,
  InstallSize,
  LibraryState,
  PageState,
  PrefixStatus,
  State,
  StoreId,
  SyncResult,
} from "./types";

// Status comes from the CLIs' own credential files, which they refresh and invalidate
// themselves, so it is always re-read rather than cached across opens.
export const getStatus = () => call<[], State>("get_status");

// Prepares a sign-in and returns the login URL to open. The result of the sign-in itself does
// not come back here — it arrives later as the "connect_done" event (see index.tsx).
export const startConnect = (store: StoreId) => call<[StoreId], ConnectStart>("start_connect", store);

// Both run the store's CLI (network for refresh) and answer with the status read back after it.
export const refreshStore = (store: StoreId) => call<[StoreId], AccountResult>("refresh", store);
export const disconnectStore = (store: StoreId) => call<[StoreId], AccountResult>("disconnect", store);

// Milestone 7, the slim panel. library_state is polled while the panel is open: one round trip
// for the activity, the drives and the install-drive preference.
export const getLibraryState = () => call<[], LibraryState>("library_state");
export const syncLibrary = (store: StoreId) => call<[StoreId], SyncResult>("sync_library", store);
export const setInstallDrive = (drive: string) =>
  call<[string], { install_drive: string } | { error: string }>("set_install_drive", drive);
// Resume is exactly a tile press: same drive rules, same answer.
export const installTile = (store: StoreId, id: string) =>
  call<[StoreId, string], InstallEvent>("install_tile", store, id);
export const stopInstall = () => call<[], { stopped: boolean } | { error: string }>("stop_install");
// Issue #136: the entry's Proton prefix (saves, settings) is kept unless asked otherwise; the
// dialog asks prefix_status first so it can say what is there.
export const uninstallGame = (store: StoreId, id: string, dropPrefix = false) =>
  call<[StoreId, string, boolean], { uninstalled: boolean; prefix_dropped?: boolean; warning?: string } | { error: string }>(
    "uninstall",
    store,
    id,
    dropPrefix,
  );
export const getPrefixStatus = (store: StoreId, id: string) =>
  call<[StoreId, string], PrefixStatus>("prefix_status", store, id);

// Revision 2, the game page. game_state is polled while a shortcut's page is open; `token` is the
// one an earlier answer gave, so a page whose entry was replaced still finds it.
export const getGameState = (appid: number, token?: string) =>
  call<[number, string | null], PageState>("game_state", appid, token ?? null);
export const getInstallSize = (store: StoreId, id: string) =>
  call<[StoreId, string], InstallSize>("install_size", store, id);

// boxtron-dos phase 3: which DOSBox version of a GOG title runs under Boxtron (DosVersionDialog).
// A null label answers the launch's question with Cancel (do not launch) / sets "Ask every time".
export const answerDosPick = (appid: number, label: string | null, remember: boolean) =>
  call<[number, string | null, boolean], { ok: true } | { error: string }>("dos_pick_answer", appid, label, remember);
// gog-comet phase 3: which saves to keep when a GOG game's changed here AND in the cloud
// (SavePickDialog). null is "Decide later": nothing is synced, the launch goes on.
export type SaveChoice = "cloud" | "local" | null;
export const answerSavePick = (appid: number, index: number, choice: SaveChoice) =>
  call<[number, number, SaveChoice], { ok: true } | { error: string }>("save_pick_answer", appid, index, choice);
export const getDosVersions = (appid: number) =>
  call<[number], DosVersions>("dos_versions", appid);
export const setDosChoice = (appid: number, label: string | null) =>
  call<[number, string | null], { choice: string | null } | { error: string }>("set_dos_choice", appid, label);
