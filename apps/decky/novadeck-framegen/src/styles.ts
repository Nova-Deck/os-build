export const styles = `
      /* NEVER put a backtick in this file. It is one template literal, so a backtick inside a
         comment ENDS the string: every rule below the stray one silently disappears and the
         panel renders unstyled. It does not fail the build -- what follows the truncation
         parses as a valid expression -- so tsc and rollup both stay green (it cost two broken
         deploys on novadeck-control). tests/test-decky.sh asserts on it. */

      /* No position:fixed wrapper, for the same reason novadeck-monitor has none: this panel
         hosts no <Tabs> strip, so it is plain PanelSections flowing in the QAM's own content
         column. The scope class below exists to name the slider, nothing more. */
      .novadeck-framegen {
        width: 100%;
      }
      /* Let the slider use the full width of the row WITHOUT touching its padding.
         novadeck-control zeroes its tabpanel padding because its tabs span the QAM edge to edge
         and it has to put the 16px back by hand; this panel has no tabs, so the QAM's own
         padding is already correct and removing it just jams the slider against the edge
         (HW-observed 2026-08-30). Constrain width, leave spacing alone. */
      .novadeck-framegen .novadeck-slider-field {
        width: 100%;
        max-width: none;
      }
      .novadeck-framegen .novadeck-slider-field * {
        min-width: 0 !important;
        max-width: 100% !important;
      }
`;
