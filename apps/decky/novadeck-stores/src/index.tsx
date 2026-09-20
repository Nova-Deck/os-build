import { definePlugin } from "@decky/api";
import { Content } from "./Content";

export default definePlugin(() => ({
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
  // NO alwaysRender: this panel holds no pending edits and nothing to keep warm. It re-reads on
  // every open by design, because a token can expire while it is closed.
}));
