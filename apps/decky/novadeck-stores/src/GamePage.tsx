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
  Navigation,
  playSectionClasses,
  showModal,
} from "@decky/ui";
import { Component, useEffect, useRef, useState } from "react";
import { getGameState, getInstallSize, installTile, stopInstall, uninstallGame } from "./backend";
import { STORE_LABELS, type OurPage, type PageState } from "./types";

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
const POLL_MS = 2000;
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

// The last answer per page and the size per game, kept across mounts: a revisit shows its row
// (and hides Steam's Play) at once, not one round trip later.
const lastState = new Map<number, PageState>();
const sizes = new Map<string, number | null>();

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

// Every action's answer, flattened as in Library.tsx: a refusal and anything worth saying is
// toasted, a silent success just re-reads the row.
type Outcome = {
  error?: string;
  ok?: boolean;
  message?: string;
  warning?: string;
  stopped?: boolean;
  uninstalled?: boolean;
};

function PlayRow({ appid }: { appid: number }) {
  // `state` is the last GOOD answer and `err` the latest failure, kept apart: one failed poll
  // must not drop the row and bring Steam's Play back (or re-grab focus when it recovers).
  const [state, setState] = useState<PageState | null>(lastState.get(appid) ?? null);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [tick, setTick] = useState(0);
  const token = useRef<string | undefined>(undefined);
  const movedTo = useRef<number | undefined>(undefined);
  const ref = useRef<HTMLDivElement>(null);

  useEffect(() => {
    let live = true;
    let timer = 0;
    const read = async () => {
      try {
        const s = await getGameState(appid, token.current);
        if (!live) return;
        if ("error" in s) {
          setErr(s.error);
        } else {
          setErr(null);
          if (s.ours) {
            token.current = s.token;
            // A finished install or an uninstall replaced the entry: this page's appid is gone
            // from the library, so move to the one that is there now. A push, not a replace
            // (Steam's router offers none), so Back passes the dead page once. Polling goes on,
            // so if the move never lands this row still shows the live entry's state.
            // Only once Steam has the new entry's overview: a page opened before that is sent
            // straight home (HW 2026-10-22). Until then the next poll tries again.
            const ready = !!(window as any).appStore?.GetAppOverviewByAppID?.(s.appid);
            if (s.appid !== appid && movedTo.current !== s.appid && ready) {
              movedTo.current = s.appid;
              Navigation.Navigate(`/library/app/${s.appid}`);
            }
          }
          lastState.set(appid, s);
          setState(s);
          // Someone else's shortcut stays someone else's: a sync adds new appids, it never takes
          // over an existing one, so there is nothing to keep asking.
          if (!s.ours && token.current === undefined) return;
        }
      } catch (e) {
        if (live) setErr(String(e));
      }
      if (live) timer = window.setTimeout(read, POLL_MS);
    };
    read();
    return () => {
      live = false;
      window.clearTimeout(timer);
    };
  }, [appid, tick]);

  const page = state && "ours" in state && state.ours ? state : null;
  const sizeKey = page ? page.token : "";
  const [size, setSize] = useState<number | null | undefined>(sizes.get(sizeKey));
  const wantsSize = page !== null && (page.state === "install" || page.state === "paused");
  useEffect(() => {
    if (!wantsSize || sizes.has(sizeKey)) {
      setSize(sizes.get(sizeKey));
      return;
    }
    let live = true;
    getInstallSize(page.store, page.id)
      .then((r) => {
        const v = "error" in r ? null : r.disk_size;
        if ("error" in r) sizes.delete(sizeKey);
        else sizes.set(sizeKey, v);
        if (live) setSize(v);
      })
      .catch(() => live && setSize(null));
    return () => {
      live = false;
    };
  }, [sizeKey, wantsSize]);

  const hidesPlay = page !== null && page.state !== "installed";
  useFocusOnMount(ref, hidesPlay);

  // Not ours, or not known yet: Steam's page untouched — an error on a page we never claimed is
  // none of our business.
  if (!page) return null;

  const run = async (fn: () => Promise<Outcome>) => {
    setBusy(true);
    try {
      const res = await fn();
      const body = res.error ?? res.warning ?? (res.ok === false ? `Not installed: ${res.message}` : res.message);
      if (body) toaster.toast({ title: page.title, body });
    } catch (e) {
      toaster.toast({ title: page.title, body: String(e) });
    } finally {
      setBusy(false);
      setTick((t) => t + 1);
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
      <RowBody page={page} size={size} busy={busy} run={run} />
      {err ? <span className="novadeck-play-note">{`Could not refresh: ${err}`}</span> : null}
    </Focusable>
  );
}

type BodyProps = {
  page: OurPage;
  size: number | null | undefined;
  busy: boolean;
  run: (fn: () => Promise<Outcome>) => void;
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

function RowBody({ page, size, busy, run }: BodyProps) {
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
            Install
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
            Resume
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
        confirm(
          `Uninstall ${page.title}?`,
          "The game's files are deleted. It stays in your library and installs again from this page.",
          "Uninstall",
          () => run(() => uninstallGame(page.store, page.id)),
        );
      return (
        <>
          <DialogButton className="novadeck-play-secondary" disabled={busy} onClick={uninstall}>
            Uninstall
          </DialogButton>
          <Meta lines={[`${store} · installed with NovaDeck`]} />
        </>
      );
    }
  }
}
