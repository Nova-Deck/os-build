export type Guest = { uuid: string; name: string; enabled: boolean };
export type Pending = { id: string; address: string };

// main.py _state. `guests` and `pending` are null while Sunshine is not answering: unknown, not empty.
export type State = {
  hosting: "on" | "off" | "starting" | "stopping" | "failed" | "unknown";
  ready: boolean;
  streaming: number;
  address: string | null;
  guests: Guest[] | null;
  pending: Pending[] | null;
  problem: string | null;
};
