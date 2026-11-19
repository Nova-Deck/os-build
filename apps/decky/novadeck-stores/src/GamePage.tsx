import { routerHook, toaster } from "@decky/api";
import {
  afterPatch,
  appDetailsClasses,
  appDetailsHeaderClasses,
  basicAppDetailsSectionStylerClasses,
  ConfirmModal,
  createReactTreePatcher,
  DialogButton,
  findInReactTree,
  Focusable,
  playSectionClasses,
  showModal,
} from "@decky/ui";
import { Component, useEffect, useRef, useState } from "react";
import { installTile, setCloudSaves, stopInstall, uninstallGame } from "./backend";
import { showDosVersionSetting } from "./DosVersionDialog";
import {
  cloudLines,
  runAction,
  useCloudSaves,
  useDosVersions,
  useFollowReplacement,
  useInstallSize,
  useOnBoxtron,
  type Outcome,
} from "./lib/pageHooks";
import { refreshPageState, usePageState } from "./lib/pageState";
import { isNativePageActive } from "./NativePage";
import { STORE_LABELS, type CloudSaves, type DosVersions, type OurPage } from "./types";
import { confirmUninstall } from "./UninstallDialog";

// THE LEGACY ROW. Steam's own page, steered with our state (NativePage.tsx), is the game page now;
// this row only renders while that could not be patched on this client (isNativePageActive false),
// so a Steam update that moves one of its seams still leaves an install surface on the page.
//
// Milestone 7 revision 2, R1: the install surface is Steam's OWN game page. For one of our
// not-installed entries the page's Play row is replaced by Install / progress + Stop / Resume +
// Remove; for an installed one Steam's native Play stays and an Uninstall row is added. The stub
// stays the fallback: when this patch cannot apply (a Steam update moved an anchor), pressing
// Play on a not-installed entry still installs.
//
// The shape is unifideck's AppDetailsPatch (renderFunc afterPatch, rows spliced into the
// InnerContainer, the native Play row hidden by CSS under a marker class), with two differences
// the R0 probe and our ownership model decided:
//   * the row is anchored after the HEADER (TopCapsule / Header): on this arm64 client the play
//     section's own Container class is absent from the page (R0, 2026-10-22);
//   * whether an entry is OURS is the backend's registry answer, never unifideck's appid > 2e9
//     — every shortcut has such an appid, the user's own ones included.

const ROUTE = "/library/app/:appid";
// Every non-Steam shortcut's appid has the top bit set, so a Steam game's page is left alone
// without a backend round trip. A pre-filter only: ours or not is the registry's answer.
const SHORTCUT_BIT = 0x80000000;
const GB = 1024 ** 3;

type Node = { key?: unknown; props?: { className?: unknown; children?: unknown; [k: string]: unknown } };
type PatchedFn = ((...args: unknown[]) => unknown) & { __novadeckPatched?: boolean };

const pageMarker = (appid: number) => `novadeck-page-${appid}`;

function classOf(node: unknown): string {
  const cn = (node as Node | null)?.props?.className;
  return typeof cn === "string" ? cn : "";
}

function headerIndex(children: unknown[]): number {
  const anchors = [appDetailsHeaderClasses?.TopCapsule, appDetailsClasses?.Header].filter(
    (c): c is string => typeof c === "string" && c !== "",
  );
  return children.findIndex((c) => anchors.some((a) => classOf(c).includes(a)));
}

function overviewOf(tree: unknown): { appid: number } | undefined {
  return findInReactTree(tree, (x: any) => x?.props?.children?.props?.overview != null)?.props?.children?.props
    ?.overview;
}

function inject(ret: unknown) {
  // Steam's own button and play bar carry our state: nothing to hide, nothing to add. Read on every
  // render, so a native seam failing mid-session brings this row back on the next one.
  if (isNativePageActive()) return;
  const appid = overviewOf(ret)?.appid;
  if (typeof appid !== "number" || (appid >>> 0) < SHORTCUT_BIT) return;
  const unsigned = appid >>> 0;
  const inner = findInReactTree(ret, (x: any) => {
    const cls = appDetailsClasses?.InnerContainer;
    return Array.isArray(x?.props?.children) && typeof cls === "string" && classOf(x).includes(cls);
  }) as Node | undefined;
  if (!inner?.props || !Array.isArray(inner.props.children)) return;
  // The marker scopes the native-Play hide to THIS page (PlayRow renders the rule only when the
  // entry is ours and not installed). Re-applied every render; idempotent.
  const marker = pageMarker(unsigned);
  if (!classOf(inner).includes(marker)) inner.props.className = `${classOf(inner)} ${marker}`.trim();
  const children = inner.props.children as unknown[];
  const key = `novadeck-play-${unsigned}`;
  if (children.some((c) => (c as Node | null)?.key === key)) return;
  const at = headerIndex(children);
  // No anchor yet: the next render tries again. A guessed position lands the row in the page's
  // top strip, which is worse than no row — and the stub still installs on Play.
  if (at < 0) return;
  children.splice(
    at + 1,
    0,
    <RowBoundary key={key}>
      <PlayRow appid={unsigned} />
    </RowBoundary>,
  );
}

// Returns the unpatch. The renderFunc wrapper is marked so a second pass of the route patch (and
// another plugin co-patching the route) never wraps it twice.
export function applyGamePagePatch(): () => void {
  const patch = routerHook.addPatch(ROUTE, (tree: any) => {
    const route = findInReactTree(tree, (x: any) => typeof x?.renderFunc === "function");
    if (!route || (route.renderFunc as PatchedFn).__novadeckPatched) return tree;
    const handler = createReactTreePatcher(
      [(t: unknown) => findInReactTree(t, (x: any) => x?.props?.children?.props?.overview != null)?.props?.children],
      (_args: unknown[], ret: unknown) => {
        try {
          inject(ret);
        } catch (e) {
          // Never break Steam's page over our row: the page renders without it, and Play still
          // installs through the stub. Said in the console, where a client update would show up.
          console.error("novadeck-stores: game page patch failed", e);
        }
        return ret;
      },
      "NovaDeckGamePage",
    );
    afterPatch(route, "renderFunc", handler);
    (route.renderFunc as PatchedFn).__novadeckPatched = true;
    return tree;
  });
  return () => routerHook.removePatch(ROUTE, patch);
}

// Hides Steam's own Play row on this page only. Gaming Mode's row is PlaySection; the desktop
// one, Container, is kept for a client that renders it. Inline in the row, so it lands in the
// document the page renders in.
function hideNativePlay(appid: number): string {
  const classes = [basicAppDetailsSectionStylerClasses?.PlaySection, playSectionClasses?.Container].filter(
    (c): c is string => typeof c === "string" && c !== "",
  );
  return classes.map((c) => `.${pageMarker(appid)} [class*="${c}"]{display:none !important;}`).join("\n");
}

const rowCss = `
  /* NEVER put a backtick in this string: it is a template literal (see styles.ts). */
  .novadeck-play-row {
    display: flex;
    align-items: center;
    gap: 16px;
    padding: 16px 2.8vw;
  }
  /* width: auto beats DialogButton's own width: 100% — without it the button takes the whole
     row and squeezes the text beside it to a column one letter wide (HW, 2026-10-22). */
  .novadeck-play-row .novadeck-play-primary {
    width: auto !important;
    min-width: 200px;
    height: 48px;
    flex: 0 0 auto;
  }
  .novadeck-play-row .novadeck-play-secondary {
    width: auto !important;
    height: 48px;
    flex: 0 0 auto;
  }
  .novadeck-play-row .novadeck-play-meta {
    display: flex;
    flex-direction: column;
    gap: 4px;
    font-size: 14px;
    flex: 1 1 auto;
    min-width: 0;
  }
  .novadeck-play-row .novadeck-play-note {
    opacity: 0.7;
  }
  .novadeck-play-row .novadeck-play-bar {
    width: 240px;
    height: 4px;
    border-radius: 2px;
    background: rgba(255, 255, 255, 0.15);
    overflow: hidden;
  }
  .novadeck-play-row .novadeck-play-bar-fill {
    height: 100%;
    background: #1a9fff;
    transition: width 0.5s linear;
  }
`;

function gb(bytes: number) {
  return `${(bytes / GB).toFixed(1)} GB`;
}

function confirm(title: string, description: string, ok: string, onOK: () => void) {
  showModal(
    <ConfirmModal strTitle={title} strDescription={description} strOKButtonText={ok} bDestructiveWarning onOK={onOK} />,
  );
}

// Steam's page focuses its own Play button on open. With that hidden, nothing on the row would
// have focus, so the primary button takes it — once, on mount, and never back from wherever the
// user has since moved it (unifideck's PlayShell does the same, for the same reason).
function useFocusOnMount(ref: React.RefObject<HTMLDivElement | null>, enabled: boolean) {
  const done = useRef(false);
  useEffect(() => {
    if (!enabled || done.current) return;
    done.current = true;
    const raf = requestAnimationFrame(() => ref.current?.querySelector<HTMLElement>("button")?.focus());
    return () => cancelAnimationFrame(raf);
  }, [enabled]);
}

// A throw while rendering our row must cost the row, never Steam's whole game page: the patch's
// try/catch covers the splice, not later renders. A class because React has no hook for this.
class RowBoundary extends Component<{ children: React.ReactNode }, { failed: boolean }> {
  state = { failed: false };
  static getDerivedStateFromError() {
    return { failed: true };
  }
  componentDidCatch(e: unknown) {
    console.error("novadeck-stores: game page row failed", e);
  }
  render() {
    return this.state.failed ? null : this.props.children;
  }
}

function PlayRow({ appid }: { appid: number }) {
  // The page's state is shared with the rest of the page (lib/pageState.ts): the last GOOD answer
  // and the latest failure, kept apart, so one failed poll does not drop the row and bring Steam's
  // Play back (or re-grab focus when it recovers).
  const { page, err, version } = usePageState(appid);
  const [busy, setBusy] = useState(false);
  const ref = useRef<HTMLDivElement>(null);
  useFollowReplacement(appid, page);
  const size = useInstallSize(page);

  // boxtron-dos phase 3: an installed GOG DOS title with several DOSBox versions gets a "DOSBox
  // version" button — but only while its compat tool IS Boxtron. Under Proton the choice does
  // nothing (GOG's own launcher asks), so offering it there was a setting with no effect.
  // gog-comet phase 3 step 8: its "Cloud saves" switch and lines.
  const installed = page !== null && page.state === "installed";
  const onBoxtron = useOnBoxtron(appid, installed);
  const dos = useDosVersions(appid, installed, version);
  const cloud = useCloudSaves(appid, installed, version);

  const hidesPlay = page !== null && page.state !== "installed";
  useFocusOnMount(ref, hidesPlay);

  // Not ours, or not known yet: Steam's page untouched — an error on a page we never claimed is
  // none of our business.
  if (!page) return null;

  const run = async (fn: () => Promise<Outcome>) => {
    setBusy(true);
    try {
      await runAction(appid, page.title, fn);
    } finally {
      setBusy(false);
      // The pressed button disabled itself while busy, which drops focus to the document: with
      // nothing focused the gamepad drives nothing until the stick is moved (HW 2026-10-22).
      // Restored only when focus is still nowhere, never taken back from where the user went.
      window.setTimeout(() => {
        const lost = document.activeElement === null || document.activeElement === document.body;
        if (lost) ref.current?.querySelector<HTMLElement>("button:not([disabled])")?.focus();
      }, 0);
    }
  };

  return (
    <Focusable ref={ref} className="novadeck-play-row" flow-children="row">
      <style>{rowCss + (hidesPlay ? hideNativePlay(appid) : "")}</style>
      <RowBody
        page={page}
        size={size}
        busy={busy}
        run={run}
        dos={onBoxtron ? dos : null}
        cloud={cloud}
        refresh={() => refreshPageState(appid)}
      />
      {err ? <span className="novadeck-play-note">{`Could not refresh: ${err}`}</span> : null}
    </Focusable>
  );
}

type BodyProps = {
  page: OurPage;
  size: number | null | undefined;
  busy: boolean;
  run: (fn: () => Promise<Outcome>) => void;
  dos: DosVersions | null;
  cloud: CloudSaves | null;
  refresh: () => void;
};

function Meta({ lines }: { lines: (string | null | undefined)[] }) {
  return (
    <div className="novadeck-play-meta">
      {lines.filter(Boolean).map((l) => (
        <span key={l as string} className="novadeck-play-note">
          {l}
        </span>
      ))}
    </div>
  );
}

function RowBody({ page, size, busy, run, dos, cloud, refresh }: BodyProps) {
  const store = STORE_LABELS[page.store] ?? page.store;
  const waiting = page.busy ? `Waiting: ${page.busy} is installing` : null;
  const needs = size ? `Needs ${gb(size)}` : size === null ? "Size unknown" : "Checking size…";
  const remove = () =>
    confirm(`Remove ${page.title}?`, "This deletes what has downloaded so far.", "Remove", () =>
      run(() => uninstallGame(page.store, page.id)),
    );

  switch (page.state) {
    case "install": {
      const drive = page.drive;
      // Refused here rather than by a press that can only answer "not enough free space".
      const tooBig = !!(size && drive && size > drive.free);
      const where = drive ? `${drive.label}, ${gb(drive.free)} free` : "no drive available";
      return (
        <>
          <DialogButton
            className="novadeck-play-primary"
            disabled={busy || !!page.busy || !drive || tooBig}
            onClick={() => run(() => installTile(page.store, page.id))}
          >
            {/* A start asks the store for the game first, which can take many seconds on a slow
                network: say so, rather than a grey button that looks like it ignored the press. */}
            {busy ? "Starting…" : "Install"}
          </DialogButton>
          <Meta lines={[`${store} · ${needs}`, tooBig ? `Not enough space on ${where}` : `To ${where}`, waiting]} />
        </>
      );
    }
    case "downloading": {
      const pct = Math.max(0, Math.min(100, page.percent ?? 0));
      return (
        <>
          {/* Stop is the clean, resumable stop (KillSignal=SIGINT, installs.py): nothing is lost. */}
          <DialogButton className="novadeck-play-primary" disabled={busy} onClick={() => run(stopInstall)}>
            Stop
          </DialogButton>
          <div className="novadeck-play-meta">
            <span className="novadeck-play-note">
              {page.percent === undefined ? `${store} · starting…` : `${store} · downloading ${pct.toFixed(1)}%`}
            </span>
            <div className="novadeck-play-bar">
              <div className="novadeck-play-bar-fill" style={{ width: `${pct}%` }} />
            </div>
          </div>
        </>
      );
    }
    case "paused":
      return (
        <>
          <DialogButton
            className="novadeck-play-primary"
            disabled={busy || !!page.busy}
            onClick={() => run(() => installTile(page.store, page.id))}
          >
            {busy ? "Starting…" : "Resume"}
          </DialogButton>
          <DialogButton className="novadeck-play-secondary" disabled={busy} onClick={remove}>
            Remove
          </DialogButton>
          <Meta lines={[`${store} · paused · ${needs}`, waiting]} />
        </>
      );
    case "finishing":
      return <Meta lines={[`${store} · installed — getting it ready to play…`]} />;
    case "stale":
      return (
        <Meta lines={[`${store} · removed. Sync the library in NovaDeck Stores to make it installable again.`]} />
      );
    case "installed": {
      const uninstall = () =>
        confirmUninstall(page.store, page.id, page.title, "this page", (dropPrefix) =>
          run(() => uninstallGame(page.store, page.id, dropPrefix)),
        );
      const versions = dos && dos.labels.length > 1 ? dos : null;
      const chooseVersion = () =>
        versions &&
        showDosVersionSetting(page.appid, page.title, versions.labels, versions.choice, (message) => {
          toaster.toast({ title: page.title, body: message });
          refresh();
        });
      // A press flips the switch; the row re-reads after (run bumps the tick). Turning it off is
      // undone by pressing again, so no confirmation.
      const switchable = cloud && (cloud.state === "on" || cloud.state === "off") ? cloud : null;
      const toggleCloud = () =>
        switchable &&
        run(async () => {
          const res = await setCloudSaves(page.appid, switchable.state === "off");
          return "error" in res ? { error: `Cloud saves: ${res.error}` } : {};
        });
      return (
        <>
          <DialogButton className="novadeck-play-secondary" disabled={busy} onClick={uninstall}>
            Uninstall
          </DialogButton>
          {versions && (
            <DialogButton className="novadeck-play-secondary" disabled={busy} onClick={chooseVersion}>
              DOSBox version
            </DialogButton>
          )}
          {switchable && (
            <DialogButton className="novadeck-play-secondary" disabled={busy} onClick={toggleCloud}>
              {switchable.state === "on" ? "Cloud saves: On" : "Cloud saves: Off"}
            </DialogButton>
          )}
          <Meta
            lines={[
              `${store} · installed with NovaDeck`,
              versions ? `Boxtron runs: ${versions.choice ?? "ask every time"}` : null,
              ...cloudLines(cloud, page.store),
            ]}
          />
        </>
      );
    }
  }
}
