// A view of a shortcut's AppOverview whose display status is ours (see status.ts).
//
// The overview is shared: every Steam surface reads the same MobX object. So nothing is written to
// it. The button is handed a Proxy that answers the one read, `display_status`, from our state and
// everything else (appid, GetGameID, BIsModOrShortcut, ...) from the real object. The real status
// stays one step away, so the moment Steam starts launching the game its own value shows through.

import { LIVE_STATUSES } from "./status";

type PerClientData = { display_status?: number; status_percentage?: number };

const overviewProxies = new WeakMap<object, Map<number, object>>();
const pcdProxies = new WeakMap<object, Map<number, object>>();
// A per-client-data proxy -> the real row behind it.
const realRows = new WeakMap<object, PerClientData>();

function isLive(row: PerClientData): boolean {
  return typeof row.display_status === "number" && LIVE_STATUSES.has(row.display_status);
}

function rowWithStatus(row: unknown, status: number): unknown {
  if (!row || typeof row !== "object") return row;
  // Steam's `selected_per_client_data` is a getter that runs with OUR proxy as `this`, so it can
  // hand back a row that is already a proxy. Never wrap a proxy: the real row must stay one step
  // away or its real (live) status cannot be read.
  const real = realRows.get(row) ?? (row as PerClientData);
  let byStatus = pcdProxies.get(real);
  if (!byStatus) pcdProxies.set(real, (byStatus = new Map()));
  let proxy = byStatus.get(status);
  if (!proxy) {
    proxy = new Proxy(real, {
      get(target, key, receiver) {
        if (key === "display_status") return isLive(target) ? target.display_status : status;
        // A shortcut's row may carry a percentage Steam would print beside our status.
        if (key === "status_percentage" && !isLive(target)) return undefined;
        return Reflect.get(target, key, receiver);
      },
    });
    realRows.set(proxy, real);
    byStatus.set(status, proxy);
  }
  return proxy;
}

// The same overview answering `display_status` with `status`. Cached per (overview, status), so a
// re-render with the same state hands React the same object and the button does not re-render.
export function withDisplayStatus<T extends object>(overview: T, status: number): T {
  let byStatus = overviewProxies.get(overview);
  if (!byStatus) overviewProxies.set(overview, (byStatus = new Map()));
  const hit = byStatus.get(status);
  if (hit) return hit as T;
  const proxy = new Proxy(overview, {
    get(target, key, receiver) {
      if (key === "selected_per_client_data") return rowWithStatus(Reflect.get(target, key, receiver), status);
      if (key === "per_client_data") {
        const rows = Reflect.get(target, key, receiver);
        return Array.isArray(rows) ? rows.map((row) => rowWithStatus(row, status)) : rows;
      }
      if (key === "display_status") {
        const real = Reflect.get(target, key, receiver);
        return typeof real === "number" && LIVE_STATUSES.has(real) ? real : status;
      }
      return Reflect.get(target, key, receiver);
    },
  });
  byStatus.set(status, proxy);
  const appid = (overview as { appid?: unknown }).appid;
  if (typeof appid === "number") proxyOwners.set(proxy, appid >>> 0);
  return proxy;
}

// Whether Steam drives this overview right now, read from the REAL row through any proxy.
export function isOverviewLive(overview: unknown): boolean {
  const row = (overview as { selected_per_client_data?: PerClientData } | null)?.selected_per_client_data;
  return !!row && isLive(realRows.get(row) ?? row);
}

// The appid of an overview that is one of OUR proxies, or null: only a button we handed a proxy
// has its press run ours. The press itself is decided at click time from the shared page state
// (NativePage.tsx), never from a closure a button instance kept from its last render.
const proxyOwners = new WeakMap<object, number>();

export function ourProxyAppid(overview: unknown): number | null {
  if (!overview || typeof overview !== "object") return null;
  return proxyOwners.get(overview) ?? null;
}
