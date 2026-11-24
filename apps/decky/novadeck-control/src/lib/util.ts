export function clone<T>(obj: T): T {
  return JSON.parse(JSON.stringify(obj));
}

// Apply edits to a settings section IN PLACE (callers pass a clone). undefined is "remove the key":
// the consumers treat absence as "no opinion", which is different from any concrete value.
export function applyChanges(section: Record<string, any>, changes: Record<string, any>) {
  for (const [key, value] of Object.entries(changes)) {
    if (value === undefined) delete section[key];
    else section[key] = value;
  }
}

export function update<T>(obj: T, path: (string | number)[], value: any): T {
  const next = clone(obj);
  let cursor: any = next;
  for (let i = 0; i < path.length - 1; i += 1) cursor = cursor[path[i]];
  cursor[path[path.length - 1]] = value;
  return next;
}
