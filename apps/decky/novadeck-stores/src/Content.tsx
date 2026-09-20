import { Field, PanelSection, PanelSectionRow } from "@decky/ui";
import { useEffect, useState } from "react";
import { getStatus } from "./backend";
import { styles } from "./styles";
import type { State, StoreStatus } from "./types";

const STORE_LABELS: Record<string, string> = {
  epic: "Epic Games",
  gog: "GOG",
};

// EVERY row here is `focusable`, and none of them is interactive. The QAM is driven entirely by
// the gamepad and it scrolls by MOVING FOCUS, so a panel built only of read-only Fields has no
// focus targets and nothing in it can be reached or scrolled — HW-observed on this panel before
// the prop was added. novadeck-monitor hit the same wall and its Content.tsx says so; this panel
// is the worse case it warns about, since it has no slider or dropdown anywhere to fall back on.
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

function StoreRow({ status }: { status: StoreStatus }) {
  const label = STORE_LABELS[status.store] ?? status.store;
  // The account name is shown when the CLI knows one and omitted when it does not, rather than
  // padded with a placeholder: "Connected" with nothing after it is honest, "Connected as
  // (unknown)" reads like a bug.
  const state = status.connected
    ? status.account
      ? `Connected as ${status.account}`
      : "Connected"
    : "Not connected";
  return (
    <Row label={label}>
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
          {/* Says what the panel cannot do yet, because a surface that only reports looks broken
              otherwise — the user's next question is "so where is the sign-in button". */}
          <span className="novadeck-store-note">
            Signing in from the device arrives in a later update.
          </span>
        </NoteRow>
      </PanelSection>
    </div>
  );
}
