import { Router } from "@decky/ui";
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

// The name a tweaks entry should cache, if we can resolve one right now. Empty when we cannot —
// an entry then keeps whatever name it already had rather than being overwritten with nothing.
export function knownGameName(config: Config, appid: string): string {
  const running = currentGame();
  if (running?.appid === appid && running.name && !running.name.startsWith("App ")) return running.name;
  const found = (config.installedGames || []).find((game) => String(game?.appid) === appid);
  return found?.name || "";
}

export function editTargetOptions(config: Config): DropdownChoice[] {
  const games = new Map<string, GameRef>();
  // Anything that already has a tweaks entry stays selectable even if uninstalled —
  // otherwise its settings would become unreachable rather than deletable. Its name comes from
  // the copy cached in the entry itself: the live name is read from Steam's appmanifest, which
  // the uninstall deletes, so without the cache these read as a bare "App <id>".
  for (const [appid, tweak] of Object.entries(config.tweaks?.games || {})) {
    games.set(appid, { appid, name: (tweak as any)?.name || "" });
  }
  for (const game of config.installedGames || []) {
    if (game?.appid && game.appid !== "0") {
      games.set(String(game.appid), { appid: String(game.appid), name: game.name || "" });
    }
  }
  const running = currentGame();
  if (running) games.set(running.appid, running);
  // "Installed" is what Steam still has a manifest for, PLUS whatever is running right now — a
  // running title is self-evidently present, and labelling it "(not installed)" because it is a
  // shortcut or an unlisted library would read as a bug.
  const present = new Set((config.installedGames || []).map((game) => String(game?.appid)));
  if (running) present.add(running.appid);
  const list = Array.from(games.values()).sort((a, b) => gameDisplayName(a).localeCompare(gameDisplayName(b)));
  return [
    { data: "", label: "Global (all games)" },
    ...list.map((game) => ({
      data: game.appid,
      // Say the state outright. These entries are not dormant: they stay keyed on the appid and
      // re-apply if the game is reinstalled, so "not installed" is the honest label — silence
      // would leave settings that still bite looking like clutter.
      label: present.has(game.appid) ? gameDisplayName(game) : `${gameDisplayName(game)} (not installed)`,
    })),
  ];
}
