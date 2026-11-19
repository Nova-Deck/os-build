import { DialogButton, findClassModule, playSectionClasses } from "@decky/ui";
import { cloneElement, Component, isValidElement, useEffect, useMemo, useRef, type ReactElement, type ReactNode } from "react";
import { installTile, stopInstall } from "./backend";
import { confirmRemove, startUninstall } from "./lib/pageActions";
import {
  cachedSize,
  cloudLines,
  runAction,
  useCloudSaves,
  useDosVersions,
  useFollowReplacement,
  useInstallSize,
  useOnBoxtron,
  type Outcome,
} from "./lib/pageHooks";
import { cachedPage, cachedPending, setPending, usePageState } from "./lib/pageState";
import { patchActionButton } from "./native/actionButton";
import { patchRowFrom, setDecorators, unpatchRowAndSection } from "./native/actionRow";
import { applyGearMenu } from "./native/gearMenu";
import { withDisplayStatus } from "./native/overview";
import { nativeAction, type Intent } from "./native/status";
import { STORE_LABELS, type OurPage } from "./types";

// The game page is Steam's own. Nothing is hidden and nothing is redrawn: Steam's action button
// shows Install / Pause / Resume from our state (native/status.ts) and its press runs ours; the
// play bar's status area says what we know (store, size, drive, progress); a trash button sits
// beside Steam's controller and gear buttons; the gear menu carries Uninstall, the DOSBox version
// and the cloud-saves switch (native/gearMenu.tsx); the cloud-saves line sits where Steam puts its
// STEAM CLOUD line. An installed entry keeps Steam's own Play.
//
// If Steam's button cannot be found on this client, nothing here is patched and the legacy row
// (GamePage.tsx) takes over, so a Steam update never leaves our entries without an install surface.

let active = false;

export function isNativePageActive(): boolean {
  return active;
}

const GB = 1024 ** 3;
const gb = (bytes: number) => `${(bytes / GB).toFixed(1)} GB`;

const cx = (...names: Array<string | false | null | undefined>) => names.filter(Boolean).join(" ");

// Everything we put into Steam's page renders behind this: a throw in one of ours costs that part
// (Steam's own element shows instead), never Steam's whole game page. The render wrappers' own
// try/catch only covers building the elements, not React rendering them later. A class because
// React has no hook for this.
class Guard extends Component<{ fallback: ReactNode; children: ReactNode }, { failed: boolean }> {
  state = { failed: false };
  static getDerivedStateFromError() {
    return { failed: true };
  }
  componentDidCatch(e: unknown) {
    console.error("novadeck-stores: native game page part failed; Steam's own shows", e);
  }
  render() {
    return this.state.failed ? this.props.fallback : this.props.children;
  }
}

// ActionRow / AppButtons / AppActionButton: Steam's App-Details layout classes (not in
// @decky/ui's appDetailsClasses). Resolved lazily; an unresolved key degrades to "".
let detailsClasses: Record<string, string> | null = null;
function details(): Record<string, string> {
  if (!detailsClasses) {
    detailsClasses = (findClassModule((m: any) => m.ActionRow && m.AppButtons && m.AppActionButton) as any) ?? {};
  }
  return detailsClasses!;
}
const pc = playSectionClasses as unknown as Record<string, string>;

// What an install would need, and whether it can start at all.
function installFacts(page: OurPage, size: number | null | undefined) {
  const drive = page.drive;
  const needs = size ? `Needs ${gb(size)}` : size === null ? "Size unknown" : "Checking size…";
  const tooBig = !!(size && drive && size > drive.free);
  const where = drive ? `${drive.label}, ${gb(drive.free)} free` : "no drive available";
  const blocked = page.state === "install" && (!!page.busy || !drive || tooBig);
  return { needs, tooBig, where, blocked };
}

// ── The action button ──────────────────────────────────────

// Renders once, inside the play-bar row, so the row can be found and patched (native/actionRow.ts).
function RowProbe() {
  const ref = useRef<HTMLSpanElement>(null);
  useEffect(() => {
    if (ref.current) patchRowFrom(ref.current);
  }, []);
  return <span ref={ref} style={{ display: "none" }} />;
}

function DownloadBar({ percent }: { percent: number }) {
  return (
    <div className={pc.OnlyDownloadBar}>
      <div role="progressbar" aria-valuenow={percent} className={cx(pc.DetailsProgressContainer, pc.DownloadProgressBar)}>
        <div className={pc.DetailsProgressBar} style={{ width: `${percent}%` }} />
      </div>
    </div>
  );
}

const PRESS: Record<Exclude<Intent, "none">, (page: OurPage) => Promise<Outcome>> = {
  install: (page) => installTile(page.store, page.id),
  resume: (page) => installTile(page.store, page.id),
  stop: () => stopInstall(),
};

function factsOf(page: OurPage | null, size: number | null | undefined) {
  return page ? { state: page.state, blocked: installFacts(page, size).blocked } : null;
}

// A press on Steam's button over one of our proxies (native/actionButton.ts). Decided NOW, from
// the shared page state, not from what some button instance rendered last: the game page's button
// and a library surface's share it, and a press must never run a since-unmounted one's intent.
function press(appid: number): void {
  const page = cachedPage(appid);
  if (!page || cachedPending(appid)) return;
  const action = nativeAction(factsOf(page, cachedSize(page.token)), undefined, false);
  if (action.intent === "none") return;
  const run = PRESS[action.intent];
  setPending(appid, true);
  void runAction(appid, page.title, () => run(page)).finally(() => setPending(appid, false));
}

function ActionHost({ element, appid }: { element: ReactElement<{ overview?: any; className?: unknown }>; appid: number }) {
  const { page, pending } = usePageState(appid);
  const size = useInstallSize(page);
  const overview = element.props.overview;
  const realStatus = overview?.selected_per_client_data?.display_status;
  const action = nativeAction(factsOf(page, size), typeof realStatus === "number" ? realStatus : undefined, pending);

  // The same button renders on library surfaces: the bar and the page move belong to the game
  // page's button only.
  const pageClass = details().AppActionButton;
  const className = element.props.className;
  const onGamePage = !!pageClass && typeof className === "string" && className.includes(pageClass);
  useFollowReplacement(appid, onGamePage ? page : null);

  const proxied = useMemo(
    () => (overview && action.status !== null ? withDisplayStatus(overview, action.status) : null),
    [overview, action.status],
  );

  // Under the button, where Steam draws its own download's bar.
  const raw = page?.state === "downloading" ? page.percent : undefined;
  const percent = onGamePage && page?.state === "downloading" ? Math.max(0, Math.min(100, typeof raw === "number" ? raw : 0)) : null;
  return (
    <>
      <RowProbe />
      {proxied ? cloneElement(element, { overview: proxied }) : element}
      {percent !== null && <DownloadBar percent={percent} />}
    </>
  );
}

// ── The play bar: status area, trash button, cloud line ────

function statusWords(page: OurPage, size: number | null | undefined): [label: string, detail: string] {
  const store = STORE_LABELS[page.store] ?? page.store;
  const f = installFacts(page, size);
  const waiting = page.busy ? ` · Waiting: ${page.busy} is installing` : "";
  switch (page.state) {
    case "install":
      return [store, `${f.needs} · ${f.tooBig ? `Not enough space on ${f.where}` : `To ${f.where}`}${waiting}`];
    case "downloading":
      // The installer's percent passes through as-is: absent or null until it has one.
      return ["Downloading", typeof page.percent === "number" ? `${store} · ${page.percent.toFixed(1)}%` : `${store} · starting…`];
    case "paused":
      return ["Paused", `${store} · ${f.needs}${waiting}`];
    case "finishing":
      return ["Installing", `${store} · getting it ready to play…`];
    case "stale":
      return ["Removed", `${store} · sync the library in NovaDeck Stores to make it installable again`];
    case "installed":
      return [store, ""];
  }
}

// In place of Steam's StatusAndStats while the entry is not installed (Steam's has nothing to say
// about our download); an installed entry keeps Steam's own: last played and play time.
function StatusArea({ appid, fallback }: { appid: number; fallback: ReactNode }) {
  const { page, err } = usePageState(appid);
  const size = useInstallSize(page);
  if (!page || page.state === "installed") return <>{fallback}</>;
  const [label, detail] = statusWords(page, size);
  return (
    <div className={pc.StatusAndStats}>
      <div className={cx(pc.DetailsSection, page.state === "downloading" && pc.Downloading)}>
        <div className={cx(pc.PlayBarLabel, pc.DetailsSectionStatus)}>{label}</div>
        <div className={cx(pc.PlayBarDetailLabel, pc.DetailsSectionExtra)}>
          {err ? `${detail} · could not refresh: ${err}` : detail}
        </div>
      </div>
    </div>
  );
}

const TRASH = (
  <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
    <path d="M4 7h16M10 11v6M14 11v6M5 7l1 13h12l1-13M9 7V4h6v3" />
  </svg>
);

// Beside Steam's controller and gear buttons: Uninstall for an installed entry, Remove for a
// paused download. One press from the page, as the old row had it; the gear menu offers both too.
function TrashButton({ appid }: { appid: number }) {
  const { page } = usePageState(appid);
  if (!page || (page.state !== "installed" && page.state !== "paused")) return null;
  const label = page.state === "installed" ? "Uninstall" : "Remove download";
  return (
    <div className={pc.MenuButtonContainer}>
      <DialogButton
        className={pc.MenuButton}
        style={{ minWidth: 0, width: "auto", padding: "0 12px", display: "flex", alignItems: "center" }}
        aria-label={label}
        onClick={() => (page.state === "installed" ? startUninstall(page) : confirmRemove(page))}
      >
        {TRASH}
      </DialogButton>
    </div>
  );
}

const CLOUD = (
  <svg width="18" height="18" viewBox="0 0 24 24" fill="currentColor">
    <path d="M18 10a6 6 0 0 0-11.6-2A4.5 4.5 0 0 0 6.5 17H18a3.5 3.5 0 0 0 0-7Z" />
  </svg>
);

// Under the PlaySection, where Steam puts its own STEAM CLOUD line.
function CloudLine({ appid }: { appid: number }) {
  const { page, version } = usePageState(appid);
  const installed = page !== null && page.state === "installed";
  const lines = cloudLines(useCloudSaves(appid, installed, version));
  if (!installed || lines.length === 0) return null;
  return (
    <div className={pc.CloudStatusRow}>
      <span className={pc.CloudStatusIcon}>{CLOUD}</span>
      <span className={pc.CloudStatusLabel}>
        {lines.map((line) => (
          <div key={line}>{line}</div>
        ))}
      </span>
    </div>
  );
}

// Draws nothing. The gear menu renders synchronously from cached answers (native/gearMenu.tsx), so
// while the game page is open this keeps them current: whether the entry runs under Boxtron
// (SUBSCRIBED: appDetailsStore's copy stayed on Proton after a switch to Boxtron, HW 2026-11-19)
// and its DOSBox versions. Without it the menu never offered "DOSBox version…".
function GearFacts({ appid }: { appid: number }) {
  const { page, version } = usePageState(appid);
  const installed = page !== null && page.state === "installed";
  useOnBoxtron(appid, installed);
  useDosVersions(appid, installed, version);
  return null;
}

function childList(children: unknown): ReactNode[] {
  return Array.isArray(children) ? children : children == null ? [] : [children as ReactNode];
}

function decorateRow(row: ReactElement, appid: number): ReactElement {
  const appButtons = details().AppButtons;
  const kids = childList((row.props as { children?: unknown }).children).map((child) => {
    if (!isValidElement(child)) return child;
    const p = child.props as { statusPanelType?: unknown; className?: unknown; children?: unknown };
    // Keyed by appid: a part React would otherwise reuse for the next game starts afresh.
    if (p.statusPanelType !== undefined) {
      return (
        <Guard key={`novadeck-status-${appid}`} fallback={child}>
          <StatusArea appid={appid} fallback={child} />
        </Guard>
      );
    }
    if (appButtons && typeof p.className === "string" && p.className.includes(appButtons)) {
      const trash = (
        <Guard key={`novadeck-trash-${appid}`} fallback={null}>
          <TrashButton appid={appid} />
        </Guard>
      );
      return cloneElement(child, undefined, ...childList(p.children), trash);
    }
    return child;
  });
  return cloneElement(row, undefined, ...kids);
}

function decorateSection(section: ReactElement, appid: number): ReactElement {
  return (
    <>
      {section}
      <Guard key={`novadeck-cloud-${appid}`} fallback={null}>
        <CloudLine appid={appid} />
        <GearFacts appid={appid} />
      </Guard>
    </>
  );
}

// Install every native patch. Returns the disposer, or null when Steam's button is not found (the
// legacy row then stays in charge).
export function applyNativePage(): (() => void) | null {
  let removeGearMenu: () => void = () => undefined;
  // Everything but the button itself: on a broken click seam the legacy row takes the page back,
  // and our status area, trash and cloud line must not stand beside it.
  const standDown = () => {
    active = false;
    removeGearMenu();
    removeGearMenu = () => undefined;
    setDecorators(null, null);
    unpatchRowAndSection();
  };
  let unpatchButton: (() => void) | null = null;
  try {
    unpatchButton = patchActionButton(
      (element, appid) => (
        <Guard key={`novadeck-action-${appid}`} fallback={element}>
          <ActionHost element={element as ReactElement<{ overview?: any }>} appid={appid} />
        </Guard>
      ),
      press,
      standDown,
    );
  } catch (e) {
    console.error("novadeck-stores: native game page not installed; the legacy row stays", e);
    return null;
  }
  if (!unpatchButton) {
    console.warn("novadeck-stores: Steam's action button not found; the legacy row stays");
    return null;
  }
  setDecorators(decorateRow, decorateSection);
  removeGearMenu = applyGearMenu();
  active = true;
  const button = unpatchButton;
  return () => {
    standDown();
    button();
  };
}
