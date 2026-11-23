// A paired host's Steam tile. Made and removed through Steam's own API, so Steam keeps its own file;
// the backend keeps which tiles are ours (hosts.py).
import { getHosts, rememberTile, forgetHost } from "./backend";
import { scheduleTabRefresh } from "./SunshineTab";
import type { Host, Hosts, TileHost } from "./types";

const LAUNCHER = "/usr/lib/novadeck/stream-host";
const LAUNCHER_DIR = "/usr/lib/novadeck";

function steamApps(): any {
  const apps = (window as any).SteamClient?.Apps;
  if (!apps?.AddShortcut || !apps?.RemoveShortcut) throw new Error("Steam's shortcut calls are not there");
  return apps;
}

const tileExists = (appid: number) => Boolean((window as any).appStore?.GetAppOverviewByAppID?.(appid >>> 0));

// One tile per host, whatever it is called and wherever it is: a host paired again keeps its tile.
export async function ensureTile(host: Host): Promise<Hosts> {
  const known = await getHosts();
  if (known.problem) return known;
  const tile = known.hosts.find((h) => h.uuid === host.uuid);
  if (tile && tileExists(tile.appid)) return known;
  const apps = steamApps();
  const name = host.name || host.address;
  const appid: number = await apps.AddShortcut(name, LAUNCHER, LAUNCHER_DIR, host.uuid);
  if (!appid) throw new Error("Steam did not make the tile");
  // AddShortcut's trailing arguments are not trusted across client versions (novadeck-stores).
  apps.SetShortcutName(appid, name);
  apps.SetShortcutLaunchOptions(appid, host.uuid);
  apps.SetShortcutStartDir(appid, LAUNCHER_DIR);
  // A tile we could not write down is one we could never take away.
  let kept: Hosts;
  try {
    kept = await rememberTile(host.uuid, name, appid);
  } catch (e) {
    apps.RemoveShortcut(appid >>> 0);
    throw e;
  }
  if (kept.problem) apps.RemoveShortcut(appid >>> 0);
  scheduleTabRefresh();
  return kept;
}

// Forgotten first: a tile that is still there but not ours is a leftover the user can remove, where a
// host whose tile is gone would be listed for good.
export async function removeTile(host: TileHost): Promise<Hosts> {
  const left = await forgetHost(host.uuid);
  if (!left.problem) {
    steamApps().RemoveShortcut(host.appid >>> 0);
    scheduleTabRefresh();
  }
  return left;
}
