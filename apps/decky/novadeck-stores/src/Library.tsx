import { toaster } from "@decky/api";
import { ConfirmModal, DialogButton, Dropdown, Field, Focusable, PanelSection, PanelSectionRow, showModal } from "@decky/ui";
import { useEffect, useState } from "react";
import {
  getLibraryState,
  installTile,
  setInstallDrive,
  stopInstall,
  syncLibrary,
  uninstallGame,
} from "./backend";
import { STORE_LABELS, type Drive, type InstallItem, type LibraryState, type StoreId } from "./types";

// The rest of the panel below the accounts: what is installing, and the library's two controls.
// NOT a game browser — every owned game is already a tile in the Steam library (milestone 7 is
// library-first), and browsing in a side strip is the UX this milestone exists to avoid. What
// lives here is what the library cannot show for a shortcut: download progress, a stop and a
// resume, and an uninstall (Steam's own Uninstall does not exist for a non-Steam entry).

// Polled while the panel is open. A download moves about a percent every few seconds on Wi-Fi;
// faster than this only redraws the same number.
const POLL_MS = 2000;

const GB = 1024 ** 3;

function driveLabel(d: Drive) {
  return `${d.label} — ${(d.free / GB).toFixed(0)} GB free`;
}

function Progress({ percent }: { percent?: number }) {
  // A plain bar, not @decky/ui's ProgressBar: the same lookup-robustness rule as Field+DialogButton
  // (novadeck-control widgets.tsx) — a scraped component can silently resolve to nothing.
  const pct = Math.max(0, Math.min(100, percent ?? 0));
  return (
    <div className="novadeck-store-bar">
      <div className="novadeck-store-bar-fill" style={{ width: `${pct}%` }} />
    </div>
  );
}

function confirm(title: string, description: string, ok: string, onOK: () => void) {
  showModal(
    <ConfirmModal strTitle={title} strDescription={description} strOKButtonText={ok} bDestructiveWarning onOK={onOK} />,
  );
}

type RowProps = { item: InstallItem; onChanged: () => void };

// Every action's answer, flattened: a refusal (`error`, or `ok: false` from install_tile) and
// anything worth saying (`message`, `warning`) is toasted; a silent success just redraws the row.
type Outcome = {
  error?: string;
  ok?: boolean;
  message?: string;
  warning?: string;
  stopped?: boolean;
  uninstalled?: boolean;
};

function ActivityRow({ item, onChanged }: RowProps) {
  const [busy, setBusy] = useState(false);
  const run = async (fn: () => Promise<Outcome>) => {
    setBusy(true);
    try {
      const res = await fn();
      const body = res.error ?? res.warning ?? res.message;
      if (body) toaster.toast({ title: item.title, body });
    } catch (e) {
      toaster.toast({ title: item.title, body: String(e) });
    } finally {
      setBusy(false);
      onChanged();
    }
  };
  const store = STORE_LABELS[item.store] ?? item.store;

  if (item.state === "downloading") {
    const pct = item.percent === undefined ? "starting…" : `${item.percent.toFixed(1)}%`;
    return (
      <PanelSectionRow>
        <Field
          label={item.title}
          description={
            <>
              <span className="novadeck-store-note">{`${store} · downloading ${pct}`}</span>
              <Progress percent={item.percent} />
            </>
          }
          childrenLayout="below"
          childrenContainerWidth="max"
        >
          {/* Stop is the clean, resumable stop (KillSignal=SIGINT, installs.py): nothing is lost. */}
          <DialogButton disabled={busy} onClick={() => run(stopInstall)}>
            Stop
          </DialogButton>
        </Field>
      </PanelSectionRow>
    );
  }

  if (item.state === "interrupted") {
    const remove = () =>
      confirm(`Remove ${item.title}?`, "This deletes what has downloaded so far.", "Remove", () =>
        run(() => uninstallGame(item.store, item.id)),
      );
    return (
      <PanelSectionRow>
        <Field
          label={item.title}
          description={<span className="novadeck-store-note">{`${store} · paused`}</span>}
          childrenLayout="below"
          childrenContainerWidth="max"
        >
          {/* Two buttons in one row need a column Focusable, or the stick skips the second
              (HW-observed; see the expired-account row in Content.tsx). */}
          <Focusable className="novadeck-store-actions" flow-children="column">
            <DialogButton disabled={busy} onClick={() => run(() => installTile(item.store, item.id))}>
              Resume
            </DialogButton>
            <DialogButton disabled={busy} onClick={remove}>
              Remove
            </DialogButton>
          </Focusable>
        </Field>
      </PanelSectionRow>
    );
  }

  const uninstall = () =>
    confirm(
      `Uninstall ${item.title}?`,
      "The game's files are deleted. It stays in your library and installs again from its tile.",
      "Uninstall",
      () => run(() => uninstallGame(item.store, item.id)),
    );
  return (
    <PanelSectionRow>
      <Field
        label={item.title}
        description={<span className="novadeck-store-note">{`${store} · installed`}</span>}
        childrenLayout="below"
        childrenContainerWidth="max"
      >
        <DialogButton disabled={busy} onClick={uninstall}>
          Uninstall
        </DialogButton>
      </Field>
    </PanelSectionRow>
  );
}

// Downloads first (the reason anyone opens this), then what is paused, then what is installed.
const ORDER: Record<InstallItem["state"], number> = { downloading: 0, interrupted: 1, installed: 2 };

export function LibrarySections({ connected }: { connected: StoreId[] }) {
  const [state, setState] = useState<LibraryState | null>(null);
  const [syncing, setSyncing] = useState(false);
  const [tick, setTick] = useState(0);

  useEffect(() => {
    let live = true;
    const read = () =>
      getLibraryState()
        .then((s) => live && setState(s))
        .catch((e) => live && setState({ error: String(e) }));
    read();
    const timer = window.setInterval(read, POLL_MS);
    return () => {
      live = false;
      window.clearInterval(timer);
    };
  }, [tick]);
  const refresh = () => setTick((t) => t + 1);

  const sync = async () => {
    setSyncing(true);
    try {
      for (const store of connected) {
        const title = STORE_LABELS[store] ?? store;
        const res = await syncLibrary(store);
        if ("error" in res) {
          toaster.toast({ title, body: res.error });
          continue;
        }
        const added = res.added ? `${res.added} new` : "nothing new";
        toaster.toast({ title, body: `${res.tiles} games in the library, ${added}${res.warning ? ` (${res.warning})` : ""}` });
      }
    } catch (e) {
      toaster.toast({ title: "Library", body: String(e) });
    } finally {
      setSyncing(false);
    }
  };

  const chooseDrive = async (drive: string) => {
    const res = await setInstallDrive(drive);
    if ("error" in res) toaster.toast({ title: "Install to", body: res.error });
    refresh();
  };

  const items = state && !("error" in state) ? [...state.installs].sort((a, b) => ORDER[a.state] - ORDER[b.state]) : [];

  return (
    <>
      <PanelSection title="Library">
        <PanelSectionRow>
          <Field
            description={
              <span className="novadeck-store-note">
                Your games are in the Steam library under [NovaDeck] Epic and [NovaDeck] GOG. Press one to install it.
              </span>
            }
            childrenLayout="below"
            childrenContainerWidth="max"
          >
            <DialogButton disabled={syncing || connected.length === 0} onClick={sync}>
              {syncing ? "Syncing…" : "Sync library"}
            </DialogButton>
          </Field>
        </PanelSectionRow>
        {state && !("error" in state) && state.drives.length > 1 ? (
          // Only offered when there is a choice: with the home alone, a one-option dropdown is a
          // focus stop that can change nothing.
          <PanelSectionRow>
            <Field label="Install to" childrenLayout="below" childrenContainerWidth="max">
              <Dropdown
                selectedOption={state.install_drive}
                rgOptions={state.drives.map((d) => ({ data: d.path, label: driveLabel(d) }))}
                onChange={(o) => chooseDrive(o.data)}
              />
            </Field>
          </PanelSectionRow>
        ) : null}
      </PanelSection>
      {items.length > 0 || (state && "error" in state) ? (
        <PanelSection title="Activity">
          {state && "error" in state ? (
            <PanelSectionRow>
              <Field focusable highlightOnFocus>
                <span className="novadeck-store-note">{state.error}</span>
              </Field>
            </PanelSectionRow>
          ) : (
            items.map((item) => <ActivityRow key={`${item.store}:${item.id}`} item={item} onChanged={refresh} />)
          )}
        </PanelSection>
      ) : null}
    </>
  );
}
