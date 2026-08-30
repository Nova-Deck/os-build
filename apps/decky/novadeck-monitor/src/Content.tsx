import { Field, PanelSection, PanelSectionRow } from "@decky/ui";
import { useEffect, useState } from "react";
import type { ReactNode } from "react";
import { getOsVersion, getTelemetry } from "./backend";
import { styles } from "./styles";
import type { Telemetry } from "./types";

// One unit for the pair, not one each: "1804 / 2035 MHz" rather than "1804 MHz / 2035 MHz".
// The panel is 300px, and the repeated unit was enough to push the cluster labels into an
// ellipsis on their own row.
const rangeMhz = (current: number, max: number, perMhz: number) =>
  `${Math.round(current / perMhz)} / ${Math.round(max / perMhz)} MHz`;
const KHZ_PER_MHZ = 1_000;
const HZ_PER_MHZ = 1_000_000;
const ratio = (value: number, of: number) => (of > 0 ? (value * 100) / of : 0);

function Bar({ percent }: { percent: number }) {
  const clamped = Math.max(0, Math.min(100, percent));
  return (
    <div className="novadeck-meter">
      <div className="novadeck-meter-fill" style={{ width: `${clamped}%` }} />
    </div>
  );
}

function Metric({ label, value, percent }: { label: ReactNode; value: string; percent?: number }) {
  return (
    <PanelSectionRow>
      {/* focusable is what makes the panel SCROLLABLE. The QAM is driven entirely by the
          gamepad: it scrolls by moving focus, so a panel built only of read-only Fields has no
          focus targets at all and everything below the fold is unreachable. These rows are not
          interactive — being focusable is purely what gives the stick something to move
          between. (This mattered even as a tab, where the sibling tabs got it for free from
          their sliders and dropdowns; as a standalone panel there is no such fallback at all.)

          The row owns its whole layout inside `children` rather than using Field's `label` and
          `description` slots. Those two lay out as a LABEL COLUMN beside the value, so a bar in
          the description slot inherits that column's width and ends up crushed against the
          number on the right. Handing Field one full-width child instead
          (childrenContainerWidth="max") lets the bar span the row, and the 16px gutter comes
          from PanelSectionRow as it does for every other row in the plugin. */}
      <Field focusable highlightOnFocus childrenLayout="below" childrenContainerWidth="max">
        <div className="novadeck-metric">
          <div className="novadeck-metric-head">
            <span className="novadeck-metric-label">{label}</span>
            <span className="novadeck-metric-value">{value}</span>
          </div>
          {percent === undefined ? null : <Bar percent={percent} />}
        </div>
      </Field>
    </PanelSectionRow>
  );
}

export function Content() {
  const [data, setData] = useState<Telemetry | null>(null);
  const [error, setError] = useState("");
  const [osVersion, setOsVersion] = useState("");

  // The release stamp never changes under a running session — fetch it once, not on the poll.
  useEffect(() => {
    let cancelled = false;
    getOsVersion()
      .then((version) => {
        if (!cancelled) setOsVersion(version);
      })
      .catch(() => {});
    return () => {
      cancelled = true;
    };
  }, []);

  useEffect(() => {
    let cancelled = false;
    const refresh = async () => {
      try {
        const next = await getTelemetry();
        if (cancelled) return;
        setData(next);
        setError("");
      } catch (reason) {
        // Keep the last good frame on screen rather than blanking the panel: at 1 Hz a
        // single dropped sample is a blink, and a monitor that flickers to an error and
        // back is harder to read than one that briefly stops moving.
        if (!cancelled && !data) setError(String(reason));
      }
    };
    refresh();
    const timer = window.setInterval(refresh, 1000);
    return () => {
      cancelled = true;
      window.clearInterval(timer);
    };
  }, []);

  // Everything the panel renders sits inside one scope div carrying the stylesheet, and the
  // release stamp closes it out — that line is what tells two dev cards apart in a bug report,
  // and a screenshot of this panel is exactly the artifact a bug report carries.
  const frame = (content: ReactNode) => (
    <div className="novadeck-monitor">
      <style>{styles}</style>
      {content}
      {osVersion ? <div className="novadeck-version-row">novadeck {osVersion}</div> : null}
    </div>
  );

  // No section title on this one: the QAM header already reads "Novadeck Monitor".
  if (!data) return frame(<PanelSection><Field label={error || "Reading sensors"} /></PanelSection>);

  const power = data.power;
  const fanPercent = ratio(power.fanPwm, power.fanCurveMaxPwm || 255);
  const overridden = !!power.activeCpuScheduler && power.activeCpuScheduler !== power.cpuScheduler;
  const profileOverridden = !!power.activeProfile && power.activeProfile !== power.profile;
  const schedulerLabel = (name: string) => (name === "none" ? "Stock (EEVDF)" : name);
  // Normally one value across every policy. "mixed" rather than picking one at random: if the
  // policies ever disagree that is worth seeing, not worth hiding behind whichever sorted first.
  const governors = [...new Set(data.cpuClusters.map((c) => c.governor).filter(Boolean))];
  const cpuGovernor = governors.length === 1 ? governors[0] : governors.length ? "mixed" : "";
  return frame(
    <>
      <PanelSection title="LOAD">
        <Metric label="CPU" value={`${data.cpuPercent.toFixed(1)}%`} percent={data.cpuPercent} />
        <Metric
          label="Memory"
          value={`${data.memory.usedMb} / ${data.memory.totalMb} MB`}
          percent={data.memory.percent}
        />
        {data.loadAverage.length ? (
          <Metric label="Load average" value={data.loadAverage.map((v) => v.toFixed(2)).join("  ")} />
        ) : null}
      </PanelSection>
      <PanelSection title="THERMAL">
        {/* Raw per-zone maxima. The bars run against a 100 °C full scale — not a throttle
            point, just a readable fixed reference, so the two bars stay comparable. */}
        <Metric
          label="CPU"
          value={data.temperatures.cpuC ? `${data.temperatures.cpuC.toFixed(1)} °C` : "—"}
          percent={data.temperatures.cpuC}
        />
        <Metric
          label="GPU"
          value={data.temperatures.gpuC ? `${data.temperatures.gpuC.toFixed(1)} °C` : "—"}
          percent={data.temperatures.gpuC}
        />
        <Metric
          label="Fan"
          value={power.fanRpm ? `${power.fanRpm} RPM  ${Math.round(fanPercent)}%` : `${Math.round(fanPercent)}%`}
          percent={fanPercent}
        />
        {/* Says WHY the fan is where it is. Deliberately a different number from the two
            above: powerd blends the hottest zones and smooths them, and that blend — not
            either reading above — is what the curve is evaluated against. */}
        {power.temperature ? (
          <div className="novadeck-field-note">
            Fan curve input: {power.temperature} °C (smoothed, hottest zones blended).
          </div>
        ) : null}
      </PanelSection>
      <PanelSection title="CLOCKS">
        {/* Label carries the cores only. The governor lives under RUNTIME: it is the same on
            every policy (apply_profile writes one value to all of them), so repeating it on
            four rows spent the width the clock numbers actually need. */}
        {data.cpuClusters.map((cluster) => (
          <Metric
            key={cluster.cores}
            label={`CPU ${cluster.cores}`}
            value={rangeMhz(cluster.khz, cluster.maxKhz, KHZ_PER_MHZ)}
            percent={ratio(cluster.khz, cluster.maxKhz)}
          />
        ))}
        {data.gpu.maxHz ? (
          <Metric
            label="GPU"
            value={rangeMhz(data.gpu.hz, data.gpu.maxHz, HZ_PER_MHZ)}
            percent={ratio(data.gpu.hz, data.gpu.maxHz)}
          />
        ) : null}
      </PanelSection>
      <PanelSection title="RUNTIME">
        {/* The profile in force, which is what this tab is for — flagged when a game's tweak,
            not the user's own choice, is what put it there. */}
        <Metric
          label="Power profile"
          value={
            profileOverridden
              ? `${power.activeProfile} (game override)`
              : power.activeProfile || "—"
          }
        />
        <Metric label="CPU governor" value={cpuGovernor || "—"} />
        {data.gpu.maxHz ? <Metric label="GPU governor" value={data.gpu.governor || "—"} /> : null}
        <Metric
          label="CPU scheduler"
          value={
            overridden
              ? `${schedulerLabel(power.activeCpuScheduler)} (game override)`
              : schedulerLabel(power.cpuScheduler) || "—"
          }
        />
        {power.error ? <Field label={power.error} /> : null}
      </PanelSection>
    </>,
  );
}
