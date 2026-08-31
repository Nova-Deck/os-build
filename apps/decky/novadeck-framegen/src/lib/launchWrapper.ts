// Per-game tuning for tools we do NOT own, via Steam launch options.
//
// Our baked Protons carry an in-tool shim (assemble-rootfs.sh rewrites their `commandline`), which
// is automatic and keeps no per-game state — but it only ever fronts a Proton we bake. Steam's own
// arm64 Proton (app 4628740) is user data the client owns, verifies and updates, and since the
// FEX-tool client update it is what Steam picks by DEFAULT for Windows titles. A game on that
// Proton gets no profile, no per-game FEX config and no `cores` topology, and nothing says so.
//
// Launch options close that gap: Steam evaluates them on the host and expands `%command%` to the
// whole chain it assembled, whatever tool that is. The two mechanisms compose rather than fight —
// whichever runs first writes FEX_APP_CONFIG and the inner one honours it.
//
// ABSOLUTE PATH on purpose: launch options run through a shell whose PATH does not include ours.
export const LAUNCH_WRAPPER = "/usr/lib/novadeck/game-launch";
const COMMAND_TOKEN = "%command%";

// null means "already correct, write nothing" — a redundant SetAppLaunchOptions is a config write
// and a cloud-sync event for no reason.
export function wrapLaunchOptions(current: string): string | null {
  const options = current || "";
  if (options.includes(LAUNCH_WRAPPER)) return null;
  if (options.includes(COMMAND_TOKEN)) {
    return options.replace(COMMAND_TOKEN, `${LAUNCH_WRAPPER} ${COMMAND_TOKEN}`);
  }
  // No %command%: Steam appends bare options to the command as arguments, so they must stay
  // AFTER it or they would be read as arguments to the wrapper instead of to the game.
  const trimmed = options.trim();
  return trimmed
    ? `${LAUNCH_WRAPPER} ${COMMAND_TOKEN} ${trimmed}`
    : `${LAUNCH_WRAPPER} ${COMMAND_TOKEN}`;
}

// Removing ours must leave the user's own options exactly as they were — including a %command%
// they wrote themselves, which is why the token is only dropped when it is the sole survivor.
export function unwrapLaunchOptions(current: string): string | null {
  const options = current || "";
  if (!options.includes(LAUNCH_WRAPPER)) return null;
  const stripped = options.replace(`${LAUNCH_WRAPPER} `, "").replace(LAUNCH_WRAPPER, "").trim();
  return stripped === COMMAND_TOKEN ? "" : stripped;
}

function currentLaunchOptions(appid: string): string {
  try {
    const details: any = (window as any).appDetailsStore?.GetAppDetails?.(Number(appid));
    return String(details?.strLaunchOptions || "");
  } catch (error) {
    return "";
  }
}

// Best effort by contract: a game must never fail to launch because we could not write an option.
// The in-tool shim still covers our own Protons if this does nothing.
export async function syncLaunchWrapper(appid: string, wanted: boolean): Promise<boolean> {
  if (!appid || appid === "0") return false;
  const apps = (window as any).SteamClient?.Apps;
  if (!apps?.SetAppLaunchOptions) return false;
  const current = currentLaunchOptions(appid);
  const next = wanted ? wrapLaunchOptions(current) : unwrapLaunchOptions(current);
  if (next === null) return false;
  try {
    apps.SetAppLaunchOptions(Number(appid), next);
    return true;
  } catch (error) {
    return false;
  }
}
