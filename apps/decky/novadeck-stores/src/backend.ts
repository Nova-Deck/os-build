import { call } from "@decky/api";
import type {
  AccountResult,
  ConnectStart,
  InstallEvent,
  LibraryState,
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
export const uninstallGame = (store: StoreId, id: string) =>
  call<[StoreId, string], { uninstalled: boolean; warning?: string } | { error: string }>("uninstall", store, id);
