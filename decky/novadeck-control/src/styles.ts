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
      .novadeck-control-tabs .novadeck-slider-field {
        width: 100%;
        max-width: none;
        overflow: hidden;
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
      .novadeck-control-tabs .novadeck-version-row {
        padding: 4px 16px 0;
        font-size: 11px;
        opacity: 0.5;
        text-align: right;
      }
    `;
