import { definePlugin } from "@decky/api";
import { Content } from "./Content";

export default definePlugin(() => ({
  name: "Novadeck Monitor",
  content: <Content />,
  // A pulse trace, deliberately nothing like novadeck-control's sliders glyph: the two plugins
  // sit next to each other in the QAM's plugin list and the icon is all that distinguishes them
  // there.
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
      <polyline points="22 12 18 12 15 21 9 3 6 12 2 12" />
    </svg>
  ),
  // NO alwaysRender. novadeck-control sets it because its tabs carry pending edits and a
  // running-game watcher that must survive the panel closing; this plugin is nothing but a
  // 1 Hz poll, and alwaysRender would keep that poll — a sysfs sweep plus a busctl subprocess,
  // every second — running for the whole session with the QAM shut. Unmounting on close is
  // what bounds it, the same way "only the active tab's content is mounted" bounded it while
  // this was a tab.
}));
