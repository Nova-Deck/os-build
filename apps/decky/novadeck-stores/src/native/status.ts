// What Steam's own action button shows and does for one of our not-installed entries.
//
// The button picks its label, icon and tone from one value, the overview's
// `selected_per_client_data.display_status` (Steam's EDisplayStatus). We hand it an overview that
// answers that read with a status matching OUR state (overview.ts), so the button is Steam's own
// Install / Pause / Resume. Pure and import-free so tests/test-store-native-page.sh runs it.
//
// EDisplayStatus as read on the Pocket Max (client 1792618285, 2026-11-19), with the button action
// Steam's own switch gives each:
//   1 Launching -> Cancel   3 Installing -> none (disabled, throbber)   4 Running -> Resume/Stop
//   7 Downloading -> Pause  9 ReadyToInstall -> Install                 11 ReadyToLaunch -> Play
//   14 InvalidPlatform -> none                                          22 DownloadPaused -> Resume
//   36 Terminating -> none

export const DisplayStatus = {
  Launching: 1,
  Installing: 3,
  Running: 4,
  Downloading: 7,
  ReadyToInstall: 9,
  ReadyToLaunch: 11,
  InvalidPlatform: 14,
  DownloadPaused: 22,
  Terminating: 36,
} as const;

// While Steam itself drives the app (launching it, running it, shutting it down) its button stays
// entirely Steam's, label and click.
export const LIVE_STATUSES: ReadonlySet<number> = new Set([
  DisplayStatus.Launching,
  DisplayStatus.Running,
  DisplayStatus.Terminating,
]);

export type PageStateName = "install" | "downloading" | "paused" | "finishing" | "installed" | "stale";

// "none": a press that must not reach Steam. Steam's Play on a not-installed entry would run the
// install stub a second time; on a finishing one it would launch a half-installed game.
export type Intent = "install" | "stop" | "resume" | "none";

// `status` null: hand the button Steam's real overview, so label and click are Steam's own.
export type NativeAction = { status: number | null; intent: Intent };

export type PageFacts = {
  state: PageStateName;
  // Install cannot start: no drive, not enough space, or another game holds the install slot.
  blocked: boolean;
};

const STOCK: NativeAction = { status: null, intent: "none" };

// `facts` null: not ours, or not known yet. Steam's own button stays, and its Play on a
// not-installed entry runs the stub, which installs: the fallback this whole page rides on.
// `pending`: a press is being answered (an install start asks the store first, which can take many
// seconds): Steam's disabled button with its throbber, rather than one that looks ignored.
export function nativeAction(facts: PageFacts | null, realStatus: number | undefined, pending: boolean): NativeAction {
  if (realStatus !== undefined && LIVE_STATUSES.has(realStatus)) return STOCK;
  if (!facts) return STOCK;
  if (pending) return { status: DisplayStatus.Installing, intent: "none" };
  switch (facts.state) {
    case "install":
      return facts.blocked
        ? { status: DisplayStatus.InvalidPlatform, intent: "none" }
        : { status: DisplayStatus.ReadyToInstall, intent: "install" };
    case "downloading":
      // Steam's Pause, and ours is a pause too: Stop keeps what has downloaded (installs.py).
      return { status: DisplayStatus.Downloading, intent: "stop" };
    case "paused":
      // Another game holding the install slot is the backend's to refuse, in words (a toast).
      return { status: DisplayStatus.DownloadPaused, intent: "resume" };
    case "finishing":
      return { status: DisplayStatus.Installing, intent: "none" };
    case "stale":
      return { status: DisplayStatus.InvalidPlatform, intent: "none" };
    case "installed":
      return STOCK;
  }
}
