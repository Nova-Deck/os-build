// The SteamClient calls behind alien-game library entries.
//
// All DECISIONS (templates, ownership, the registry, refusals) live in the backend
// (novadeck_stores/shortcuts.py). This file exists because SteamClient is reachable only from
// the frontend: the backend emits a "shortcut_op" event, index.tsx hands it here, and the result
// goes back through the shortcut_result callable. Entries written through Steam's own API are
// persisted by Steam itself — nothing of ours ever writes shortcuts.vdf.
import { call } from "@decky/api";
import { Navigation } from "@decky/ui";

export type ShortcutOp =
  | { op: "add"; req: number; name: string; exe: string; dir: string; options: string }
  | { op: "remove"; req: number; appid: number; moved_to?: number }
  | { op: "edit"; req: number; appid: number; name: string; exe: string; dir: string; options: string }
  | {
      op: "artwork";
      req: number;
      appid: number;
      images: { assetType: number; base64: string; imageType: "jpg" | "png" }[];
    }
  | { op: "compat"; req: number; appid: number; tool: string };

// Steam's app store. Only the member used here is typed.
type AppOverview = { appid: number };
type AppStore = { GetAppOverviewByAppID: (appid: number) => AppOverview | null };

// A shortcut added a moment ago may not have an overview yet. Bounded, so a missing app is an
// answer and not a hang.
const OVERVIEW_WAIT_MS = 5000;

// The overviews that exist, and the appids that never got one.
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

// How long a page move gets to land before the old entry is removed regardless.
const ROUTE_WAIT_MS = 2000;

// An install transition replaces an entry; if its game page is open, move it to the replacement
// FIRST. Steam sends an open page whose app was removed to the library home (HW 2026-10-22: the
// user was kicked out the moment DOOM 64 finished), and the page cannot follow on its own — it is
// gone before its next poll. The replacement's OVERVIEW must exist before the move: a page opened
// for an app Steam has no overview of yet is itself sent home within 100 ms, and a just-added
// shortcut has none for a moment (measured on HW the same day). Bounded throughout: a move that
// never lands still lets the removal go ahead.
async function followReplacement(oldAppid: number, newAppid: number): Promise<void> {
  const onPage = (appid: number) => window.location.pathname.endsWith(`/library/app/${appid}`);
  if (!onPage(oldAppid)) return;
  const appStore = (window as unknown as { appStore?: AppStore }).appStore;
  if (!appStore?.GetAppOverviewByAppID) return;
  const { missing } = await overviewsFor(appStore, [newAppid]);
  if (missing.length) return;
  Navigation.Navigate(`/library/app/${newAppid}`);
  const deadline = Date.now() + ROUTE_WAIT_MS;
  while (!onPage(newAppid) && Date.now() < deadline) {
    await new Promise((r) => setTimeout(r, 50));
  }
}

export async function executeShortcutOp(op: ShortcutOp): Promise<void> {
  try {
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
    } else if (op.op === "edit") {
      // The install transitions change an entry IN PLACE so its appid — play time, last played,
      // art, an open game page — survives (main.py _edit_entry). Probed on the arm64 client: these
      // keep the appid, reach shortcuts.vdf and survive a Steam restart.
      if (!apps?.SetShortcutExe || !apps?.SetShortcutStartDir) throw new Error("SetShortcutExe unavailable");
      const appid = op.appid >>> 0;
      apps.SetShortcutName(appid, op.name);
      apps.SetShortcutExe(appid, op.exe);
      apps.SetShortcutStartDir(appid, op.dir);
      apps.SetShortcutLaunchOptions(appid, op.options);
      await call("shortcut_result", op.req, appid, null);
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
      if (op.moved_to !== undefined) await followReplacement(op.appid >>> 0, op.moved_to >>> 0);
      // Unsigned, the form live SteamClient calls take (unifideck's removals do the same).
      apps.RemoveShortcut(op.appid >>> 0);
      await call("shortcut_result", op.req, null, null);
    }
  } catch (error) {
    await call("shortcut_result", op.req, null, String(error));
  }
}
