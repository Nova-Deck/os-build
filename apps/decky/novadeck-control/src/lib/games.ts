import { Router } from "@apps/decky/ui";
import type { Config, DropdownChoice, GameRef } from "../types";

export function gameDisplayName(game: GameRef | null | undefined): string {
  if (!game?.appid) return "";
  return game.name || `App ${game.appid}`;
}

// The running app, straight from SteamUI's own router state. appid "0" never appears here
// (it is Valve's no-app sentinel on compat-tool helper launches, not a UI app).
export function currentGame(): GameRef | null {
  const running = (Router as any)?.MainRunningApp || (window as any).Router?.MainRunningApp;
  const appid = running?.appid;
  if (!appid) return null;
  const id = String(appid);
  let name = running?.display_name || running?.displayName || "";
  try {
    const details: any = (window as any).appDetailsStore?.GetAppDetails?.(Number(id));
    name = details?.strDisplayName || details?.strName || details?.name || name;
  } catch (error) {
    // best effort: the id alone is enough to key the tweaks entry
  }
  return { appid: id, name: name || `App ${id}` };
}

export function editTargetOptions(config: Config): DropdownChoice[] {
  const games = new Map<string, GameRef>();
  // Anything that already has a tweaks entry stays selectable even if uninstalled —
  // otherwise its settings would become unreachable rather than deletable.
  for (const appid of Object.keys(config.tweaks?.games || {})) {
    games.set(appid, { appid, name: `App ${appid}` });
  }
  for (const game of config.installedGames || []) {
    if (game?.appid && game.appid !== "0") {
      games.set(String(game.appid), { appid: String(game.appid), name: game.name || `App ${game.appid}` });
    }
  }
  const running = currentGame();
  if (running) games.set(running.appid, running);
  const list = Array.from(games.values()).sort((a, b) => gameDisplayName(a).localeCompare(gameDisplayName(b)));
  return [
    { data: "", label: "Global (all games)" },
    ...list.map((game) => ({ data: game.appid, label: gameDisplayName(game) })),
  ];
}
