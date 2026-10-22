export type StoreId = "epic" | "gog";

// Shared by the panel rows and the sign-in toasts, which are raised from index.tsx.
export const STORE_LABELS: Record<string, string> = {
  epic: "Epic Games",
  gog: "GOG",
};

export type StoreStatus = {
  store: StoreId;
  connected: boolean;
  account?: string | null;
  // What the credential file says about its access token. Meaningful only after a refresh has
  // run: then it means the refresh could not renew it (main.py refresh).
  expired?: boolean;
};

// The backend answers with an error string instead of a store list when it cannot resolve the
// credential paths at all. That is a broken image, not an empty state, and the panel says so
// rather than showing two "not connected" rows — those would invite the user to fix it by
// signing in, which is the one action that cannot help.
// A plain union with an `in` check, NOT optional `never` members: TypeScript will not narrow a
// union on a truthiness test against an optional property, so `state.error ? … : state.stores`
// compiles with `state.stores` possibly undefined. Narrow on the key's presence instead.
export type State = { stores: StoreStatus[] } | { error: string };

// Same union-and-`in` shape as State, for the same narrowing reason.
export type ConnectStart = { url: string } | { error: string };

export type AccountResult = StoreStatus | { error: string };

// One install record as main.py library_state reports it. `state` is derived from the CLI's own
// artifacts on every read (installs.install_status); `tile` says what the library shows for it.
export type InstallItem = {
  store: StoreId;
  id: string;
  title: string;
  state: "downloading" | "installed" | "interrupted";
  percent?: number;
  tile?: "shelf" | "installed" | null;
};

export type Drive = { path: string; label: string; free: number };

export type LibraryState =
  | { installs: InstallItem[]; drives: Drive[]; install_drive: string | null }
  | { error: string };

export type SyncResult = { added: number; tiles: number; warning?: string } | { error: string };

// What install_tile answers: the same event a tile press toasts.
export type InstallEvent = { ok: boolean; message: string };

// What main.py game_state answers for one game page (novadeck_stores/game_page.py has the states).
// `appid` is the entry's LIVE appid: it differs from the page's own once an install finished or an
// uninstall ran, since both replace the entry — the page then moves to the new one.
export type OurPage = {
  ours: true;
  token: string;
  store: StoreId;
  id: string;
  title: string;
  appid: number;
  state: "install" | "downloading" | "paused" | "finishing" | "installed" | "stale";
  percent?: number;
  // The game holding the one install slot, when it is another one.
  busy?: string;
  // Where Install would put it (state "install" only).
  drive?: { label: string; free: number };
};

export type PageState = OurPage | { ours: false } | { error: string };

export type InstallSize = { disk_size: number } | { error: string };
