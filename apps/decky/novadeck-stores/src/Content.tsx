import { Field, PanelSection, PanelSectionRow } from "@decky/ui";
import { useEffect, useState } from "react";
import { getStatus } from "./backend";
import { styles } from "./styles";
import type { State, StoreStatus } from "./types";

const STORE_LABELS: Record<string, string> = {
  epic: "Epic Games",
  gog: "GOG",
};

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
    <PanelSectionRow>
      <Field label={label}>
        <span className="novadeck-store-state">{state}</span>
      </Field>
    </PanelSectionRow>
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
          <PanelSectionRow>
            <span className="novadeck-store-note">Checking…</span>
          </PanelSectionRow>
        ) : "error" in state ? (
          <PanelSectionRow>
            <span className="novadeck-store-note">{state.error}</span>
          </PanelSectionRow>
        ) : (
          state.stores.map((s) => <StoreRow key={s.store} status={s} />)
        )}
        <PanelSectionRow>
          {/* Says what the panel cannot do yet, because a surface that only reports looks broken
              otherwise — the user's next question is "so where is the sign-in button". */}
          <span className="novadeck-store-note">
            Signing in from the device arrives in a later update.
          </span>
        </PanelSectionRow>
      </PanelSection>
    </div>
  );
}
