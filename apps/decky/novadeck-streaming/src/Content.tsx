import { ButtonItem, ConfirmModal, Field, PanelSection, PanelSectionRow, ToggleField, showModal } from "@decky/ui";
import { useCallback, useEffect, useRef, useState } from "react";
import { getState, setHosting } from "./backend";
import { showGuestDialog } from "./GuestDialog";
import { JoinSection } from "./JoinSection";
import { showPinDialog } from "./PinDialog";
import type { State } from "./types";

// A guest asking to pair shows up here by itself: the panel re-reads while it is open.
const POLL_MS = 2000;

// Kept across remounts: the panel under a modal does not reliably stay mounted.
let lastState: State | null = null;

const HOSTING: Record<State["hosting"], string> = {
  on: "Friends can join with Moonlight. Any device on this network can ask to join; you let it in with its PIN",
  off: "Off. It never starts by itself",
  starting: "Starting…",
  stopping: "Stopping…",
  failed: "Sunshine stopped with an error",
  unknown: "The host service did not report its state",
};

export function Content() {
  const [state, setState] = useState<State | null>(lastState);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // A poll that left before a change must not put the old state back.
  const generation = useRef(0);

  const keep = useCallback((next: State) => {
    generation.current += 1;
    lastState = next;
    setState(next);
  }, []);

  useEffect(() => {
    let live = true;
    let timer = 0;
    // What went wrong last time the panel was open is not news now.
    if (lastState?.problem) {
      lastState = { ...lastState, problem: null };
      setState(lastState);
    }
    const poll = async () => {
      const started = generation.current;
      try {
        const next = await getState();
        // A change's `problem` stays until the host moves on (a stop that was slow, not refused).
        if (live && started === generation.current) {
          lastState = { ...next, problem: lastState?.hosting === next.hosting ? lastState.problem : null };
          setState(lastState);
        }
        if (live) setError(null);
      } catch {
        if (live) setError("The plugin did not answer");
      }
      // The next one only now: a slow answer must never land after a newer one.
      if (live) timer = window.setTimeout(() => void poll(), POLL_MS);
    };
    void poll();
    return () => {
      live = false;
      window.clearTimeout(timer);
    };
  }, []);

  const apply = async (on: boolean) => {
    setBusy(true);
    try {
      keep(await setHosting(on));
    } catch {
      setError("The plugin did not answer");
    }
    setBusy(false);
  };

  const onToggle = (on: boolean) => {
    const streaming = state?.streaming ?? 0;
    if (on || streaming === 0) {
      void apply(on);
      return;
    }
    showModal(
      <ConfirmModal
        strTitle="Stop hosting?"
        strDescription={`${streaming === 1 ? "One guest is" : `${streaming} guests are`} streaming and will be disconnected.`}
        strOKButtonText="Stop hosting"
        onOK={() => void apply(false)}
      />,
    );
  };

  if (!state) {
    return (
      <PanelSection>
        <PanelSectionRow><Field label={error ?? "Loading…"} /></PanelSectionRow>
      </PanelSection>
    );
  }

  const on = state.hosting === "on";
  const changing = busy || state.hosting === "starting" || state.hosting === "stopping";

  return (
    <>
      <PanelSection title="Host">
        <PanelSectionRow>
          <ToggleField label="Let friends join" description={HOSTING[state.hosting]} checked={on || state.hosting === "starting"} disabled={changing} onChange={onToggle} />
        </PanelSectionRow>
        {(state.problem || error) && (
          <PanelSectionRow><Field label={state.problem ?? error} /></PanelSectionRow>
        )}
        {on && (
          <PanelSectionRow>
            <Field
              label={state.streaming === 0 ? "Nobody is streaming" : state.streaming === 1 ? "1 guest is streaming" : `${state.streaming} guests are streaming`}
              description="Guests control this device like a second controller, Steam's menus included: they can run programs on it."
            />
          </PanelSectionRow>
        )}
      </PanelSection>

      {on && !state.ready && (
        <PanelSection><PanelSectionRow><Field label="Sunshine is not answering yet" /></PanelSectionRow></PanelSection>
      )}

      {on && state.pending && (
        <PanelSection title="New guest">
          {state.pending.map((p) => (
            <PanelSectionRow key={p.id}>
              <ButtonItem layout="below" onClick={() => showPinDialog(p, keep)}>
                Enter the PIN of {p.address || "a guest"}
              </ButtonItem>
            </PanelSectionRow>
          ))}
          {state.pending.length === 0 && (
            <PanelSectionRow>
              <Field
                label="Nobody is asking to join"
                description={state.address ? `In Moonlight, add ${state.address} and select it. The PIN it shows is typed here.` : "This device has no network address."}
              />
            </PanelSectionRow>
          )}
        </PanelSection>
      )}

      {on && state.guests && state.guests.length > 0 && (
        <PanelSection title="Paired guests">
          {state.guests.map((g) => (
            <PanelSectionRow key={g.uuid}>
              <ButtonItem layout="below" description={g.enabled ? undefined : "Blocked"} onClick={() => showGuestDialog(g, keep)}>
                {g.name || "Guest"}
              </ButtonItem>
            </PanelSectionRow>
          ))}
        </PanelSection>
      )}

      <JoinSection />
    </>
  );
}
