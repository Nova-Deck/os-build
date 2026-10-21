// The SteamClient calls behind alien-game library entries, plus the [NovaDeck] collections.
//
// All DECISIONS (templates, ownership, the registry, refusals) live in the backend
// (novadeck_stores/shortcuts.py). This file exists because SteamClient is reachable only from
// the frontend: the backend emits a "shortcut_op" event, index.tsx hands it here, and the result
// goes back through the shortcut_result callable. Entries written through Steam's own API are
// persisted by Steam itself — nothing of ours ever writes shortcuts.vdf.
import { call } from "@decky/api";

export type ShortcutOp =
  | { op: "add"; req: number; name: string; exe: string; dir: string; options: string }
  | { op: "remove"; req: number; appid: number }
  | {
      op: "artwork";
      req: number;
      appid: number;
      images: { assetType: number; base64: string; imageType: "jpg" | "png" }[];
    }
  | { op: "compat"; req: number; appid: number; tool: string }
  | { op: "collection"; req: number; name: string; add: number[]; remove: number[] };

// Steam's collection store and app store, the two globals the library's collections live in. Only
// the members used here are typed; the shapes match what unifideck's collection-manager drives.
type AppOverview = { appid: number };
type Collection = {
  AsDragDropCollection: () => {
    AddApps: (overviews: AppOverview[]) => void;
    RemoveApps: (overviews: AppOverview[]) => void;
  };
  Save: () => Promise<void>;
};
type CollectionStore = {
  GetCollectionIDByUserTag: (tag: string) => string | null;
  GetCollection: (id: string) => Collection | undefined;
  NewUnsavedCollection: (tag: string, filter: unknown, overviews: AppOverview[]) => Collection | undefined;
};
type AppStore = { GetAppOverviewByAppID: (appid: number) => AppOverview | null };

// A shortcut added a moment ago may not have an overview yet; the collection can only take one
// that does. Bounded, so a missing app is an error and not a hang.
const OVERVIEW_WAIT_MS = 5000;

// The overviews that exist, and the appids that never got one. A missing one (a tile the user
// deleted in Steam) must not keep the healthy tiles out of the collection, so it is reported, not
// thrown.
async function overviewsFor(
  appStore: AppStore,
  appids: number[],
): Promise<{ found: AppOverview[]; missing: number[] }> {
  const deadline = Date.now() + OVERVIEW_WAIT_MS;
  for (;;) {
    const found = appids.map((id) => appStore.GetAppOverviewByAppID(id >>> 0));
    if (found.every(Boolean) || Date.now() > deadline) {
      return {
        found: found.filter(Boolean) as AppOverview[],
        missing: appids.filter((_, i) => !found[i]),
      };
    }
    await new Promise((r) => setTimeout(r, 250));
  }
}

async function applyCollection(name: string, add: number[], remove: number[]): Promise<void> {
  const w = window as unknown as { collectionStore?: CollectionStore; appStore?: AppStore };
  const cs = w.collectionStore;
  const appStore = w.appStore;
  if (!cs?.GetCollectionIDByUserTag || !cs?.NewUnsavedCollection || !appStore?.GetAppOverviewByAppID) {
    throw new Error("collectionStore/appStore unavailable");
  }
  const id = cs.GetCollectionIDByUserTag(name);
  let c = typeof id === "string" ? cs.GetCollection(id) : undefined;
  if (!c) {
    if (add.length === 0) return; // never create an empty collection just to remove from it
    c = cs.NewUnsavedCollection(name, undefined, []);
    if (!c) throw new Error(`could not create collection ${name}`);
  }
  // Removals first, and only for apps that still exist: a deregistered shortcut is already gone.
  const leaving = remove.map((a) => appStore.GetAppOverviewByAppID(a >>> 0)).filter(Boolean) as AppOverview[];
  if (leaving.length) c.AsDragDropCollection().RemoveApps(leaving);
  const { found, missing } = add.length ? await overviewsFor(appStore, add) : { found: [], missing: [] };
  if (found.length) c.AsDragDropCollection().AddApps(found);
  await c.Save();
  if (missing.length) throw new Error(`no app overview for ${missing.join(",")} (the rest were added)`);
}

export async function executeShortcutOp(op: ShortcutOp): Promise<void> {
  try {
    if (op.op === "collection") {
      await applyCollection(op.name, op.add, op.remove);
      await call("shortcut_result", op.req, null, null);
      return;
    }
    const apps = (window as any).SteamClient?.Apps;
    if (!apps?.AddShortcut || !apps?.RemoveShortcut) {
      throw new Error("SteamClient.Apps unavailable");
    }
    if (op.op === "compat") {
      if (!apps?.SpecifyCompatTool) throw new Error("SpecifyCompatTool unavailable");
      // No availability guard: our baked Proton is always registered (read-only root, via
      // STEAM_EXTRA_COMPAT_TOOLS_PATHS), unlike Valve's lazily-downloaded tools — and the arm64
      // client exposes no GetAvailableCompatTools on SteamClient.Apps anyway (measured on device).
      // CompatToolMapping is keyed by the UNSIGNED appid; the backend re-asserts on boot since the
      // set is in-memory until Steam flushes config.vdf.
      apps.SpecifyCompatTool(op.appid >>> 0, op.tool);
      await call("shortcut_result", op.req, null, null);
    } else if (op.op === "artwork") {
      if (!apps?.SetCustomArtworkForApp) throw new Error("SetCustomArtworkForApp unavailable");
      // One call per kind. Steam writes its own grid dir, so these persist the way the entry
      // does (milestone 4) — the gate confirms it. A kind that could not be sourced is simply
      // absent from images; nothing here blocks the entry it decorates.
      for (const img of op.images) {
        await apps.SetCustomArtworkForApp(op.appid, img.base64, img.imageType, img.assetType);
      }
      await call("shortcut_result", op.req, null, null);
    } else if (op.op === "add") {
      const appid: number = await apps.AddShortcut(op.name, op.exe, op.dir, op.options);
      if (!appid) throw new Error("AddShortcut returned no appid");
      // AddShortcut's trailing arguments are not trusted across client versions (the arm64
      // client has its own history of API skew — the mis-packed atoms precedent), so the fields
      // that carry identity are set explicitly after the add. Idempotent when the add already
      // took them.
      apps.SetShortcutName(appid, op.name);
      apps.SetShortcutLaunchOptions(appid, op.options);
      if (op.dir) apps.SetShortcutStartDir(appid, op.dir);
      await call("shortcut_result", op.req, appid, null);
    } else {
      // Unsigned, the form live SteamClient calls take (unifideck's removals do the same).
      apps.RemoveShortcut(op.appid >>> 0);
      await call("shortcut_result", op.req, null, null);
    }
  } catch (error) {
    await call("shortcut_result", op.req, null, String(error));
  }
}
