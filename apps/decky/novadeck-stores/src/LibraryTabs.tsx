import { call, routerHook } from "@decky/api";
import { afterPatch, findInReactTree, gamepadTabbedPageClasses, replacePatch, wrapReactType, type Patch } from "@decky/ui";
import { createElement, useEffect, useState, type ComponentType, type Context, type ReactElement } from "react";

// Milestone 7 revision 2, R2: Epic and GOG as TABS of Steam's library, beside All Games and
// Installed — the browse surface (collections become an opt-in, R3).
//
// The technique is unifideck's library-patch.ts (itself TabMaster's): patch the /library route,
// afterPatch down two element levels to the memoised component that owns the tab list, and wrap
// its useMemo so the list it returns gains our tabs before React commits. Each tab's content is
// Steam's OWN grid component (found by its "Library_FilteredByHeader" marker in the AllGames
// tab) given a collection-shaped object, so the grid, its sorting and its focus are Steam's.
// The R0 probe (2026-10-22) walked exactly this chain on the arm64 client.
//
// Differences from unifideck: membership is our REGISTRY (main.py library_tabs, the same rule as
// the game page) rather than store tags on Steam's games collection, so a tab can never list a
// shortcut that is not ours; and Steam's own tabs are all kept — ours are added, nothing hidden.

type StoreId = "epic" | "gog";
const TABS: { id: string; store: StoreId; title: string }[] = [
  { id: "novadeck-epic", store: "epic", title: "Epic" },
  { id: "novadeck-gog", store: "gog", title: "GOG" },
];
// Ours go right after this one of Steam's (or at the end, should a client rename it).
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

// The members each tab shows, re-read from the backend after every library-entry operation
// (index.tsx). `version` is folded into the tabs useMemo's deps, so a change re-renders the list.
type Members = Record<StoreId | "installed", number[]>;
let members: Members = { epic: [], gog: [], installed: [] };
let version = 0;
const listeners = new Set<() => void>();

export async function refreshLibraryTabs(): Promise<void> {
  const r = await call<[], Members | { error: string }>("library_tabs");
  if ("error" in r) {
    console.error("novadeck-stores: library tabs not refreshed:", r.error);
    return;
  }
  members = r;
  version += 1;
  listeners.forEach((l) => l());
}

// Debounced: a sync is dozens of shortcut ops in a row, and one re-read after the last is enough.
let refreshTimer = 0;
export function scheduleLibraryTabsRefresh(): void {
  window.clearTimeout(refreshTimer);
  refreshTimer = window.setTimeout(() => void refreshLibraryTabs(), 500);
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

// Steam's grid component, found once: the AllGames tab renders it, marked by a string in its
// own source.
let cachedGrid: ComponentType<Record<string, unknown>> | undefined;

// Logged once per reason: a client update that moves something shows in the console, without a
// line every render.
const bailed = new Set<string>();
function bail<T>(reason: string, result: T): T {
  if (!bailed.has(reason)) {
    bailed.add(reason);
    console.error(`novadeck-stores: library tabs not added: ${reason}`);
  }
  return result;
}

function spliceTabs(result: unknown, deps: unknown[]): unknown {
  // Every useMemo of the tab owner comes through here; only the tab list is touched.
  if (!Array.isArray(result)) return result;
  const isTuple = Array.isArray(result[0]);
  const tabs = (isTuple ? result[0] : result) as SteamTab[];
  if (!tabs[0]?.id || !tabs[0]?.content) return result;
  if (tabs.some((t) => t.id?.startsWith("novadeck-"))) return result; // already ours this render

  const template = tabs.find((t) => t.id === "AllGames");
  if (!template) return bail("no AllGames tab to copy", result);
  const Grid =
    cachedGrid ??
    (findInReactTree(template.content, (e: any) => Boolean(e?.type?.toString?.().includes("Library_FilteredByHeader")))
      ?.type as ComponentType<Record<string, unknown>> | undefined);
  if (!Grid) return bail("Steam's library grid component not found", result);
  cachedGrid = Grid;
  const TabContext = (template.content as any)?.type?._context as Context<{ label: string }> | undefined;

  // The sort state is the first three deps (unifideck/TabMaster); the collections app filter is
  // found by its shape, never its position — Steam reorders these deps across builds.
  const [eSortBy, setSortBy, showSortingContextMenu] = deps;
  const appFilter = deps.find((d) => typeof (d as AppFilter | null)?.Matches === "function") as AppFilter | undefined;

  // One tab on Steam's grid. `footer` is the template's: Steam's tab renderer expects its button
  // hints and menu callbacks, and an empty one makes the tab a skipped no-op in the strip.
  const gridTab = (base: SteamTab, collection: ReturnType<typeof collectionFor>): SteamTab => {
    const grid = createElement(Grid, { collection, eSortBy, setSortBy, showSortingContextMenu });
    return {
      ...base,
      footer: { ...(base.footer ?? template.footer ?? {}) },
      content: TabContext ? createElement(TabContext.Provider, { value: { label: base.title } }, grid) : grid,
      renderTabAddon: () =>
        createElement(
          "span",
          { className: gamepadTabbedPageClasses?.TabCount ?? "" },
          collection.GetAppCountWithToolsFilter(appFilter),
        ),
    };
  };

  const ours: SteamTab[] = [];
  for (const t of TABS) {
    const collection = collectionFor(t.id, t.title, overviews(members[t.store] ?? []));
    // A store with nothing in the library (not connected, never synced) gets no tab.
    if (collection.allApps.length === 0) continue;
    ours.push(gridTab({ id: t.id, title: t.title, content: template.content }, collection));
  }

  // Steam's own Installed tab, with our installed games in it too. Steam leaves every shortcut
  // out (by app type): to Steam a not-installed stub tile looks as installed as a game, so only
  // our registry can say which of ours are (library_tabs "installed"). Same id, title and footer,
  // so Steam's per-tab sort and filter state still apply; its own apps are read from the grid it
  // built, never from a collection we look up.
  let withInstalled = tabs;
  const installed = overviews(members.installed ?? []);
  const at = tabs.findIndex((t) => t.id === AFTER_TAB);
  if (installed.length && at >= 0) {
    const steamCollection = findInReactTree(tabs[at].content, (e: any) => Array.isArray(e?.props?.collection?.allApps))
      ?.props?.collection;
    if (steamCollection) {
      const mine = new Set(installed.map((a) => a.appid));
      const steamApps = (steamCollection.allApps as Overview[]).filter((a) => !mine.has(a.appid));
      const collection = collectionFor(steamCollection.id, steamCollection.displayName, [...steamApps, ...installed]);
      withInstalled = [...tabs.slice(0, at), gridTab(tabs[at], collection), ...tabs.slice(at + 1)];
    } else {
      bail("Steam's Installed tab has no collection to add to", null);
    }
  }

  if (ours.length === 0 && withInstalled === tabs) return result;
  const merged =
    at < 0 ? [...withInstalled, ...ours] : [...withInstalled.slice(0, at + 1), ...ours, ...withInstalled.slice(at + 1)];
  return isTuple ? [merged, ...result.slice(1)] : merged;
}

type Elt = ReactElement & { type: any };

// Returns the unpatch. With TabMaster installed we add nothing: it owns the tab list, and two
// plugins rewriting one useMemo is how a library ends up blank.
export function applyLibraryTabsPatch(): () => void {
  const patch = routerHook.addPatch("/library", (props: any) => {
    if (isTabMasterInstalled()) return props;
    // A re-render of the library when the members change (refreshLibraryTabs).
    const [, setTick] = useState(0);
    useEffect(() => {
      const l = () => setTick((v) => v + 1);
      listeners.add(l);
      return () => void listeners.delete(l);
    }, []);

    afterPatch(props.children, "type", (_: unknown[], ret1: Elt) => {
      if (!ret1?.type) return ret1;
      let inner: Patch | undefined;
      let memoCache: unknown;
      useEffect(() => () => inner?.unpatch());
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
                return spliceTabs(value, withVersion) as T;
              } catch (e) {
                // Steam's tabs, untouched, rather than a library with none.
                console.error("novadeck-stores: library tabs failed", e);
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
