import { DialogButton, Field, Focusable, PanelSection, PanelSectionRow } from "@decky/ui";
import { useEffect, useRef, useState } from "react";
import { calibratePanel, getPanelStatus, revertPanel, savePanel, setPanel } from "../backend";
import { ButtonRow } from "../components/widgets";
import type { PanelStatus } from "../types";

// The display's REAL state, measured, not configured: the scanout rate from vblank sequence
// numbers and — on panels whose driver exposes frame_len trim knobs — the calibration that pins
// it just above nominal. Measurement works on every board; the controls only exist where the
// knobs do (e.g. Odin 3, Odin 2 Portal), so boards like the Pocket Fit just get the readout.
//
// Every control acts LIVE on the rate the panel is scanning now; nothing is kept across a reboot
// until Save. Calibrate lands automatically, skipping the values the backend knows gray this
// panel's picture. Hand-stepping the knob is an operator job: `panel-calibration step` over SSH.
export function Panel() {
  const [status, setStatus] = useState<PanelStatus | null>(null);
  const [busyLabel, setBusyLabel] = useState<string | null>(null);
  const [message, setMessage] = useState<string | null>(null);
  const busy = useRef(false);

  // Each poll measures ~0.5s of vblanks on the backend, so poll gently — and never underneath
  // a running action, whose own measurements the extra vblank waits would jitter.
  useEffect(() => {
    let cancelled = false;
    const refresh = async () => {
      if (busy.current) return;
      try {
        const next = await getPanelStatus();
        if (!cancelled && !busy.current) setStatus(next);
      } catch (error) {
        // transient backend hiccups just skip a poll
      }
    };
    const timer = window.setInterval(refresh, 5000);
    refresh();
    return () => {
      cancelled = true;
      window.clearInterval(timer);
    };
  }, []);

  // One action at a time; the result (or error) is the message, then the status is re-read.
  const run = async (label: string, action: () => Promise<string>) => {
    if (busy.current) return;
    busy.current = true;
    setBusyLabel(label);
    try {
      setMessage(await action());
    } catch (error) {
      setMessage(String(error));
    } finally {
      busy.current = false;
      setBusyLabel(null);
      try {
        setStatus(await getPanelStatus());
      } catch (error) {
        // the next poll catches up
      }
    }
  };

  const measured = status?.measuredHz;
  const nominal = status?.nominalHz;
  const deviation = measured != null && nominal != null ? measured - nominal : null;
  const rate = nominal != null && status?.rates.includes(nominal) ? nominal : null;
  const key = rate != null ? String(rate) : null;
  const live = key ? status?.current[key] : undefined;
  const saved = key ? status?.saved[key] : undefined;
  const fallback = key ? status?.defaults[key] : undefined;
  const stored = saved ?? fallback;
  const unsaved = live !== undefined && stored !== undefined && live !== stored;
  const working = busyLabel != null;

  const calibrate = () =>
    run("Calibrating…", async () => {
      const result = await calibratePanel();
      if (result.error) return `Calibration failed: ${result.error}`;
      return `${result.rate} Hz: ${result.startHz} → ${result.endHz} Hz (not saved yet)`;
    });

  const resetToDefault = () =>
    run("Resetting…", async () => {
      const result = await setPanel(rate!, fallback!);
      return result.error ?? `Driver default ${fallback} applied (not saved yet)`;
    });

  const save = () =>
    run("Saving…", async () => {
      const result = await savePanel(rate!);
      if (result.error) return result.error;
      return result.saved == null ? "Saved: this unit uses the driver default" : `Saved ${result.saved} for this unit`;
    });

  const revert = () =>
    run("Reverting…", async () => {
      const result = await revertPanel(rate!);
      return result.error ?? `Back to ${result.value}`;
    });

  return (
    <PanelSection title="Display">
      <PanelSectionRow>
        <Field
          label="Measured refresh rate"
          description={
            deviation != null
              ? `Nominal ${nominal} Hz · ${deviation >= 0 ? "+" : ""}${deviation.toFixed(2)} Hz`
              : status?.measureError || undefined
          }
        >
          {measured != null ? `${measured.toFixed(2)} Hz` : "—"}
        </Field>
      </PanelSectionRow>
      {status?.supported && (
        <>
          <PanelSectionRow>
            <Field label="Calibration" description="Saved values are stored for this unit and re-applied at boot.">
              {status.rates
                .map((r) => {
                  const value = status.saved[String(r)];
                  return `${r} Hz: ${value !== undefined ? `saved ${value}` : "default"}`;
                })
                .join(" · ")}
            </Field>
          </PanelSectionRow>
          <ButtonRow
            label={busyLabel === "Calibrating…" ? busyLabel : "Calibrate Panel"}
            description={
              working
                ? "Keep the screen on."
                : `Tunes the ${nominal ?? "current"} Hz mode to just above its nominal rate, live; Save keeps it.` +
                  " To calibrate the other rate, start a game and set the Refresh Rate slider to it first" +
                  " — outside a game the panel stays at its top rate."
            }
            onClick={calibrate}
            disabled={working || rate == null}
          />
          {rate != null && live !== undefined && (
            <>
              <PanelSectionRow>
                <Field
                  label={`${rate} Hz frame length: ${live}${unsaved ? " (unsaved)" : ""}`}
                  childrenLayout="below"
                  childrenContainerWidth="max"
                >
                  {/* Several buttons in one row need a column Focusable, or the stick skips all but the first. */}
                  <Focusable className="novadeck-panel-actions" flow-children="column">
                    <DialogButton disabled={working || !unsaved} onClick={save}>
                      Save
                    </DialogButton>
                    <DialogButton disabled={working || !unsaved} onClick={revert}>
                      {saved !== undefined ? `Revert to saved (${saved})` : `Revert to default (${fallback})`}
                    </DialogButton>
                    <DialogButton
                      disabled={working || fallback === undefined || live === fallback}
                      onClick={resetToDefault}
                    >
                      {fallback !== undefined ? `Reset to driver default (${fallback})` : "Reset to driver default"}
                    </DialogButton>
                  </Focusable>
                </Field>
              </PanelSectionRow>
            </>
          )}
        </>
      )}
      {message && (
        <PanelSectionRow>
          <Field label={message} />
        </PanelSectionRow>
      )}
    </PanelSection>
  );
}
