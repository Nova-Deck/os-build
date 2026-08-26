import { useEffect } from "react";
import type { MutableRefObject, Dispatch, SetStateAction } from "react";
import { saveTweaks } from "../backend";
import type { Config } from "../types";

// Edits land in local state instantly; the file write trails by `delay` so a slider drag is
// one write, not thirty. The snapshot ref holds the last SAVED serialization — comparing
// against it is what makes a backend echo (which may reorder keys) not retrigger a save.
export function useDebouncedTweaksSave({ config, snapshot, setConfig, onError, delay = 900 }: {
  config: Config | null;
  snapshot: MutableRefObject<string>;
  setConfig: Dispatch<SetStateAction<Config | null>>;
  onError?: (error: unknown) => void;
  delay?: number;
}) {
  const value = config?.tweaks;
  useEffect(() => {
    if (!config || !snapshot.current || value === undefined) return;
    const current = JSON.stringify(value);
    if (current === snapshot.current) return;
    const timer = window.setTimeout(async () => {
      try {
        const saved = current;
        const next = await saveTweaks(value);
        snapshot.current = JSON.stringify(next);
        setConfig((stored) => {
          if (!stored) return stored;
          // Only adopt the echo if nothing changed while the save was in flight.
          if (JSON.stringify(stored.tweaks) !== saved) return stored;
          return { ...stored, tweaks: next };
        });
      } catch (error) {
        onError?.(error);
      }
    }, delay);
    return () => window.clearTimeout(timer);
  }, [value]);
}
