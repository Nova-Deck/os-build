// One entry's game-page state (main.py game_state), polled while anything shows it.
//
// Several parts of a page read the same answer: Steam's own button, the status line, the trash
// button, the gear menu, and (when the native page could not be patched) the legacy row. One poll
// per appid feeds them all, and the last good answer outlives them, so a revisit (or a gear menu
// opened later) shows it at once rather than one round trip later.

import { useEffect, useState } from "react";
import { getGameState } from "../backend";
import type { OurPage, PageState } from "../types";

const POLL_MS = 2000;

export type Snapshot = {
  // The last GOOD answer, and the latest failure, kept apart: one failed poll must not drop what
  // the page shows (Steam's Play coming back mid-install would be worse than a stale line).
  state: PageState | null;
  err: string | null;
  // Bumped by every refreshPageState: what reads besides game_state (cloud saves, DOSBox
  // versions) re-run on, so a press shows its effect everywhere on the page.
  version: number;
  // A press on this entry is being answered. Per entry, not per button: the game page's button
  // and a library surface's show the same throbber, and neither takes a second press.
  pending: boolean;
};

type Entry = {
  snap: Snapshot;
  token?: string;
  listeners: Set<() => void>;
  timer: number;
  // Bumped on every (re)start, so a read that outlives its poll cannot schedule a second one.
  generation: number;
  // Resolved when the next poll has answered (refreshPageState's promise).
  waiters: Array<() => void>;
};

const entries = new Map<number, Entry>();

function entryFor(appid: number): Entry {
  let entry = entries.get(appid);
  if (!entry) {
    entry = {
      snap: { state: null, err: null, version: 0, pending: false },
      listeners: new Set(),
      timer: 0,
      generation: 0,
      waiters: [],
    };
    entries.set(appid, entry);
  }
  return entry;
}

function same(a: Snapshot, b: Snapshot): boolean {
  return (
    a.err === b.err &&
    a.version === b.version &&
    a.pending === b.pending &&
    JSON.stringify(a.state) === JSON.stringify(b.state)
  );
}

// Only a changed snapshot is published: every part of the page re-renders on a publish, and the
// poll answers the same thing every two seconds while nothing happens.
function publish(entry: Entry, snap: Snapshot): void {
  if (same(entry.snap, snap)) return;
  entry.snap = snap;
  entry.listeners.forEach((notify) => notify());
}

function settle(entry: Entry): void {
  const waiters = entry.waiters.splice(0);
  waiters.forEach((resolve) => resolve());
}

async function poll(appid: number, entry: Entry, generation: number): Promise<void> {
  try {
    const s = await getGameState(appid, entry.token);
    if (generation !== entry.generation) return;
    if ("error" in s) {
      publish(entry, { ...entry.snap, err: s.error });
    } else {
      if (s.ours) entry.token = s.token;
      publish(entry, { ...entry.snap, state: s, err: null });
    }
  } catch (e) {
    if (generation !== entry.generation) return;
    publish(entry, { ...entry.snap, err: String(e) });
  }
  settle(entry);
  // Someone else's shortcut stays someone else's: a sync adds new appids, it never takes over an
  // existing one, so there is nothing to keep asking.
  const s = entry.snap.state;
  if (s && "ours" in s && !s.ours && entry.token === undefined) return;
  if (generation === entry.generation && entry.listeners.size > 0) {
    entry.timer = window.setTimeout(() => poll(appid, entry, generation), POLL_MS);
  }
}

function restart(appid: number, entry: Entry): void {
  window.clearTimeout(entry.timer);
  entry.generation += 1;
  void poll(appid, entry, entry.generation);
}

export function subscribe(appid: number, notify: () => void): () => void {
  const entry = entryFor(appid);
  entry.listeners.add(notify);
  if (entry.listeners.size === 1) restart(appid, entry);
  return () => {
    entry.listeners.delete(notify);
    if (entry.listeners.size === 0) {
      window.clearTimeout(entry.timer);
      entry.generation += 1;
      settle(entry);
    }
  };
}

// Read now: after a press, the page must not wait out the poll interval to show its effect.
// Resolves once that read has answered, so a press can stay "pending" until its effect shows;
// at once when nothing shows this entry (no poll runs then).
export function refreshPageState(appid: number): Promise<void> {
  const entry = entries.get(appid);
  if (!entry) return Promise.resolve();
  publish(entry, { ...entry.snap, version: entry.snap.version + 1 });
  if (entry.listeners.size === 0) return Promise.resolve();
  const done = new Promise<void>((resolve) => entry.waiters.push(resolve));
  restart(appid, entry);
  return done;
}

export function setPending(appid: number, pending: boolean): void {
  const entry = entryFor(appid);
  publish(entry, { ...entry.snap, pending });
}

// The last good answer, read synchronously (the gear menu and a button press have no time for a
// round trip).
export function cachedPage(appid: number): OurPage | null {
  return pageOf(entries.get(appid)?.snap.state ?? null);
}

export function cachedPending(appid: number): boolean {
  return entries.get(appid)?.snap.pending ?? false;
}

function pageOf(s: PageState | null): OurPage | null {
  return s && "ours" in s && s.ours ? s : null;
}

export function usePageState(appid: number): Snapshot & { page: OurPage | null } {
  // The snapshot is held WITH the appid it is for: a component React reuses for another game must
  // not show the previous game's answer for a render (or follow its "replacement" off the page).
  const [held, setHeld] = useState(() => ({ appid, snap: entryFor(appid).snap }));
  useEffect(() => {
    const entry = entryFor(appid);
    setHeld({ appid, snap: entry.snap });
    return subscribe(appid, () => setHeld({ appid, snap: entry.snap }));
  }, [appid]);
  const snap = held.appid === appid ? held.snap : entryFor(appid).snap;
  return { ...snap, page: pageOf(snap.state) };
}
