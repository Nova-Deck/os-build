// Steam's own action button (Play / Install / Pause / Resume), for our entries.
//
// Two seams, both found on the Pocket Max (client 1792618285, 2026-11-19):
//  1. The button is an exported React.forwardRef; its module's factory source holds
//     `bShowStreamingSelector`, `ShowStreamingMenu` and `strGameActionDetailsOverride`. React
//     reads `.render` on every render, so wrapping it reaches every button. For a shortcut the
//     wrapper hands the native element to our host (NativePage.tsx), which re-renders it with a
//     proxied overview (overview.ts).
//  2. The element's class decorates `OnClick` with a bind getter that caches a bound copy on the
//     instance at first access (a configurable prototype accessor). Its `render` cannot be
//     patched, but the getter can: ours installs a per-instance handler that runs our press when
//     the overview is one of our proxies, and Steam's own otherwise.
//
// The same button renders on library surfaces too, so they get our handler as well. If the click
// seam cannot be patched the button is left entirely stock (a proxied label with Steam's click
// would run the install stub from an "Install" press, which works, but from a "Pause" press too).

import { isValidElement, type ReactElement } from "react";
import { isOverviewLive, ourProxyAppid } from "./overview";
import { patchGetter, patchSlot } from "./slots";
import { findExportInModule, isClassComponent, isForwardRef, type ForwardRef } from "./webpack";

// Every non-Steam shortcut's appid has the top bit set: the cheap pre-filter. Whether one is OURS
// is the backend's registry answer, read by the host.
const SHORTCUT_BIT = 0x80000000;

export function isShortcutAppid(appid: unknown): appid is number {
  return typeof appid === "number" && appid >>> 0 >= SHORTCUT_BIT;
}

export type HostRenderer = (nativeElement: ReactElement, appid: number) => ReactElement;

type ButtonInstance = { props?: { overview?: unknown } };
type Handler = (...args: unknown[]) => unknown;
export type PressHandler = (appid: number) => void;

function patchOnClick(cls: unknown, onPress: PressHandler): () => void {
  if (!isClassComponent(cls)) throw new Error("the action button is not a class component");
  const proto = cls.prototype;
  // Steam's own handler per instance. Kept HERE, not as an own property on the instance: an own
  // OnClick would outlive this patch (an unpatch or a plugin reload) on every mounted button.
  const natives = new WeakMap<object, Handler>();
  return patchGetter(proto, "OnClick", (originalGet) =>
    function getOnClick(this: unknown) {
      // Read off the prototype itself (introspection): Steam's own getter, untouched.
      if (this === proto) return originalGet.call(this);
      const self = this as ButtonInstance & object;
      let native = natives.get(self);
      if (!native) {
        // Steam's getter binds and caches on whatever `this` it gets; an object inheriting from
        // the instance gets Steam's handler without it claiming the instance's own OnClick slot.
        native = originalGet.call(Object.create(self)) as Handler;
        natives.set(self, native);
      }
      const steams = native;
      // Steam calls `this.OnClick(...)` at click time (its render's arrow reads it then), so a
      // fresh wrapper per read costs nothing and always sees this load's handler.
      return (...args: unknown[]) => {
        const overview = self.props?.overview;
        const appid = ourProxyAppid(overview);
        if (appid === null || isOverviewLive(overview)) return steams(...args);
        try {
          onPress(appid);
        } catch (e) {
          console.error("novadeck-stores: action button press failed", e);
        }
        const event = args[1] as { stopPropagation?: () => void; preventDefault?: () => void } | undefined;
        event?.stopPropagation?.();
        event?.preventDefault?.();
        return undefined;
      };
    },
  );
}

// Install the patch. Returns its disposer, or null when Steam's button cannot be found (the legacy
// row then stays in charge). `onBroken` is told when the click seam fails at a render.
export function patchActionButton(
  renderHost: HostRenderer,
  onPress: PressHandler,
  onBroken: () => void,
): (() => void) | null {
  const button = findExportInModule(
    ["bShowStreamingSelector", "ShowStreamingMenu", "strGameActionDetailsOverride"],
    isForwardRef,
  );
  if (!button) return null;
  // Every class the forwardRef renders gets its click patched, not only the first one seen: a
  // proxied label over Steam's own click would run the install stub from a "Pause".
  const clicks = new Map<unknown, () => void>();
  let broken = false;
  const unpatchRender = patchSlot<ForwardRef["render"]>(button, "render", (original) =>
    function render(this: unknown, props, ref) {
      const element = original.call(this, props, ref);
      if (broken || !isValidElement(element)) return element;
      const appid = (props?.overview as { appid?: unknown } | undefined)?.appid;
      if (!isShortcutAppid(appid)) return element;
      try {
        if (!clicks.has(element.type)) clicks.set(element.type, patchOnClick(element.type, onPress));
        return renderHost(element, appid >>> 0);
      } catch (e) {
        broken = true;
        console.error("novadeck-stores: Steam's action button left stock", e);
        onBroken();
        return element;
      }
    },
  );
  return () => {
    unpatchRender();
    clicks.forEach((unpatch) => unpatch());
    clicks.clear();
  };
}
