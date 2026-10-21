export const styles = `
      /* NEVER put a backtick in this file. It is one template literal, so a backtick inside a
         comment ENDS the string: every rule below the stray one silently disappears and the
         panel renders unstyled, while tsc and rollup both stay green. Same rule as
         novadeck-framegen and novadeck-control; tests/test-decky.sh asserts on it. */

      /* No position:fixed wrapper and no tabs: this panel is plain PanelSections flowing in the
         QAM's own content column, so the QAM's padding is already right. The scope class exists
         to name the rows below, nothing more. */
      .novadeck-stores {
        width: 100%;
      }
      /* The status word carries the meaning of each row, so it is the one thing allowed to be
         louder than the label next to it. */
      .novadeck-stores .novadeck-store-state {
        font-weight: 600;
      }
      .novadeck-stores .novadeck-store-note {
        font-size: 12px;
        opacity: 0.7;
      }
      /* An expired row's Sign in again + Disconnect, stacked: side by side they do not fit the
         QAM's width. */
      .novadeck-stores .novadeck-store-actions {
        display: flex;
        flex-direction: column;
        gap: 8px;
      }
      /* Download progress under an Activity row. Thin, so a row with a download still reads as
         a row and not as a progress widget. */
      .novadeck-stores .novadeck-store-bar {
        height: 4px;
        margin-top: 6px;
        border-radius: 2px;
        background: rgba(255, 255, 255, 0.15);
        overflow: hidden;
      }
      .novadeck-stores .novadeck-store-bar-fill {
        height: 100%;
        background: #1a9fff;
        transition: width 0.5s linear;
      }
`;
