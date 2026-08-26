import { Field, PanelSection, Tabs } from "@decky/ui";
import { useCallback, useEffect, useRef, useState } from "react";
import type { ReactNode } from "react";
import { getConfig, getInstalledGames } from "./backend";
import { useDebouncedTweaksSave } from "./hooks/useDebouncedSave";
import { currentGame } from "./lib/games";
import { styles } from "./styles";
import { Games } from "./tabs/Games";
import { Monitor } from "./tabs/Monitor";
import { Power } from "./tabs/Power";
import type { Config } from "./types";

export function Content() {
  const [tab, setTab] = useState("Games");
  const [config, setConfig] = useState<Config | null>(null);
  const [message, setMessage] = useState("Loading");
  const savedTweaksSnapshot = useRef("");
  const installedGamesRequested = useRef(false);

  const load = useCallback(async () => {
    try {
      const next = await getConfig();
      next.game = currentGame();
      savedTweaksSnapshot.current = JSON.stringify(next.tweaks);
      setConfig((current) => ({ ...next, installedGames: current?.installedGames || [] }));
    } catch (error) {
      setMessage(String(error));
    }
  }, []);
  useEffect(() => {
    load();
  }, [load]);

  // The library scan reads every appmanifest on disk — request it once, after first paint.
  useEffect(() => {
    if (!config || installedGamesRequested.current) return;
    installedGamesRequested.current = true;
    let cancelled = false;
    getInstalledGames()
      .then((installedGames) => {
        if (cancelled) return;
        setConfig((current) => (current ? { ...current, installedGames } : current));
      })
      .catch(() => {});
    return () => {
      cancelled = true;
    };
  }, [!!config]);

  // Track the running game so the Games tab can default its edit target to it.
  useEffect(() => {
    if (!config) return;
    const refresh = () => {
      const runtimeGame = currentGame();
      setConfig((current) => {
        if (!current) return current;
        if ((current.game?.appid || "") === (runtimeGame?.appid || "")) return current;
        return { ...current, game: runtimeGame };
      });
    };
    const timer = window.setInterval(refresh, 2000);
    refresh();
    return () => window.clearInterval(timer);
  }, [!!config]);

  useDebouncedTweaksSave({ config, snapshot: savedTweaksSnapshot, setConfig, onError: load });

  if (!config) return <PanelSection title="Novadeck Control"><Field label={message} /></PanelSection>;
  // The version line lives at the end of the SCROLLABLE tab content, not as a sibling of
  // <Tabs>: the tab strip fills the container's height, so anything after it lands on the
  // container's bottom edge and is eaten by overflow:hidden (HW-observed 2026-08-09 — the row
  // was in the DOM, at y=482 against a 482 bottom, invisible on every tab).
  const tabContent = (content: ReactNode) => (
    <div className="novadeck-control-tab-content">
      {content}
      <div className="novadeck-version-row">novadeck {config.osVersion}</div>
    </div>
  );
  return (
    <div className="novadeck-control-tabs">
      <style>{styles}</style>
      <Tabs
        activeTab={tab}
        onShowTab={setTab}
        tabs={[
          { id: "Games", title: "Games", content: tabContent(<Games config={config} setConfig={setConfig} />) },
          { id: "Power", title: "Power", content: tabContent(<Power config={config} setConfig={setConfig} />) },
          // Only the active tab's content is mounted, so the 1 Hz poll inside Monitor runs
          // only while it is on screen.
          { id: "Monitor", title: "Monitor", content: tabContent(<Monitor />) },
        ]}
      />
    </div>
  );
}
