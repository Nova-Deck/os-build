// Reload-safe wrapping of a function on a Steam-owned object.
//
// The objects patched here (a forwardRef's `render`, a class prototype's accessor) are webpack
// singletons: they outlive a plugin reload, this module's variables do not. So the original is
// stashed ON the owner and the wrapper is branded: a fresh install after a reload finds the stash
// and never wraps a wrapper (a page that would then run our decoration twice).

const BRAND = "__novadeckWrapper";
const stashKey = (key: string) => `__novadeckOriginal_${key}`;

type AnyFn = (...args: never[]) => unknown;
type Owner = Record<string, unknown>;

// Replace owner[key] with makeWrapper(original). The disposer restores the original, but only
// while our wrapper is still the live value: a patch someone layered on top is never clobbered.
export function patchSlot<F extends AnyFn>(owner: object, key: string, makeWrapper: (original: F) => F): () => void {
  const o = owner as Owner;
  const current = o[key] as (F & { [BRAND]?: true }) | undefined;
  const stashed = o[stashKey(key)] as F | undefined;
  const original = typeof stashed === "function" ? stashed : current && !current[BRAND] ? current : undefined;
  if (typeof original !== "function") throw new Error(`cannot recover the original ${key}`);
  const wrapper = makeWrapper(original) as F & { [BRAND]?: true };
  wrapper[BRAND] = true;
  o[stashKey(key)] = original;
  o[key] = wrapper;
  return () => {
    if (o[key] === wrapper) {
      o[key] = original;
      delete o[stashKey(key)];
    }
  };
}

// Replace a prototype accessor's getter. Its original descriptor is stashed on the prototype, so a
// reload restores Steam's own getter, not a previous load's wrapper.
export function patchGetter(
  proto: object,
  key: string,
  makeGetter: (originalGet: (this: unknown) => unknown) => (this: unknown) => unknown,
): () => void {
  const p = proto as Owner;
  const stash = stashKey(`get_${key}`);
  const original = (p[stash] as PropertyDescriptor | undefined) ?? Object.getOwnPropertyDescriptor(proto, key);
  if (!original?.get || !original.configurable) throw new Error(`${key} is not a configurable accessor`);
  const getter = makeGetter(original.get);
  Object.defineProperty(proto, stash, { value: original, configurable: true, enumerable: false, writable: true });
  Object.defineProperty(proto, key, { configurable: true, enumerable: original.enumerable, get: getter });
  return () => {
    if (Object.getOwnPropertyDescriptor(proto, key)?.get === getter) {
      Object.defineProperty(proto, key, original);
      delete p[stash];
    }
  };
}
