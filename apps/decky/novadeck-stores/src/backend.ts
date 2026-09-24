import { call } from "@decky/api";
import type { ConnectStart, State, StoreId } from "./types";

// Status comes from the CLIs' own credential files, which they refresh and invalidate
// themselves, so it is always re-read rather than cached across opens.
export const getStatus = () => call<[], State>("get_status");

// Prepares a sign-in and returns the login URL to open. The result of the sign-in itself does
// not come back here — it arrives later as the "connect_done" event (see index.tsx).
export const startConnect = (store: StoreId) => call<[StoreId], ConnectStart>("start_connect", store);
