// Finding Steam's components by SHAPE: minified export names and module ids change with every
// client build, so a component is found by strings in its module's factory source, and checked by
// the form of its export (forwardRef, memo, class).
//
// @decky/ui already requires every module in this context when it loads, so calling the webpack
// require here only reads its cache: no module factory runs for the first time from this file.

type WebpackRequire = ((id: string) => unknown) & { m: Record<string, unknown> };

let cached: WebpackRequire | null = null;

// Steam's webpack require, borrowed the way @decky/ui borrows it: by pushing a throwaway chunk.
function getRequire(): WebpackRequire | null {
  if (cached) return cached;
  const chunks = (window as unknown as { webpackChunksteamui?: unknown[] }).webpackChunksteamui;
  if (!Array.isArray(chunks)) return null;
  let req: WebpackRequire | undefined;
  chunks.push([[Symbol("novadeck-stores")], {}, (r: WebpackRequire) => (req = r)] as never);
  cached = req && req.m ? req : null;
  return cached;
}

function sourceOf(value: unknown): string {
  try {
    return String(value);
  } catch (error) {
    return "";
  }
}

function exportValues(req: WebpackRequire, id: string): unknown[] {
  let exports: unknown;
  try {
    exports = req(id);
  } catch (error) {
    return [];
  }
  if (!exports || typeof exports !== "object") return [];
  const record = exports as Record<string, unknown>;
  return Object.keys(record).map((key) => {
    try {
      return record[key];
    } catch (error) {
      return undefined; // a throwing getter
    }
  });
}

// The first export `pick` accepts, of the first module whose factory source holds every needle.
export function findExportInModule<T>(needles: readonly string[], pick: (value: unknown) => value is T): T | null {
  const req = getRequire();
  if (!req) return null;
  for (const id of Object.keys(req.m)) {
    const source = sourceOf(req.m[id]);
    if (!needles.every((needle) => source.includes(needle))) continue;
    const found = exportValues(req, id).find(pick);
    if (found !== undefined) return found;
  }
  return null;
}

export type ForwardRef = { $$typeof: symbol; render: (props: Record<string, unknown>, ref: unknown) => unknown };

const FORWARD_REF = Symbol.for("react.forward_ref");

export function isForwardRef(value: unknown): value is ForwardRef {
  const v = value as ForwardRef | null;
  return !!v && v.$$typeof === FORWARD_REF && typeof v.render === "function";
}

export function isClassComponent(value: unknown): value is { prototype: object } {
  return typeof value === "function" && !!(value as { prototype?: { isReactComponent?: unknown } }).prototype?.isReactComponent;
}

export function renderSource(type: unknown): string {
  return isForwardRef(type) ? sourceOf(type.render) : "";
}
