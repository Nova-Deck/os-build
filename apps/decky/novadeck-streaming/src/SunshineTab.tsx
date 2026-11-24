import { routerHook } from "@decky/api";
import { afterPatch, findInReactTree, gamepadTabbedPageClasses, replacePatch, wrapReactType, type Patch } from "@decky/ui";
import { createElement, useEffect, useState, type ComponentType, type Context, type ReactElement } from "react";
import { tabMembers } from "./backend";

// "Sunshine", a tab of Steam's library with the tiles of the hosts paired here. novadeck-stores'
// LibraryTabs.tsx, for one tab: that file says how and why (copied, as plugins cannot import each
// other). Both plugins wrap the same useMemo, so each must leave the other's tabs alone.
//
// Members are our registry, so another device's tile (Steam offers those for Remote Play) is never here.

const TAB_ID = "novadeck-sunshine";
const TAB_TITLE = "Sunshine";
const AFTER_TAB = "Installed";

type Overview = { appid: number };
type AppFilter = { Matches: (a: Overview) => boolean };
type SteamTab = {
  id: string;
  title: string;
  content: ReactElement;
  footer?: Record<string, unknown>;
  renderTabAddon?: () => ReactElement;
};

let members: number[] = [];
// Folded into the tabs useMemo's deps, so a change re-renders the list.
let version = 0;
const listeners = new Set<() => void>();

export async function refreshTab(): Promise<void> {
  const r = await tabMembers();
  if ("error" in r) {
    console.error("novadeck-streaming: library tab not refreshed:", r.error);
    return;
  }
  members = r.appids;
  version += 1;
  listeners.forEach((l) => l());
}

// A tile just added has no overview for a moment (about 250 ms, measured by novadeck-stores).
let refreshTimer = 0;
export function scheduleTabRefresh(): void {
  window.clearTimeout(refreshTimer);
  refreshTimer = window.setTimeout(() => void refreshTab(), 1000);
}

function isTabMasterInstalled(): boolean {
  const plugins = (window as any).DeckyPluginLoader?.plugins ?? [];
  return plugins.some((p: { name?: string }) => p.name === "TabMaster" || p.name === "Tab Master");
}

// React's current hooks dispatcher, so the tab owner's useMemo can be wrapped for the length of
// one render. Two shapes: the React 18 internals and the React 19 client internals.
type Hooks = { useMemo?: <T>(fn: () => T, deps: unknown[]) => T; useEffect?: unknown };
function getReactHooks(): Hooks | null {
  const r = (window as any).SP_REACT;
  const current = r?.__SECRET_INTERNALS_DO_NOT_USE_OR_YOU_WILL_BE_FIRED?.ReactCurrentDispatcher?.current;
  if (current?.useMemo) return current;
  const client = r?.__CLIENT_INTERNALS_DO_NOT_USE_OR_WARN_USERS_THEY_CANNOT_UPGRADE;
  if (client) {
    for (const c of Object.values(client) as Hooks[]) {
      if (c?.useMemo && c.useEffect) return c;
    }
  }
  return null;
}

function overviews(appids: number[]): Overview[] {
  const store = (window as any).appStore;
  return appids.map((a) => store?.GetAppOverviewByAppID?.(a) as Overview | null).filter(Boolean) as Overview[];
}

// A collection-shaped object for Steam's grid. Every member Steam calls must be safe to call: a
// throw here escapes into the library's error boundary and takes the WHOLE library down.
function collectionFor(id: string, title: string, apps: Overview[]) {
  return {
    AsDeletableCollection: () => null,
    AsDragDropCollection: () => null,
    AsEditableCollection: () => null,
    GetAppCountWithToolsFilter: (f: AppFilter | undefined) => {
      if (typeof f?.Matches !== "function") return apps.length;
      try {
        return apps.filter((a) => f.Matches(a)).length;
      } catch {
        return apps.length;
      }
    },
    bAllowsDragAndDrop: false,
    bIsDeletable: false,
    bIsDynamic: false,
    bIsEditable: false,
    displayName: title,
    id,
    allApps: apps,
    visibleApps: [...apps],
    apps: new Map(apps.map((a) => [a.appid, a])),
  };
}

let cachedGrid: ComponentType<Record<string, unknown>> | undefined;

// Logged once per reason: a client update that moves something shows in the console.
const bailed = new Set<string>();
function bail<T>(reason: string, result: T): T {
  if (!bailed.has(reason)) {
    bailed.add(reason);
    console.error(`novadeck-streaming: library tab not added: ${reason}`);
  }
  return result;
}

function spliceTab(result: unknown, deps: unknown[]): unknown {
  // Every useMemo of the tab owner comes through here; only the tab list is touched.
  if (!Array.isArray(result)) return result;
  const isTuple = Array.isArray(result[0]);
  const tabs = (isTuple ? result[0] : result) as SteamTab[];
  if (!tabs[0]?.id || !tabs[0]?.content) return result;
  if (tabs.some((t) => t.id === TAB_ID)) return result;

  const apps = overviews(members);
  if (apps.length === 0) return result; // no host, no tab

  const template = tabs.find((t) => t.id === "AllGames");
  if (!template) return bail("no AllGames tab to copy", result);
  const Grid =
    cachedGrid ??
    (findInReactTree(template.content, (e: any) => Boolean(e?.type?.toString?.().includes("Library_FilteredByHeader")))
      ?.type as ComponentType<Record<string, unknown>> | undefined);
  if (!Grid) return bail("Steam's library grid component not found", result);
  cachedGrid = Grid;
  const TabContext = (template.content as any)?.type?._context as Context<{ label: string }> | undefined;

  const [eSortBy, setSortBy, showSortingContextMenu] = deps;
  const appFilter = deps.find((d) => typeof (d as AppFilter | null)?.Matches === "function") as AppFilter | undefined;
  const collection = collectionFor(TAB_ID, TAB_TITLE, apps);
  const grid = createElement(Grid, { collection, eSortBy, setSortBy, showSortingContextMenu });
  const ours: SteamTab = {
    id: TAB_ID,
    title: TAB_TITLE,
    footer: { ...(template.footer ?? {}) },
    content: TabContext ? createElement(TabContext.Provider, { value: { label: TAB_TITLE } }, grid) : grid,
    renderTabAddon: () =>
      createElement("span", { className: gamepadTabbedPageClasses?.TabCount ?? "" }, collection.GetAppCountWithToolsFilter(appFilter)),
  };
  // After the other first-party tabs if they are there, else after Steam's Installed, else last.
  const others = tabs.map((t) => t.id.startsWith("novadeck-")).lastIndexOf(true);
  const at = others >= 0 ? others : tabs.findIndex((t) => t.id === AFTER_TAB);
  const merged = at < 0 ? [...tabs, ours] : [...tabs.slice(0, at + 1), ours, ...tabs.slice(at + 1)];
  return isTuple ? [merged, ...result.slice(1)] : merged;
}

type Elt = ReactElement & { type: any };

// Returns the unpatch. With TabMaster installed we add nothing: it owns the tab list, and two
// plugins rewriting one useMemo is how a library ends up blank.
export function applySunshineTab(): () => void {
  const patch = routerHook.addPatch("/library", (props: any) => {
    if (isTabMasterInstalled()) return props;
    // No hook out here: Decky calls this inside its ROUTER's render, where hooks count as the
    // router's, and a second plugin adding some after the first render takes Steam's UI down (React
    // error 310). The function patched below is the page's component, made anew on every such pass.
    afterPatch(props.children, "type", (_: unknown[], ret1: Elt) => {
      // A re-render of the library when the members change (refreshTab).
      const [, setTick] = useState(0);
      useEffect(() => {
        const l = () => setTick((v) => v + 1);
        listeners.add(l);
        return () => void listeners.delete(l);
      }, []);
      let inner: Patch | undefined;
      let memoCache: unknown;
      useEffect(() => () => inner?.unpatch());
      if (!ret1?.type) return ret1;
      afterPatch(ret1, "type", (_2: unknown[], ret2: Elt) => {
        if (!ret2?.type) return ret2;
        if (memoCache) {
          ret2.type = memoCache;
          return ret2;
        }
        const original = ret2.type.type;
        // Some client builds leave this empty on a render path; wrapping nothing would call
        // undefined() and take the library down. Leave that render untouched.
        if (typeof original !== "function") return ret2;
        wrapReactType(ret2);
        inner = replacePatch(ret2.type, "type", (args: unknown[]) => {
          const hooks = getReactHooks();
          if (!hooks?.useMemo) return original(...args);
          const realUseMemo = hooks.useMemo;
          hooks.useMemo = <T,>(fn: () => T, deps: unknown[]): T => {
            const withVersion = [...deps, version];
            return realUseMemo(() => {
              const value = fn();
              try {
                return spliceTab(value, withVersion) as T;
              } catch (e) {
                // Steam's tabs, untouched, rather than a library with none.
                console.error("novadeck-streaming: library tab failed", e);
                return value;
              }
            }, withVersion);
          };
          try {
            return original(...args);
          } finally {
            hooks.useMemo = realUseMemo;
          }
        });
        memoCache = ret2.type;
        return ret2;
      });
      return ret1;
    });
    return props;
  });
  return () => routerHook.removePatch("/library", patch);
}
