import { ButtonItem, ConfirmModal, Field, PanelSection, PanelSectionRow, showModal } from "@decky/ui";
import { useState } from "react";
import { findHosts } from "./backend";
import { publishHosts, useHosts } from "./hostList";
import { showAddressDialog, showJoinDialog } from "./JoinDialog";
import { removeTile } from "./tiles";
import type { Host, TileHost } from "./types";

// Kept across remounts: the panel under a modal does not reliably stay mounted.
let lastFound: Host[] | null = null;

export function JoinSection() {
  const [found, setFound] = useState<Host[] | null>(lastFound);
  const [error, setError] = useState<string | null>(null);
  const [looking, setLooking] = useState(false);
  const hosts = useHosts(setError);

  const look = async () => {
    setLooking(true);
    setError(null);
    try {
      lastFound = (await findHosts()).found;
      setFound(lastFound);
    } catch {
      // Not "none found": the search did not happen.
      setError("The search did not run");
    }
    setLooking(false);
  };

  // Not a row's own action: the QAM is open over a running game, the stream itself included.
  const forget = (host: TileHost) =>
    showModal(
      <ConfirmModal
        strTitle={`Forget ${host.name}?`}
        strDescription="Its tile is removed from your library. The host still lists this device until its owner removes it."
        strOKButtonText="Forget"
        onOK={() => void removeTile(host).then(publishHosts).catch(() => {})}
      />,
    );

  return (
    <>
      <PanelSection title="Join">
        <PanelSectionRow>
          <ButtonItem layout="below" disabled={looking} onClick={() => void look()}>{looking ? "Looking…" : "Find hosts"}</ButtonItem>
        </PanelSectionRow>
        {found?.map((h) => (
          <PanelSectionRow key={`${h.uuid} ${h.address}`}>
            {/* Selectable even when we have it: its owner may have removed this device since. */}
            <ButtonItem layout="below" description={hosts?.hosts.some((t) => t.uuid === h.uuid) ? `${h.address}, in your library` : h.address} onClick={() => showJoinDialog(h.address, h.name || h.address)}>
              {h.name || h.address}
            </ButtonItem>
          </PanelSectionRow>
        ))}
        {found?.length === 0 && !looking && !error && (
          <PanelSectionRow><Field label="No host found" description="Hosting must be on there, on this network." /></PanelSectionRow>
        )}
        <PanelSectionRow>
          <ButtonItem layout="below" onClick={() => showAddressDialog()}>Enter an address</ButtonItem>
        </PanelSectionRow>
        {(error || hosts?.problem) && <PanelSectionRow><Field label={error ?? hosts?.problem} /></PanelSectionRow>}
      </PanelSection>
      {hosts && hosts.hosts.length > 0 && (
        <PanelSection title="Hosts in your library">
          {hosts.hosts.map((h) => (
            <PanelSectionRow key={h.uuid}>
              <ButtonItem layout="below" description="Play it from the Sunshine tab" onClick={() => forget(h)}>{`${h.name || "Host"}: forget…`}</ButtonItem>
            </PanelSectionRow>
          ))}
        </PanelSection>
      )}
    </>
  );
}
