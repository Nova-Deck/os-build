import { definePlugin } from "@decky/api";
import { Content } from "./Content";

export default definePlugin(() => ({
  name: "Novadeck Frame Gen",
  content: <Content />,
  // Three stacked frames with the middle one dashed: the inserted frame. Deliberately unlike
  // novadeck-control's sliders and novadeck-monitor's pulse trace -- all three sit together in
  // the QAM's plugin list and the icon is the only thing telling them apart there.
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
      <rect x="2" y="5" width="9" height="14" rx="1" />
      <rect x="13" y="5" width="9" height="14" rx="1" strokeDasharray="3 2" />
    </svg>
  ),
  // NO alwaysRender, matching novadeck-monitor. This panel holds no pending edits -- every
  // change is written through on the spot and the backend hands back the whole new state -- so
  // there is nothing that needs to survive the QAM closing, and keeping it mounted would only
  // hold a Steam-library read in memory for the whole session.
}));
