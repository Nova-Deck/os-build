import { ConfirmModal, showModal, ToggleField } from "@decky/ui";
import { useState } from "react";
import { getPrefixStatus } from "./backend";
import type { PrefixStatus, StoreId } from "./types";

// The Uninstall confirmation, shared by the game page and the QAM row (issue #136). An uninstall
// removes the game's files and keeps its Proton prefix — saves and settings — as Steam does for
// every shortcut. The dialog says whether that prefix is there and how big it is, and a toggle,
// off by default, deletes it too. The status is asked before the dialog opens so what it says is
// what is on disk, not a guess.

const MB = 1024 ** 2;
const GB = 1024 ** 3;

function size(bytes: number) {
  return bytes >= GB ? `${(bytes / GB).toFixed(1)} GB` : `${Math.max(1, Math.round(bytes / MB))} MB`;
}

type Props = {
  title: string;
  // Where the game installs again from: "this page" or "its tile".
  where: string;
  prefix: PrefixStatus;
  onConfirm: (dropPrefix: boolean) => void;
  // Injected by showModal; ConfirmModal closes itself through it.
  closeModal?: () => void;
};

function UninstallModal({ title, where, prefix, onConfirm, closeModal }: Props) {
  const [drop, setDrop] = useState(false);
  const has = "exists" in prefix && prefix.exists;
  const note =
    "error" in prefix
      ? `Its Proton prefix could not be checked: ${prefix.error}.`
      : has
        ? null
        : "It has no Proton prefix on disk.";
  return (
    <ConfirmModal
      strTitle={`Uninstall ${title}?`}
      strDescription={`The game's files are deleted. It stays in your library and installs again from ${where}.${note ? ` ${note}` : ""}`}
      strOKButtonText="Uninstall"
      bDestructiveWarning
      closeModal={closeModal}
      onOK={() => onConfirm(has && drop)}
    >
      {has && (
        <ToggleField
          label="Also delete its Proton prefix"
          description={`Saves and settings live there · ${size(prefix.bytes)}`}
          checked={drop}
          onChange={setDrop}
          bottomSeparator="none"
        />
      )}
    </ConfirmModal>
  );
}

// The status read walks the prefix (du over a few hundred MB on a card), so the dialog opens a
// beat after the press. One at a time: a second press while the first is still reading would
// otherwise stack two dialogs for the same game.
let opening = false;

export async function confirmUninstall(
  store: StoreId,
  id: string,
  title: string,
  where: string,
  onConfirm: (dropPrefix: boolean) => void,
) {
  if (opening) return;
  opening = true;
  try {
    const prefix = await getPrefixStatus(store, id);
    showModal(<UninstallModal title={title} where={where} prefix={prefix} onConfirm={onConfirm} />);
  } finally {
    opening = false;
  }
}
