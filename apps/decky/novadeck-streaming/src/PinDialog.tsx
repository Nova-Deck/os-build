import { DialogButton, DialogBody, DialogFooter, DialogHeader, Focusable, ModalRoot, TextField, showModal } from "@decky/ui";
import { useState } from "react";
import { pair } from "./backend";
import type { Pending, State } from "./types";

const PIN_LENGTH = 4;

type Props = { pending: Pending; onState: (s: State) => void; closeModal?: () => void };

function PinDialog({ pending, onState, closeModal }: Props) {
  const [pin, setPin] = useState("");
  const [name, setName] = useState("");
  const [busy, setBusy] = useState(false);
  const [problem, setProblem] = useState<string | null>(null);

  // Answers once the pairing has finished (up to ten seconds), so "paired" here means paired.
  const submit = async () => {
    setBusy(true);
    setProblem(null);
    try {
      // Closes whatever the answer: this pairing is spent, and a guest who tries again shows up in
      // the panel as a new one. The panel says what went wrong.
      onState(await pair(pending.id, pin, name));
      closeModal?.();
      return;
    } catch {
      setProblem("The plugin did not answer");
    }
    setBusy(false);
  };

  return (
    <ModalRoot closeModal={closeModal} onCancel={closeModal}>
      <DialogHeader>Pair a guest</DialogHeader>
      <DialogBody>
        <div style={{ marginBottom: "12px" }}>
          {/* By address, which Sunshine measured: every Moonlight sends the same device name. */}
          A device at <b>{pending.address || "an unknown address"}</b> asks to join. Type the PIN its Moonlight shows,
          only if you know who it is. A paired guest controls this device like a second controller, Steam&apos;s menus included.
        </div>
        <TextField
          label="PIN"
          value={pin}
          mustBeNumeric
          disabled={busy}
          onChange={(e) => setPin(e.target.value.replace(/[^0-9]/g, "").slice(0, PIN_LENGTH))}
        />
        <TextField label="Name for this guest" value={name} disabled={busy} onChange={(e) => setName(e.target.value)} />
        {problem && <div style={{ marginTop: "12px" }}>{problem}</div>}
      </DialogBody>
      <DialogFooter>
        <Focusable flow-children="row" style={{ display: "flex", gap: "8px" }}>
          <DialogButton disabled={busy || pin.length !== PIN_LENGTH} onClick={() => void submit()}>
            {busy ? "Pairing…" : "Pair"}
          </DialogButton>
          <DialogButton onClick={closeModal}>Cancel</DialogButton>
        </Focusable>
      </DialogFooter>
    </ModalRoot>
  );
}

export function showPinDialog(pending: Pending, onState: (s: State) => void) {
  showModal(<PinDialog pending={pending} onState={onState} />);
}
