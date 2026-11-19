// The two destructive presses Steam's own page offers for an entry of ours: from the trash button
// beside Steam's gear (NativePage.tsx) and from the gear menu (native/gearMenu.tsx).

import { ConfirmModal, showModal } from "@decky/ui";
import { uninstallGame } from "../backend";
import type { OurPage } from "../types";
import { confirmUninstall } from "../UninstallDialog";
import { runAction } from "./pageHooks";

// A paused download: delete what has downloaded so far.
export function confirmRemove(page: OurPage): void {
  showModal(
    <ConfirmModal
      strTitle={`Remove ${page.title}?`}
      strDescription="This deletes what has downloaded so far."
      strOKButtonText="Remove"
      bDestructiveWarning
      onOK={() => void runAction(page.appid, page.title, () => uninstallGame(page.store, page.id))}
    />,
  );
}

// An installed entry: the uninstall dialog, which asks about the Proton prefix (issue #136).
export function startUninstall(page: OurPage): void {
  confirmUninstall(page.store, page.id, page.title, "this page", (dropPrefix) =>
    runAction(page.appid, page.title, () => uninstallGame(page.store, page.id, dropPrefix)),
  );
}
