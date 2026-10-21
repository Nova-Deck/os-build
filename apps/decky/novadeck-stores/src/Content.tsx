import { toaster } from "@decky/api";
import {
  ConfirmModal,
  DialogButton,
  Field,
  Focusable,
  Navigation,
  PanelSection,
  PanelSectionRow,
  showModal,
} from "@decky/ui";
import { useEffect, useState } from "react";
import { disconnectStore, getStatus, refreshStore, startConnect } from "./backend";
import { LibrarySections } from "./Library";
import { styles } from "./styles";
import { STORE_LABELS, type State, type StoreId, type StoreStatus } from "./types";

// Read-only rows are `focusable`. The QAM is driven entirely by the gamepad and it scrolls by
// MOVING FOCUS, so a panel built only of read-only Fields has no focus targets and nothing in it
// can be reached or scrolled — HW-observed on this panel before the prop was added. A Sign in
// button is a focus target of its own, but with both stores connected there are none left, so
// the connected rows still need this. novadeck-monitor hit the same wall and its Content.tsx
// says so.
function Row({ children, label }: { children: React.ReactNode; label?: string }) {
  return (
    <PanelSectionRow>
      <Field label={label} focusable highlightOnFocus>
        {children}
      </Field>
    </PanelSectionRow>
  );
}

// The exception, and the line is "does this row ever change?". The footer below is static prose
// that says the same thing every time the panel opens, so a focus stop on it is pure friction —
// the stick lands on something that cannot be acted on and says nothing new. The transient rows
// ("Checking…", an error) stay focusable because in those states they are the panel's ONLY
// content: drop them and there is no focus target at all, which is the defect this whole
// arrangement exists to avoid.
function NoteRow({ children }: { children: React.ReactNode }) {
  return <PanelSectionRow>{children}</PanelSectionRow>;
}

// Opens the store's login in Steam's own browser. NavigateToExternalWeb and not a BrowserView we
// create: the milestone-2 spike found a view created by anyone but SteamUI's own code renders
// nowhere. The QAM is closed first so the login is not sitting underneath it. What happens after
// the user signs in is the backend's job and arrives as "connect_done" (index.tsx).
async function signIn(status: StoreStatus, setBusy: (b: boolean) => void) {
  setBusy(true);
  try {
    const res = await startConnect(status.store);
    if ("error" in res) {
      toaster.toast({ title: STORE_LABELS[status.store] ?? status.store, body: res.error });
      return;
    }
    Navigation.CloseSideMenus();
    Navigation.NavigateToExternalWeb(res.url);
  } catch (e) {
    toaster.toast({ title: STORE_LABELS[status.store] ?? status.store, body: String(e) });
  } finally {
    setBusy(false);
  }
}

// Field + DialogButton rather than ButtonItem, for the lookup-robustness reason spelled out in
// novadeck-control's components/widgets.tsx.
function SignInRow({ status }: { status: StoreStatus }) {
  const [busy, setBusy] = useState(false);
  return (
    <PanelSectionRow>
      <Field
        label={STORE_LABELS[status.store] ?? status.store}
        description="Not connected"
        childrenLayout="below"
        childrenContainerWidth="max"
      >
        <DialogButton disabled={busy} onClick={() => signIn(status, setBusy)}>
          Sign in
        </DialogButton>
      </Field>
    </PanelSectionRow>
  );
}

// Asked before anything is deleted. It is not undoable from here: getting back means the store's
// whole login again. The description says what it does NOT do as well, because "disconnect"
// reads like signing out of the store, and neither CLI can end the session with the store.
function confirmDisconnect(label: string, onConfirm: () => void) {
  showModal(
    <ConfirmModal
      strTitle={`Disconnect ${label}?`}
      strDescription="This deletes the sign-in stored on this device. It does not sign you out of the store anywhere else."
      strOKButtonText="Disconnect"
      bDestructiveWarning
      onOK={onConfirm}
    />,
  );
}

type ConnectedRowProps = {
  status: StoreStatus;
  isChecking: boolean;
  onDisconnect: (store: StoreId) => Promise<void>;
};

function ConnectedRow({ status, isChecking, onDisconnect }: ConnectedRowProps) {
  const [busy, setBusy] = useState(false);
  const label = STORE_LABELS[status.store] ?? status.store;
  // `expired` means something only once the refresh has run: then the CLI could not renew the
  // session. Whether it was the network or the store refusing, the CLIs do not say, so neither
  // does this. (A session Epic refused is deleted by legendary, and reads as not connected.)
  const isStale = !isChecking && status.expired;
  // The account name is shown when the CLI knows one and omitted when it does not, rather than
  // padded with a placeholder: "Connected" with nothing after it is honest, "Connected as
  // (unknown)" reads like a bug. A session that could not be renewed is not connected to
  // anything, so it does not say so.
  const who = status.account ? ` as ${status.account}` : "";
  const state = isStale ? "Expired" : `Connected${who}`;
  const note = isChecking
    ? "Checking the session…"
    : isStale
      ? "Could not be renewed. Check the network, or sign in again."
      : null;
  const disconnect = () =>
    confirmDisconnect(label, () => {
      setBusy(true);
      onDisconnect(status.store).finally(() => setBusy(false));
    });
  const disconnectButton = (
    <DialogButton disabled={busy} onClick={disconnect}>
      Disconnect
    </DialogButton>
  );
  // Sign in straight over the dead session: the exchange overwrites the stored one, so making the
  // user disconnect first would only add a confirm dialog on the way. The two buttons stack in a
  // column Focusable inside the store's own row: two bare buttons in one Field are not both
  // reachable (the stick jumps from the first straight to the next row, HW-observed), a row of
  // its own for Disconnect reads as belonging to no store, and side by side they do not fit the
  // QAM. The value is Steam's, not Decky's: steamui parses row/column/grid and their -reverse
  // forms, and nothing else ("horizontal", seen in Decky examples, is not one of them).
  return (
    <PanelSectionRow>
      <Field
        label={label}
        description={
          <>
            <span className="novadeck-store-state">{state}</span>
            {note ? <div className="novadeck-store-note">{note}</div> : null}
          </>
        }
        childrenLayout="below"
        childrenContainerWidth="max"
      >
        {isStale ? (
          <Focusable className="novadeck-store-actions" flow-children="column">
            <DialogButton disabled={busy} onClick={() => signIn(status, setBusy)}>
              Sign in again
            </DialogButton>
            {disconnectButton}
          </Focusable>
        ) : (
          disconnectButton
        )}
      </Field>
    </PanelSectionRow>
  );
}

function replaceStore(state: State | null, next: StoreStatus): State | null {
  if (state === null || "error" in state) {
    return state;
  }
  return { stores: state.stores.map((s) => (s.store === next.store ? next : s)) };
}

export function Content() {
  const [state, setState] = useState<State | null>(null);
  const [checking, setChecking] = useState<ReadonlySet<StoreId>>(new Set());

  // Re-read on every open, then renew each connected store through its own CLI. A token can
  // expire, or be revoked, while the panel is closed; the file alone would still say
  // "connected", so the panel asks the CLI rather than trusting it. The rows show the file's
  // answer at once and the CLI's when it arrives.
  useEffect(() => {
    let live = true;
    const settle = (store: StoreId) =>
      setChecking((prev) => new Set([...prev].filter((s) => s !== store)));
    const renew = async (store: StoreId) => {
      try {
        const res = await refreshStore(store);
        if (!live) return;
        if ("error" in res) {
          toaster.toast({ title: STORE_LABELS[store] ?? store, body: res.error });
        } else {
          setState((prev) => replaceStore(prev, res));
        }
      } catch (e) {
        if (live) toaster.toast({ title: STORE_LABELS[store] ?? store, body: String(e) });
      } finally {
        if (live) settle(store);
      }
    };
    getStatus()
      .then((s) => {
        if (!live) return;
        setState(s);
        if ("error" in s) return;
        const connected = s.stores.filter((st) => st.connected).map((st) => st.store);
        setChecking(new Set(connected));
        connected.forEach(renew);
      })
      .catch((e) => live && setState({ error: String(e) }));
    return () => {
      live = false;
    };
  }, []);

  // No `live` guard, unlike the refresh above, and on purpose: a refresh's answer only matters to
  // the open panel, but a disconnect the user asked for is news even after the QAM has closed, so
  // its toast still shows. The setState on an unmounted panel is a no-op.
  const onDisconnect = async (store: StoreId) => {
    const title = STORE_LABELS[store] ?? store;
    try {
      const res = await disconnectStore(store);
      if ("error" in res) {
        toaster.toast({ title, body: res.error });
        return;
      }
      setState((prev) => replaceStore(prev, res));
      toaster.toast({
        title,
        body: res.connected ? "Could not remove the sign-in." : "Disconnected",
      });
    } catch (e) {
      toaster.toast({ title, body: String(e) });
    }
  };

  return (
    <div className="novadeck-stores">
      <style>{styles}</style>
      <PanelSection title="Stores">
        {state === null ? (
          <Row>
            <span className="novadeck-store-note">Checking…</span>
          </Row>
        ) : "error" in state ? (
          <Row>
            <span className="novadeck-store-note">{state.error}</span>
          </Row>
        ) : (
          state.stores.map((s) =>
            s.connected ? (
              <ConnectedRow
                key={s.store}
                status={s}
                isChecking={checking.has(s.store)}
                onDisconnect={onDisconnect}
              />
            ) : (
              <SignInRow key={s.store} status={s} />
            ),
          )
        )}
        <NoteRow>
          {/* Says where the sign-in happens before the user presses it: the panel closes and a
              store page opens full-screen, which is surprising if nothing said it would. */}
          <span className="novadeck-store-note">
            Sign-in opens the store's own page in Steam's browser.
          </span>
        </NoteRow>
      </PanelSection>
      {state !== null && !("error" in state) ? (
        <LibrarySections connected={state.stores.filter((s) => s.connected).map((s) => s.store)} />
      ) : null}
    </div>
  );
}
