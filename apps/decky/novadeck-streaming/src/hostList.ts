import { useEffect, useState } from "react";
import { getHosts } from "./backend";
import type { Hosts } from "./types";

// The hosts in the library, kept outside any panel. Closing a dialog remounts the panel under it, so the
// panel that opened a Forget or a join is gone by the time its answer comes, and the new one has
// already asked: its answer can be the list from before. Every mounted panel follows this list.
let current: Hosts | null = null;
let changes = 0;
const listeners = new Set<(hosts: Hosts) => void>();

export function publishHosts(next: Hosts): void {
  current = next;
  changes += 1;
  listeners.forEach((l) => l(next));
}

export function useHosts(onError: (problem: string) => void): Hosts | null {
  const [hosts, show] = useState<Hosts | null>(current);
  useEffect(() => {
    let live = true;
    listeners.add(show);
    const asked = changes;
    getHosts()
      .then((answer) => asked === changes && publishHosts(answer)) // older than a change: not news
      .catch(() => live && onError("The plugin did not answer"));
    return () => {
      live = false;
      listeners.delete(show);
    };
  }, []);
  return hosts;
}
