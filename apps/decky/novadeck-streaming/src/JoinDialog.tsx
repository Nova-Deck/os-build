import { DialogBody, DialogButton, DialogFooter, DialogHeader, Focusable, ModalRoot, TextField, showModal } from "@decky/ui";
import { useEffect, useState } from "react";
import { cancelJoin, joinStatus, startJoin } from "./backend";
import { publishHosts } from "./hostList";
import { ensureTile } from "./tiles";

const POLL_MS = 1000;

type Props = { address: string; title: string; closeModal?: () => void };

function JoinDialog({ address, title, closeModal }: Props) {
  const [pin, setPin] = useState<string | null>(null);
  const [text, setText] = useState("Asking the host…");
  const [done, setDone] = useState(false);

  useEffect(() => {
    let live = true;
    let timer = 0;
    const finish = (message: string) => {
      if (!live) return;
      setPin(null);
      setText(message);
      setDone(true);
    };
    const poll = async () => {
      let paired = false;
      try {
        const status = await joinStatus();
        if (!live) return;
        if (status.state === "waiting") {
          timer = window.setTimeout(() => void poll(), POLL_MS);
        } else if (status.state === "paired" && status.host) {
          paired = true;
          const hosts = await ensureTile(status.host);
          publishHosts(hosts);
          finish(hosts.problem ?? `Paired. ${status.host.name || status.host.address} is in your library, under Sunshine.`);
        } else {
          finish(status.problem ?? "The pairing was stopped");
        }
      } catch (e) {
        finish(paired ? `Paired, but no tile was made: ${e instanceof Error ? e.message : String(e)}` : "The plugin did not answer");
      }
    };
    void startJoin(address)
      .then((started) => {
        if (!live) {
          // Closed while the host was being asked: the cleanup below had nothing to stop yet.
          void cancelJoin();
          return;
        }
        if (started.problem || !started.pin) {
          finish(started.problem ?? "The plugin did not answer");
          return;
        }
        setPin(started.pin);
        setText(`Type this PIN on ${started.host?.name || address}, in NovaDeck Streaming or on its Sunshine page.`);
        void poll();
      })
      .catch(() => finish("The plugin did not answer"));
    // Closing the dialog ends the attempt: Moonlight would otherwise wait on, unseen.
    return () => {
      live = false;
      window.clearTimeout(timer);
      void cancelJoin();
    };
  }, []);

  return (
    <ModalRoot closeModal={closeModal} onCancel={closeModal}>
      <DialogHeader>Join {title}</DialogHeader>
      <DialogBody>
        {pin && <div style={{ fontSize: "48px", letterSpacing: "12px", textAlign: "center", margin: "16px 0" }}>{pin}</div>}
        <div>{text}</div>
      </DialogBody>
      <DialogFooter>
        <DialogButton onClick={closeModal}>{done ? "Close" : "Cancel"}</DialogButton>
      </DialogFooter>
    </ModalRoot>
  );
}

function AddressDialog({ closeModal }: { closeModal?: () => void }) {
  const [address, setAddress] = useState("");
  const join = () => {
    closeModal?.();
    showJoinDialog(address.trim(), address.trim());
  };
  return (
    <ModalRoot closeModal={closeModal} onCancel={closeModal}>
      <DialogHeader>Join by address</DialogHeader>
      <DialogBody>
        <TextField label="Address of the host" description="Its NovaDeck Streaming panel shows it" value={address} onChange={(e) => setAddress(e.target.value)} />
      </DialogBody>
      <DialogFooter>
        <Focusable flow-children="row" style={{ display: "flex", gap: "8px" }}>
          <DialogButton disabled={!address.trim()} onClick={join}>Join</DialogButton>
          <DialogButton onClick={closeModal}>Cancel</DialogButton>
        </Focusable>
      </DialogFooter>
    </ModalRoot>
  );
}

export function showJoinDialog(address: string, title: string) {
  showModal(<JoinDialog address={address} title={title} />);
}

export function showAddressDialog() {
  showModal(<AddressDialog />);
}
