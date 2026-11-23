import { ConfirmModal, DialogBody, DialogButton, DialogHeader, Focusable, ModalRoot, showModal } from "@decky/ui";
import { useState } from "react";
import { allow, disconnect, remove } from "./backend";
import type { Guest, State } from "./types";

type Props = { guest: Guest; onState: (s: State) => void; closeModal?: () => void };

function GuestDialog({ guest, onState, closeModal }: Props) {
  const [busy, setBusy] = useState(false);
  const [problem, setProblem] = useState<string | null>(null);
  const name = guest.name || "Guest";

  const run = async (action: (uuid: string) => Promise<State>) => {
    setBusy(true);
    setProblem(null);
    try {
      const state = await action(guest.uuid);
      // Said here, where it happened; the panel would keep showing it after this closes.
      onState({ ...state, problem: null });
      if (!state.problem) {
        closeModal?.();
        return;
      }
      setProblem(state.problem);
    } catch {
      setProblem("The plugin did not answer");
    }
    setBusy(false);
  };

  // Behind its own question: a removed guest needs a new PIN to come back.
  const confirmRemove = () =>
    showModal(
      <ConfirmModal
        strTitle={`Remove ${name}?`}
        strDescription="They are disconnected, and need a new PIN to join again."
        strOKButtonText="Remove"
        onOK={() => void run(remove)}
      />,
    );

  return (
    <ModalRoot closeModal={closeModal} onCancel={closeModal}>
      <DialogHeader>{name}</DialogHeader>
      <DialogBody>
        <div style={{ marginBottom: "12px" }}>
          {guest.enabled
            ? "Disconnect ends their stream and unplugs their controller. They can join again without a PIN."
            : "This guest is blocked: they are paired, and cannot join."}
        </div>
        {problem && <div style={{ marginBottom: "12px" }}>{problem}</div>}
        <Focusable flow-children="column" style={{ display: "flex", flexDirection: "column", gap: "8px" }}>
          {guest.enabled ? (
            <DialogButton disabled={busy} onClick={() => void run(disconnect)}>Disconnect</DialogButton>
          ) : (
            <DialogButton disabled={busy} onClick={() => void run(allow)}>Allow</DialogButton>
          )}
          <DialogButton disabled={busy} onClick={confirmRemove}>Remove…</DialogButton>
          <DialogButton onClick={closeModal}>Close</DialogButton>
        </Focusable>
      </DialogBody>
    </ModalRoot>
  );
}

export function showGuestDialog(guest: Guest, onState: (s: State) => void) {
  showModal(<GuestDialog guest={guest} onState={onState} />);
}
