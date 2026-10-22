import { addEventListener, call, definePlugin, removeEventListener, toaster } from "@decky/api";
import { Navigation } from "@decky/ui";
import { Content } from "./Content";
import { applyGamePagePatch } from "./GamePage";
import { applyLibraryTabsPatch, refreshLibraryTabs, scheduleLibraryTabsRefresh } from "./LibraryTabs";
import { executeShortcutOp, ShortcutOp } from "./lib/shortcutBridge";
import { STORE_LABELS } from "./types";

// The end of a sign-in, emitted by the backend's background task (main.py _connect_flow).
// Registered HERE and not in the panel: while the login page is on screen the QAM is closed and
// Content is unmounted, so a listener inside it would never hear the result.
//
// `close` says whether the login page is still showing. It is true once the redirect was
// captured — the browser is sitting on the store's redirect page — and false on a timeout, when
// the user left long ago and leaving now would pull them out of whatever they are doing.
//
// Home, not Back. The external-web route spends Back on the PAGE's history first, and a store
// login is a chain of redirects, so on hardware a Back after Epic's redirect left the login on
// screen. Navigating to a route leaves the browser outright, and ends every sign-in in one place.
const HOME_ROUTE = "/library/home";

function onConnectDone(store: string, connected: boolean, close: boolean, message: string) {
  if (close) {
    Navigation.Navigate(HOME_ROUTE);
  }
  toaster.toast({
    title: STORE_LABELS[store] ?? store,
    body: connected ? message : `${message}. Try signing in again.`,
  });
}

// Library-entry operations the backend asks Steam for (main.py register/deregister_entry).
// Registered HERE for the same reason connect_done is: the backend can ask while the panel is
// unmounted, and milestone 4 has no panel at all — the gate drives the backend directly.
function onShortcutOp(op: ShortcutOp) {
  // Every add, remove and swap changes what the Epic / GOG tabs list (LibraryTabs.tsx).
  void executeShortcutOp(op).then(scheduleLibraryTabsRefresh);
}

// The outcome of pressing Play on a not-installed tile (main.py take_install_requests). The stub
// Steam ran has already exited and Steam shows nothing for a shortcut, so without this toast the
// press would look like it did nothing.
type InstallEvent = { store: string; id: string; title: string; ok: boolean; message: string };

function onInstallEvent(ev: InstallEvent) {
  toaster.toast({
    title: ev.title,
    body: ev.ok ? ev.message : `Not installed: ${ev.message}`,
  });
}

export default definePlugin(() => {
  addEventListener("connect_done", onConnectDone);
  addEventListener("shortcut_op", onShortcutOp);
  addEventListener("install_event", onInstallEvent);
  // Now that shortcut_op has a listener, the backend may ask Steam for things: it re-asserts the
  // compat tools here, not at its own boot, when nothing would have answered (main.py).
  void call("frontend_ready");
  // Revision 2: Install / progress / Uninstall on Steam's own game page (GamePage.tsx).
  const removeGamePagePatch = applyGamePagePatch();
  // R2: Epic / GOG tabs in Steam's library.
  const removeLibraryTabsPatch = applyLibraryTabsPatch();
  void refreshLibraryTabs();
  return {
    name: "NovaDeck Stores",
    content: <Content />,
    // A storefront awning. Deliberately unlike the other three in the QAM's plugin list --
    // novadeck-control's sliders, novadeck-monitor's pulse trace, novadeck-framegen's stacked
    // frames -- since the icon is the only thing telling them apart there.
    icon: (
      <svg
        xmlns="http://www.w3.org/2000/svg"
        width="24"
        height="24"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        strokeWidth="2"
        strokeLinecap="round"
        strokeLinejoin="round"
      >
        <path d="M3 9h18l-1.5-4.5h-15L3 9Z" />
        <path d="M4.5 9v10.5h15V9" />
        <path d="M9.75 19.5V13.5h4.5v6" />
      </svg>
    ),
    onDismount() {
      removeEventListener("connect_done", onConnectDone);
      removeEventListener("shortcut_op", onShortcutOp);
      removeEventListener("install_event", onInstallEvent);
      removeGamePagePatch();
      removeLibraryTabsPatch();
    },
    // NO alwaysRender: this panel holds no pending edits and nothing to keep warm. It re-reads on
    // every open by design, because a token can expire while it is closed — and that re-read is
    // also what shows a fresh sign-in as connected.
  };
});
