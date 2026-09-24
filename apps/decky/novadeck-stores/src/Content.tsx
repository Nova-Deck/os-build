import { toaster } from "@decky/api";
import { DialogButton, Field, Navigation, PanelSection, PanelSectionRow } from "@decky/ui";
import { useEffect, useState } from "react";
import { getStatus, startConnect } from "./backend";
import { styles } from "./styles";
import { STORE_LABELS, type State, type StoreStatus } from "./types";

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

function StoreRow({ status }: { status: StoreStatus }) {
  if (!status.connected) {
    return <SignInRow status={status} />;
  }
  // The account name is shown when the CLI knows one and omitted when it does not, rather than
  // padded with a placeholder: "Connected" with nothing after it is honest, "Connected as
  // (unknown)" reads like a bug.
  const state = status.account ? `Connected as ${status.account}` : "Connected";
  return (
    <Row label={STORE_LABELS[status.store] ?? status.store}>
      <span className="novadeck-store-state">{state}</span>
    </Row>
  );
}

export function Content() {
  const [state, setState] = useState<State | null>(null);

  // Re-read on every open. The CLIs refresh and invalidate these credentials themselves, and a
  // token can expire while the panel is closed, so a value cached across opens would be stale
  // exactly when it matters.
  useEffect(() => {
    let live = true;
    getStatus()
      .then((s) => live && setState(s))
      .catch((e) => live && setState({ error: String(e) }));
    return () => {
      live = false;
    };
  }, []);

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
          state.stores.map((s) => <StoreRow key={s.store} status={s} />)
        )}
        <NoteRow>
          {/* Says where the sign-in happens before the user presses it: the panel closes and a
              store page opens full-screen, which is surprising if nothing said it would. */}
          <span className="novadeck-store-note">
            Sign-in opens the store's own page in Steam's browser.
          </span>
        </NoteRow>
      </PanelSection>
    </div>
  );
}
