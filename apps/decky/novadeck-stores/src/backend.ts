import { call } from "@decky/api";
import type { State } from "./types";

// Read-only for now: this milestone lands the panel inert, so there is nothing to mutate yet.
// Status comes from the CLIs' own credential files, which they refresh and invalidate
// themselves, so it is always re-read rather than cached across opens.
export const getStatus = () => call<[], State>("get_status");
