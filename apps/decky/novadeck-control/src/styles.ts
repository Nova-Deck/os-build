export const styles = `
      /* position:fixed sizes against the viewport, so the width must restate the QAM plugin
         content area (measured live via CDP on our client: x=48, 300px wide). The reference
         plugin uses 316px + margin-left:-8px, which on OUR client escapes that area by 8px on
         BOTH sides — a focused row's full-width highlight then paints over the QAM sidebar. */
      .novadeck-control-tabs {
        height: 95%;
        width: 300px;
        position: fixed;
        margin-top: -12px;
        overflow: hidden;
      }
      .novadeck-control-tabs > div > div:first-child::before {
        background: #0D141C;
        box-shadow: none;
        backdrop-filter: none;
      }
      .novadeck-control-tabs [role="tabpanel"] {
        padding-left: 0 !important;
        padding-right: 0 !important;
      }
      .novadeck-control-tabs .novadeck-control-tab-content {
        padding-bottom: 24px;
      }
      /* A label-less SelectEdit renders a BARE Dropdown — none of the vertical padding that a
         Field-wrapped row carries. Decky paints a focused row's highlight slightly outside its own
         box, so with no gap below, the next row's highlight lands on this dropdown's bottom edge
         (HW-observed: the enable toggle's focus ring touching the edit-target dropdown). Reserve
         the space here rather than on the toggle, which is shared by every other tab. */
      .novadeck-control-tabs .novadeck-bare-dropdown {
        padding-bottom: 8px;
      }
      /* NEVER put a backtick in this file. It is one template literal, so a backtick inside a
         comment ENDS the string: every rule below the stray one silently disappears and each
         tab renders unstyled. It does not fail the build -- what follows the truncation parses
         as a valid expression -- so tsc and rollup both stay green (cost two broken deploys,
         2026-08-09). tests/test-decky.sh now asserts on it. */
      /* No overflow:hidden. This wrapper is the only element between PanelSectionRow and the
         slider, and Decky paints a focused row's highlight slightly OUTSIDE the row's own box
         (see the bare-dropdown note above) -- clipping here cropped the highlight back to the
         padded content box, so slider rows highlighted narrower than every other row. The rule
         below is what keeps the slider's internals inside the panel, by capping their width
         directly rather than by hiding the overflow. */
      .novadeck-control-tabs .novadeck-slider-field {
        width: 100%;
        max-width: none;
      }
      .novadeck-control-tabs .novadeck-slider-field * {
        min-width: 0 !important;
        max-width: 100% !important;
      }
      /* Bare explainer text placed directly in a PanelSection. The tabpanel's own padding is
         zeroed above (the tabs span the QAM's full width), so anything not wrapped in a
         PanelSectionRow must carry the QAM's 16px horizontal padding itself. */
      .novadeck-control-tabs .novadeck-field-note {
        box-sizing: border-box;
        width: 100%;
        padding: 2px 16px 6px;
        font-size: 12px;
        line-height: 16px;
        opacity: 0.62;
      }
      /* The metric/meter rules that used to live here left with the Monitor tab -- they are
         now novadeck-monitor's styles.ts, rescoped to that plugin's own root class. */
      .novadeck-control-tabs .novadeck-version-row {
        padding: 4px 16px 0;
        font-size: 11px;
        opacity: 0.5;
        text-align: right;
      }
    `;
