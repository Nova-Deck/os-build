import { DialogBody, DialogBodyText, DialogButton, DialogHeader, Focusable, ModalRoot, showModal } from "@decky/ui";
import { useRef } from "react";
import { answerSavePick, SaveChoice } from "./backend";
import { STORE_LABELS, type StoreId } from "./types";

// Which saves to keep when a GOG or Epic game's changed both on this device and in its store's cloud
// since they were last synced (.claude/plans/gog-galaxy-comet.plan.md, phase 3 step 6;
// .claude/plans/epic-cloud-saves.plan.md step 6). game-launch is
// blocked waiting for the answer (novadeck_savesync.ask), so the game has not started yet:
//
//   * the cloud's saves: the launch backs this device's save folder up first, then downloads;
//   * this device's saves: the launch uploads them, replacing the cloud's;
//   * Decide later, or B: nothing is synced and the game starts on this device's saves. The
//     question comes back on the next launch.
//
// Each choice says what it does to the other side, in plain words: one of them replaces saves.

export type SavePick = {
  appid: number;
  index: number;
  title: string;
  location: string;
  localTime: number; // Unix seconds, 0 when unknown
  cloudTime: number;
  store: StoreId; // whose cloud: the dialog names it
};

type Props = SavePick & {
  // Injected by showModal.
  closeModal?: () => void;
};

function when(seconds: number): string {
  return seconds > 0 ? new Date(seconds * 1000).toLocaleString() : "an unknown time";
}

function SavePickModal({ appid, index, title, localTime, cloudTime, store, closeModal }: Props) {
  // One answer per question: a button press closes the modal, and closing must not then send a
  // second answer (Decide later) behind it.
  const answered = useRef(false);
  const send = (choice: SaveChoice) => {
    if (answered.current) return;
    answered.current = true;
    void answerSavePick(appid, index, choice);
    closeModal?.();
  };
  return (
    <ModalRoot onCancel={() => send(null)} closeModal={closeModal}>
      <DialogHeader>Which saves?</DialogHeader>
      <DialogBody>
        <DialogBodyText>
          {title} has saves that changed both on this device and in the {STORE_LABELS[store]} cloud
          since they were last synced.
        </DialogBodyText>
        <Focusable style={{ display: "flex", flexDirection: "column", gap: "8px", margin: "12px 0" }}>
          <DialogButton onClick={() => send("cloud")}>Cloud saves, from {when(cloudTime)}</DialogButton>
          <DialogBodyText style={{ fontSize: "12px", margin: "0 0 4px" }}>
            This device's saves are backed up, then replaced.
          </DialogBodyText>
          <DialogButton onClick={() => send("local")}>This device's saves, from {when(localTime)}</DialogButton>
          <DialogBodyText style={{ fontSize: "12px", margin: "0 0 4px" }}>
            The cloud's saves are replaced.
          </DialogBodyText>
          <DialogButton onClick={() => send(null)}>Decide later</DialogButton>
          <DialogBodyText style={{ fontSize: "12px", margin: "0" }}>
            Nothing is synced now. You will be asked again next time.
          </DialogBodyText>
        </Focusable>
      </DialogBody>
    </ModalRoot>
  );
}

export function showSavePick(pick: SavePick) {
  showModal(<SavePickModal {...pick} />);
}
