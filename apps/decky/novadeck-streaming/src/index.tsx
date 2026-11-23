import { definePlugin } from "@decky/api";
import { Content } from "./Content";

export default definePlugin(() => ({
  name: "NovaDeck Streaming",
  content: <Content />,
  // Two pads sharing one signal. The icon is the only thing telling the first-party plugins apart in
  // the QAM's plugin list.
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
      <rect x="1.5" y="13" width="9" height="7" rx="3" />
      <rect x="13.5" y="13" width="9" height="7" rx="3" />
      <path d="M8 8.5a5.6 5.6 0 0 1 8 0" />
      <path d="M5 5a10 10 0 0 1 14 0" />
    </svg>
  ),
  // NO alwaysRender: nothing here needs to outlive the panel. Sunshine is the record of who is
  // paired, and the panel reads it again each time it opens.
}));
