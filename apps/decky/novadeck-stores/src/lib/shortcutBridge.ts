// The five SteamClient calls behind alien-game library entries, and nothing else.
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
  | { op: "compat"; req: number; appid: number; tool: string };

export async function executeShortcutOp(op: ShortcutOp): Promise<void> {
  try {
    const apps = (window as any).SteamClient?.Apps;
    if (!apps?.AddShortcut || !apps?.RemoveShortcut) {
      throw new Error("SteamClient.Apps unavailable");
    }
    if (op.op === "compat") {
      if (!apps?.SpecifyCompatTool || !apps?.GetAvailableCompatTools) {
        throw new Error("compat-tool API unavailable");
      }
      // Verify the tool is installed before setting it — Steam provisions our Proton lazily, and
      // mapping an absent tool silently drops. CompatToolMapping is keyed by the UNSIGNED appid.
      const tools: { strToolName: string }[] = await apps.GetAvailableCompatTools(op.appid >>> 0);
      if (!tools?.some((t) => t.strToolName === op.tool)) {
        throw new Error(`compat tool ${op.tool} not installed yet`);
      }
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
