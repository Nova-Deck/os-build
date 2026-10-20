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
  | { op: "remove"; req: number; appid: number };

export async function executeShortcutOp(op: ShortcutOp): Promise<void> {
  try {
    const apps = (window as any).SteamClient?.Apps;
    if (!apps?.AddShortcut || !apps?.RemoveShortcut) {
      throw new Error("SteamClient.Apps unavailable");
    }
    if (op.op === "add") {
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
