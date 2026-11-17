import {
  DialogBody,
  DialogBodyText,
  DialogButton,
  DialogHeader,
  Focusable,
  ModalRoot,
  showModal,
  ToggleField,
} from "@decky/ui";
import { useRef, useState } from "react";
import { answerDosPick, setDosChoice } from "./backend";

// Which DOSBox version of a GOG title to run under Boxtron (.claude/plans/boxtron-dos.plan.md,
// phase 3). Some GOG DOS games ship several complete builds behind a Windows launcher — Master of
// Magic has an Official Release and a Community Patch — and Boxtron skips that launcher, so the
// choice it made has to be made here instead. Two ways in, one list:
//
//   * AT LAUNCH (dos_pick event, index.tsx): game-launch is blocked waiting for the answer. A
//     version button answers it; Cancel or B answers "do not launch", like dismissing Steam's own
//     launch-option dialog. "Remember my choice" (off by default) saves it, and the next Play
//     goes straight in.
//   * FROM THE GAME PAGE ("DOSBox version", GamePage.tsx, shown only while the game's compat tool
//     is Boxtron): the same list plus "Ask every time", which forgets the remembered choice.

type PickProps = {
  appid: number;
  title: string;
  labels: string[];
  // Injected by showModal.
  closeModal?: () => void;
};

function DosPickModal({ appid, title, labels, closeModal }: PickProps) {
  const [remember, setRemember] = useState(false);
  // One answer per question: a button press closes the modal, and closing must not then send a
  // second answer (Cancel) behind it.
  const answered = useRef(false);
  const send = (label: string | null) => {
    if (answered.current) return;
    answered.current = true;
    void answerDosPick(appid, label, label !== null && remember);
    closeModal?.();
  };
  return (
    <ModalRoot onCancel={() => send(null)} closeModal={closeModal}>
      <DialogHeader>Which version?</DialogHeader>
      <DialogBody>
        <DialogBodyText>{title} comes in more than one version.</DialogBodyText>
        <Focusable style={{ display: "flex", flexDirection: "column", gap: "8px", margin: "12px 0" }}>
          {labels.map((label) => (
            <DialogButton key={label} onClick={() => send(label)}>
              {label}
            </DialogButton>
          ))}
          <DialogButton onClick={() => send(null)}>Cancel</DialogButton>
        </Focusable>
        <ToggleField
          label="Remember my choice"
          description="Change it later from the game page's DOSBox version button."
          checked={remember}
          onChange={setRemember}
          bottomSeparator="none"
        />
      </DialogBody>
    </ModalRoot>
  );
}

export function showDosPick(appid: number, title: string, labels: string[]) {
  showModal(<DosPickModal appid={appid} title={title} labels={labels} />);
}

type SettingProps = {
  appid: number;
  title: string;
  labels: string[];
  choice: string | null;
  onSaved: (message: string) => void;
  closeModal?: () => void;
};

const ASK = "Ask every time";

function DosVersionSettingModal({ appid, title, labels, choice, onSaved, closeModal }: SettingProps) {
  const pick = async (label: string | null) => {
    closeModal?.();
    const res = await setDosChoice(appid, label);
    onSaved("error" in res ? `Not saved: ${res.error}` : `DOSBox version: ${res.choice ?? ASK}`);
  };
  const current = choice ?? ASK;
  return (
    <ModalRoot closeModal={closeModal}>
      <DialogHeader>DOSBox version</DialogHeader>
      <DialogBody>
        <DialogBodyText>
          {`Which version of ${title} Boxtron runs.`}
        </DialogBodyText>
        <Focusable style={{ display: "flex", flexDirection: "column", gap: "8px", marginTop: "12px" }}>
          {[ASK, ...labels].map((label) => (
            <DialogButton key={label} onClick={() => pick(label === ASK ? null : label)}>
              {label === current ? `✓ ${label}` : label}
            </DialogButton>
          ))}
        </Focusable>
      </DialogBody>
    </ModalRoot>
  );
}

export function showDosVersionSetting(
  appid: number,
  title: string,
  labels: string[],
  choice: string | null,
  onSaved: (message: string) => void,
) {
  showModal(
    <DosVersionSettingModal appid={appid} title={title} labels={labels} choice={choice} onSaved={onSaved} />,
  );
}
