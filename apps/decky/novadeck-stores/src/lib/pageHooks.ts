// What a game page reads besides its state, and how a press reports back. Shared by Steam's own
// page (NativePage.tsx) and the legacy row (GamePage.tsx).

import { toaster } from "@decky/api";
import { Navigation } from "@decky/ui";
import { useEffect, useRef, useState } from "react";
import { getCloudSaves, getDosVersions, getInstallSize } from "../backend";
import type { CloudSaves, DosVersions, OurPage } from "../types";
import { refreshPageState } from "./pageState";

const CLOUD_POLL_MS = 10000;

// The internal compat_tools name packages/boxtron installs (its PKGBUILD asserts it).
const BOXTRON_TOOL = "boxtron";

// Last answers per appid, for the gear menu: it renders synchronously, with no time to ask.
export const latestDos = new Map<number, DosVersions | null>();
export const latestCloud = new Map<number, CloudSaves | null>();
export const latestOnBoxtron = new Map<number, boolean>();

const sizes = new Map<string, number | null>();

// The size last read for an entry (by its page token), for a press decided outside React.
export function cachedSize(token: string): number | null | undefined {
  return sizes.get(token);
}

// Install size of a not-installed entry: undefined while unknown, null when the store would not
// say. Asked once per entry (`token`), cached across mounts.
export function useInstallSize(page: OurPage | null): number | null | undefined {
  const key = page ? page.token : "";
  const wanted = page !== null && (page.state === "install" || page.state === "paused");
  const [size, setSize] = useState<number | null | undefined>(sizes.get(key));
  useEffect(() => {
    if (!page || !wanted || sizes.has(key)) {
      setSize(sizes.get(key));
      return;
    }
    let live = true;
    getInstallSize(page.store, page.id)
      .then((r) => {
        const v = "error" in r ? null : r.disk_size;
        if ("error" in r) sizes.delete(key);
        else sizes.set(key, v);
        if (live) setSize(v);
      })
      .catch(() => live && setSize(null));
    return () => {
      live = false;
    };
  }, [key, wanted]);
  return size;
}

function compatToolOf(appid: number): string {
  try {
    const details: any = (window as any).appDetailsStore?.GetAppDetails?.(appid);
    return String(details?.strCompatToolName || "");
  } catch (error) {
    return "";
  }
}

// Whether the entry's compat tool IS Boxtron: the DOSBox version setting does nothing under Proton.
// SUBSCRIBED to, not polled: appDetailsStore's copy only refreshes while some page holds a details
// subscription (HW 2026-11-17, Pocket FIT), and RegisterForAppDetails pushes the change itself.
export function useOnBoxtron(appid: number, installed: boolean): boolean {
  const [on, setOn] = useState(() => compatToolOf(appid) === BOXTRON_TOOL);
  useEffect(() => {
    if (!installed) return;
    const set = (v: boolean) => {
      latestOnBoxtron.set(appid, v);
      setOn(v);
    };
    set(compatToolOf(appid) === BOXTRON_TOOL);
    let sub: { unregister?: () => void } | undefined;
    try {
      sub = (window as any).SteamClient?.Apps?.RegisterForAppDetails?.(appid, (details: any) =>
        set(String(details?.strCompatToolName || "") === BOXTRON_TOOL),
      );
    } catch (error) {
      sub = undefined;
    }
    return () => sub?.unregister?.();
  }, [appid, installed]);
  return on;
}

// The DOSBox versions of an installed GOG DOS title, read once per install state and per refresh.
export function useDosVersions(appid: number, installed: boolean, version: number): DosVersions | null {
  const [dos, setDos] = useState<DosVersions | null>(null);
  useEffect(() => {
    if (!installed) {
      setDos(null);
      return;
    }
    let live = true;
    const set = (v: DosVersions | null) => {
      latestDos.set(appid, v);
      if (live) setDos(v);
    };
    getDosVersions(appid).then(set, () => set(null));
    return () => {
      live = false;
    };
  }, [appid, installed, version]);
  return dos;
}

// An installed GOG game's cloud saves, read per install state, per refresh, and every
// CLOUD_POLL_MS: the upload after a game exits lands seconds after the page is back.
export function useCloudSaves(appid: number, installed: boolean, version: number): CloudSaves | null {
  const [cloud, setCloud] = useState<CloudSaves | null>(null);
  useEffect(() => {
    if (!installed) {
      setCloud(null);
      return;
    }
    let live = true;
    const read = () =>
      getCloudSaves(appid).then(
        (c) => {
          latestCloud.set(appid, c);
          if (live) setCloud(c);
        },
        () => live && setCloud(null),
      );
    read();
    const timer = window.setInterval(read, CLOUD_POLL_MS);
    return () => {
      live = false;
      window.clearInterval(timer);
    };
  }, [appid, installed, version]);
  return cloud;
}

const NO_CLOUD: Record<"no-client" | "unknown" | "unsupported", string> = {
  "no-client": "No cloud saves: this install names no GOG Galaxy client",
  unknown: "Cloud saves: not known yet (GOG could not be reached; checked again at the next library sync)",
  unsupported: "No cloud saves for this game on GOG",
};

// The cloud-saves words: the switch's state, the last sync, and what the last sync could not do
// (cloud_saves.py words it). Empty when there is nothing to say.
export function cloudLines(cloud: CloudSaves | null): string[] {
  if (!cloud || cloud.state === "none") return [];
  if (cloud.state === "unavailable") return [NO_CLOUD[cloud.why]];
  if (cloud.state === "off") return ["Cloud saves: off, saves stay on this device", ...cloud.notes];
  const last = cloud.lastSync ? `last synced ${new Date(cloud.lastSync * 1000).toLocaleString()}` : "not synced yet";
  return [`Cloud saves: on, ${last}`, ...cloud.notes];
}

// Every action's answer, flattened: a refusal and anything worth saying is toasted, a silent
// success just re-reads the page.
export type Outcome = {
  error?: string;
  ok?: boolean;
  message?: string;
  warning?: string;
  stopped?: boolean;
  uninstalled?: boolean;
};

// Resolves once the page's state has been re-read after the action, so whatever shows the press as
// pending keeps doing so until its effect is on screen (no flash of the old button in between).
export async function runAction(appid: number, title: string, fn: () => Promise<Outcome>): Promise<void> {
  try {
    const res = await fn();
    const body = res.error ?? res.warning ?? (res.ok === false ? `Not installed: ${res.message}` : res.message);
    if (body) toaster.toast({ title, body });
  } catch (e) {
    toaster.toast({ title, body: String(e) });
  } finally {
    await refreshPageState(appid);
  }
}

// The entry's live appid is not this page's: only an entry an earlier build REPLACED (remove +
// re-add); the install transitions now edit in place. Move to the one that is there now — a push,
// Steam's router has no replace — and only once Steam has its overview: a page opened before that
// is sent straight home (HW 2026-10-22). Until then the next poll tries again.
export function useFollowReplacement(appid: number, page: OurPage | null): void {
  const movedTo = useRef<number | undefined>(undefined);
  useEffect(() => {
    if (!page || page.appid === appid || movedTo.current === page.appid) return;
    if (!(window as any).appStore?.GetAppOverviewByAppID?.(page.appid)) return;
    movedTo.current = page.appid;
    Navigation.Navigate(`/library/app/${page.appid}`);
  }, [appid, page]);
}
