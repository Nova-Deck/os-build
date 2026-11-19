// Steam's play-bar row (button · status and stats · icon buttons) and the PlaySection around it.
//
// Neither is exported. The row is a React.forwardRef whose render builds
// `ActionRow > [ActionButtonAndStatusPanel, StatusAndStats, AppButtons]`; the PlaySection is the
// forwardRef above it, whose element Steam follows with its own cloud-status line. Both are found
// once at runtime from a node rendered inside the row (the action-button host renders a hidden
// probe): walk the probe's fiber up to them, then wrap their `render` like any other forwardRef.
// Found on the Pocket Max 2026-11-19 at 14 (row) and 19 (section) fibers above the button.

import type { ReactElement } from "react";
import { isShortcutAppid } from "./actionButton";
import { patchSlot } from "./slots";
import { renderSource, type ForwardRef } from "./webpack";

export type Decorator = (element: ReactElement, appid: number) => ReactElement;

type Fiber = {
  type?: unknown;
  return?: Fiber | null;
  memoizedProps?: Record<string, unknown> | null;
  stateNode?: { forceUpdate?: () => void } | null;
};

let unpatchRow: (() => void) | null = null;
let unpatchSection: (() => void) | null = null;
let rowDecorator: Decorator | null = null;
let sectionDecorator: Decorator | null = null;

export function setDecorators(row: Decorator | null, section: Decorator | null): void {
  rowDecorator = row;
  sectionDecorator = section;
}

function fiberOf(node: Element): Fiber | null {
  const key = Object.keys(node).find((k) => k.startsWith("__reactFiber$"));
  return key ? ((node as unknown as Record<string, Fiber>)[key] ?? null) : null;
}

function isRow(fiber: Fiber): boolean {
  const source = renderSource(fiber.type);
  return !!fiber.memoizedProps?.details && source.includes("ActionButtonAndStatusPanel") && source.includes("AppButtons");
}

function isSection(fiber: Fiber): boolean {
  const source = renderSource(fiber.type);
  return source.includes(".PlaySection") && source.includes("onNav");
}

function wrap(type: ForwardRef, label: string, current: () => Decorator | null): () => void {
  return patchSlot<ForwardRef["render"]>(type, "render", (original) =>
    function render(this: unknown, props, ref) {
      const out = original.call(this, props, ref) as ReactElement;
      const decorate = current();
      const appid = (props?.overview as { appid?: unknown } | undefined)?.appid;
      if (!decorate || !isShortcutAppid(appid)) return out;
      try {
        return decorate(out, appid >>> 0);
      } catch (e) {
        console.error(`novadeck-stores: ${label} left stock`, e);
        return out;
      }
    },
  );
}

// Patch the row (and its PlaySection) from a node rendered inside it. After the first success it
// returns at once. Returns whether the row is patched.
export function patchRowFrom(node: Element): boolean {
  if (unpatchRow) return true;
  if (!rowDecorator) return false;
  let row = fiberOf(node);
  while (row && !isRow(row)) row = row.return ?? null;
  if (!row) return false;
  let section: Fiber | null = row.return ?? null;
  while (section && !isSection(section)) section = section.return ?? null;
  try {
    if (section) unpatchSection = wrap(section.type as ForwardRef, "play section", () => sectionDecorator);
    unpatchRow = wrap(row.type as ForwardRef, "play bar", () => rowDecorator);
  } catch (e) {
    console.error("novadeck-stores: play bar patch failed", e);
    unpatchSection?.();
    unpatchSection = null;
    return false;
  }
  // The row has rendered once without us: re-render it through the patches.
  for (let up = (section ?? row).return; up; up = up.return ?? null) {
    if (typeof up.stateNode?.forceUpdate === "function") {
      up.stateNode.forceUpdate();
      break;
    }
  }
  return true;
}

export function unpatchRowAndSection(): void {
  unpatchRow?.();
  unpatchRow = null;
  unpatchSection?.();
  unpatchSection = null;
}
