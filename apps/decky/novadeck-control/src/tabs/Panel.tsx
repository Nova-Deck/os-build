import { Field, PanelSection, PanelSectionRow } from "@decky/ui";
import { useEffect, useRef, useState } from "react";
import { calibratePanel, getPanelStatus } from "../backend";
import { ButtonRow } from "../components/widgets";
import type { PanelStatus } from "../types";

// The display's REAL state, measured, not configured: the scanout rate from vblank timestamps
// and — on panels whose driver exposes frame_len trim knobs — the calibration that pins it to
// nominal. Measurement works on every board; the Calibrate button only exists where the knobs
// do (e.g. Odin 3), so boards like the Pocket Fit just get the readout.
export function Panel() {
  const [status, setStatus] = useState<PanelStatus | null>(null);
  const [calibrating, setCalibrating] = useState(false);
  const [message, setMessage] = useState<string | null>(null);
  const busy = useRef(false);

  // Each poll measures ~0.5s of vblanks on the backend, so poll gently — and never underneath
  // a running calibration, whose own measurements the extra vblank waits would jitter.
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

  const runCalibration = async () => {
    busy.current = true;
    setCalibrating(true);
    setMessage(null);
    try {
      const result = await calibratePanel();
      if (result.error) {
        setMessage(`Calibration failed: ${result.error}`);
      } else {
        setMessage(`${result.rate} Hz calibrated: ${result.startHz} → ${result.endHz} Hz`);
      }
    } catch (error) {
      setMessage(String(error));
    } finally {
      busy.current = false;
      setCalibrating(false);
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
  const calibrated = status && status.rates.some((rate) => status.saved[String(rate)] !== undefined);

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
            <Field
              label="Calibration"
              description="Stored for this unit and re-applied at boot."
            >
              {status.rates
                .map((rate) => {
                  const saved = status.saved[String(rate)];
                  return `${rate} Hz: ${saved !== undefined ? "calibrated" : "factory"}`;
                })
                .join(" · ")}
            </Field>
          </PanelSectionRow>
          <ButtonRow
            label={calibrating ? "Calibrating…" : "Calibrate Panel"}
            description={
              calibrating
                ? "Measuring and trimming the panel — takes up to a minute. Keep the screen on."
                : `Trims the panel so the ${nominal ?? "current"} Hz mode scans at its nominal rate. ` +
                  (calibrated ? "Recalibrating replaces this unit's stored value." : "") +
                  " To calibrate the other rate, start a game and set the Refresh Rate slider to it first" +
                  " — outside a game the panel stays at its top rate."
            }
            onClick={runCalibration}
            disabled={calibrating || measured == null}
          />
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
