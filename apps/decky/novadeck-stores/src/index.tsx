import { addEventListener, definePlugin, removeEventListener, toaster } from "@decky/api";
import { Navigation } from "@decky/ui";
import { Content } from "./Content";
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

export default definePlugin(() => {
  addEventListener("connect_done", onConnectDone);
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
    },
    // NO alwaysRender: this panel holds no pending edits and nothing to keep warm. It re-reads on
    // every open by design, because a token can expire while it is closed — and that re-read is
    // also what shows a fresh sign-in as connected.
  };
});
