export const styles = `
      /* NEVER put a backtick in this file. It is one template literal, so a backtick inside a
         comment ENDS the string: every rule below the stray one silently disappears and the
         panel renders unstyled. It does not fail the build -- what follows the truncation
         parses as a valid expression -- so tsc and rollup both stay green (cost two broken
         deploys on novadeck-control, 2026-08-09). tests/test-decky.sh asserts on it. */

      /* No position:fixed wrapper here, unlike novadeck-control. That plugin sizes itself
         against the viewport (300px, height 95%) because it hosts a <Tabs> strip, which needs
         a sized container and then eats anything laid out after it. This panel has no tabs:
         it is plain PanelSections in the QAM's own content column, so it flows and scrolls
         natively and the wrapper below is a naming scope only. */
      .novadeck-monitor {
        width: 100%;
      }
      /* A metric row: label and value on one line, the bar spanning the full width beneath.
         The row is one full-width child of a Field (see Content.tsx) rather than Field's own
         label/description slots, because those lay out as a label COLUMN and squeeze the bar
         against the value. Horizontal inset is PanelSectionRow's, which is where every other
         row in the Decky QAM gets its 16px gutter. */
      .novadeck-monitor .novadeck-metric {
        width: 100%;
        min-width: 0;
      }
      .novadeck-monitor .novadeck-metric-head {
        display: flex;
        align-items: baseline;
        justify-content: space-between;
        gap: 12px;
      }
      /* The label yields: a long one (cluster rows carry their core list) must ellipsize
         rather than wrap or push the value off the row. */
      .novadeck-monitor .novadeck-metric-label {
        min-width: 0;
        overflow: hidden;
        text-overflow: ellipsis;
        white-space: nowrap;
      }
      /* The fill is transitioned so a 1 Hz sample reads as movement rather than as a row of
         numbers snapping between frames. */
      .novadeck-monitor .novadeck-meter {
        height: 6px;
        margin-top: 6px;
        width: 100%;
        border-radius: 3px;
        overflow: hidden;
        background: rgba(255, 255, 255, 0.14);
      }
      .novadeck-monitor .novadeck-meter-fill {
        height: 100%;
        background: currentColor;
        opacity: 0.75;
        transition: width 0.35s linear;
      }
      /* Tabular figures: without them the last digit of a live value jitters the whole
         right-aligned column on every sample. flex-shrink:0 so the value keeps its room and
         the label is what gives way. */
      .novadeck-monitor .novadeck-metric-value {
        flex: 0 0 auto;
        font-variant-numeric: tabular-nums;
        font-weight: 600;
      }
      /* Bare explainer text placed directly in a PanelSection. The 16px gutter every other row
         gets comes from PanelSectionRow, which this is not inside, so it carries its own. */
      .novadeck-monitor .novadeck-field-note {
        box-sizing: border-box;
        width: 100%;
        padding: 2px 16px 6px;
        font-size: 12px;
        line-height: 16px;
        opacity: 0.62;
      }
      .novadeck-monitor .novadeck-version-row {
        padding: 4px 16px 12px;
        font-size: 11px;
        opacity: 0.5;
        text-align: right;
      }
    `;
