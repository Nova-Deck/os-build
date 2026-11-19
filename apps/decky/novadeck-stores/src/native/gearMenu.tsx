// Our items in Steam's game context menu (the gear button on the game page, and a library tile's
// menu): Uninstall, Remove download, the DOSBox version and the cloud-saves switch. Steam puts its
// own Uninstall there, so ours goes there too, just before "Properties…".
//
// Technique (the one decky-steamgriddb uses for its menu item): find the LibraryContextMenu class
// through the export that renders it, afterPatch its render, then the inner type's render and
// shouldComponentUpdate, and splice MenuItems into the menu's children. The menu renders
// synchronously, so what it offers comes from the page's last answers (lib/pageState.ts,
// lib/pageHooks.ts): an entry whose page has never been opened this session shows none of them.

import { toaster } from "@decky/api";
import { afterPatch, fakeRenderComponent, findInReactTree, findInTree, findModuleByExport, MenuItem, type Patch } from "@decky/ui";
import type { ReactElement } from "react";
import { setCloudSaves } from "../backend";
import { showDosVersionSetting } from "../DosVersionDialog";
import { latestCloud, latestDos, latestOnBoxtron, runAction } from "../lib/pageHooks";
import { confirmRemove, startUninstall } from "../lib/pageActions";
import { cachedPage, refreshPageState } from "../lib/pageState";
import type { OurPage } from "../types";

const KEY = "novadeck-menu-";

function itemsFor(page: OurPage): ReactElement[] {
  const items: ReactElement[] = [];
  if (page.state === "paused") {
    items.push(
      <MenuItem key={`${KEY}remove`} tone="destructive" onSelected={() => confirmRemove(page)}>
        Remove download
      </MenuItem>,
    );
  }
  if (page.state !== "installed") return items;
  const dos = latestDos.get(page.appid);
  if (latestOnBoxtron.get(page.appid) && dos && dos.labels.length > 1) {
    items.push(
      <MenuItem
        key={`${KEY}dosbox`}
        onSelected={() =>
          showDosVersionSetting(page.appid, page.title, dos.labels, dos.choice, (message) => {
            toaster.toast({ title: page.title, body: message });
            refreshPageState(page.appid);
          })
        }
      >
        DOSBox version…
      </MenuItem>,
    );
  }
  const cloud = latestCloud.get(page.appid);
  if (cloud && (cloud.state === "on" || cloud.state === "off")) {
    const turnOn = cloud.state === "off";
    items.push(
      <MenuItem
        key={`${KEY}cloud`}
        onSelected={() =>
          void runAction(page.appid, page.title, async () => {
            const res = await setCloudSaves(page.appid, turnOn);
            return "error" in res ? { error: `Cloud saves: ${res.error}` } : {};
          })
        }
      >
        {turnOn ? "Turn cloud saves on" : "Turn cloud saves off"}
      </MenuItem>,
    );
  }
  items.push(
    <MenuItem key={`${KEY}uninstall`} tone="destructive" onSelected={() => startUninstall(page)}>
      Uninstall…
    </MenuItem>,
  );
  return items;
}

function isOurs(node: unknown): boolean {
  const key = (node as { key?: unknown } | null)?.key;
  return typeof key === "string" && key.startsWith(KEY);
}

// The menu's own appid, read from its children rather than a closure: the outer render's value is
// the FIRST menu ever opened, and trusting it would make every game's menu act on that game.
function appidOfItems(items: unknown[], fallback: number): number {
  const owned = items
    .map((x) => (x as { _owner?: { pendingProps?: { overview?: { appid?: number } } } })?._owner?.pendingProps?.overview?.appid)
    .find((a) => !!a && a !== fallback);
  if (owned) return owned;
  const found = findInTree(items, (x: any) => !!x?.app?.appid, { walkable: ["props", "children"] });
  return found?.app?.appid ?? fallback;
}

// The game context menu, not a screenshot's or a collection's: one of its items launches.
function isGameMenu(items: unknown): items is unknown[] {
  return (
    Array.isArray(items) &&
    items.length > 0 &&
    !!findInReactTree(items, (x: any) => String(x?.props?.onSelected ?? "").includes("launchSource"))
  );
}

function splice(items: unknown[], fallback: number): void {
  for (let i = items.length - 1; i >= 0; i--) if (isOurs(items[i])) items.splice(i, 1);
  const page = cachedPage(appidOfItems(items, fallback) >>> 0);
  if (!page) return;
  const ours = itemsFor(page);
  if (ours.length === 0) return;
  const at = items.findIndex((item) =>
    findInReactTree(item, (x: any) => String(x?.onSelected ?? "").includes("AppProperties")),
  );
  items.splice(at >= 0 ? at : items.length, 0, ...ours);
}

function findLibraryContextMenu(): { prototype: Record<string, unknown> } | null {
  const mod = findModuleByExport((e: any) => String(e?.toString?.() ?? "").includes("().LibraryContextMenu"));
  const renderer = Object.values(mod ?? {}).find((v: any) => String(v?.toString?.() ?? "").includes("navigator:"));
  if (!renderer) return null;
  return (fakeRenderComponent(renderer as () => unknown) as any)?.type ?? null;
}

function appidOfMenu(component: any): number {
  const owned = component?._owner?.pendingProps?.overview?.appid;
  if (owned) return owned;
  const found = findInTree(component?.props?.children, (x: any) => !!x?.app?.appid, { walkable: ["props", "children"] });
  return found?.app?.appid ?? 0;
}

// Returns the disposer; a no-op when Steam's menu cannot be found (the trash button still uninstalls).
export function applyGearMenu(): () => void {
  let menu: { prototype: Record<string, unknown> } | null = null;
  try {
    menu = findLibraryContextMenu();
  } catch (e) {
    console.error("novadeck-stores: gear menu not found", e);
  }
  if (!menu) return () => undefined;
  const patches: Patch[] = [];
  let inner: Patch | undefined;
  patches.push(
    afterPatch(menu.prototype, "render", (_args: unknown[], component: any) => {
      const fallback = appidOfMenu(component);
      if (!inner) {
        inner = afterPatch(component, "type", (_a: unknown[], ret: any) => {
          const proto = ret?.type?.prototype;
          if (!proto) return ret;
          patches.push(
            afterPatch(proto, "render", (_b: unknown[], ret2: any) => {
              const items = ret2?.props?.children?.[0];
              if (isGameMenu(items)) {
                try {
                  splice(items, fallback);
                } catch (e) {
                  console.error("novadeck-stores: gear menu items failed", e);
                }
              }
              return ret2;
            }),
            afterPatch(proto, "shouldComponentUpdate", (args: any[], update: unknown) => {
              const next = args?.[0]?.children;
              if (update === true && isGameMenu(next)) {
                try {
                  splice(next, fallback);
                } catch (e) {
                  console.error("novadeck-stores: gear menu items failed", e);
                }
              }
              return update;
            }),
          );
          return ret;
        });
        patches.push(inner);
      } else {
        // Later opens: the inner patch is bound to the first menu's prototype and may not fire.
        const children = component?.props?.children;
        if (isGameMenu(children)) {
          try {
            splice(children, fallback);
          } catch (e) {
            console.error("novadeck-stores: gear menu items failed", e);
          }
        }
      }
      return component;
    }),
  );
  return () => patches.forEach((p) => p.unpatch());
}
