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

export type Host = { uuid: string; name: string; address: string };
export type FoundHost = Host & { joined: boolean };
// A host we made a tile for. `appid` is the tile's.
export type TileHost = { uuid: string; name: string; appid: number };
export type Hosts = { hosts: TileHost[]; problem: string | null };
export type JoinStart = { pin: string | null; problem: string | null; host?: Host };
export type JoinStatus = { state: "idle" | "waiting" | "paired" | "failed"; problem: string | null; host: Host | null };
