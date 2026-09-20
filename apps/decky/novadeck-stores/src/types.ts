export type StoreId = "epic" | "gog";

export type StoreStatus = {
  store: StoreId;
  connected: boolean;
  account?: string | null;
};

// The backend answers with an error string instead of a store list when it cannot resolve the
// credential paths at all. That is a broken image, not an empty state, and the panel says so
// rather than showing two "not connected" rows — those would invite the user to fix it by
// signing in, which is the one action that cannot help.
// A plain union with an `in` check, NOT optional `never` members: TypeScript will not narrow a
// union on a truthiness test against an optional property, so `state.error ? … : state.stores`
// compiles with `state.stores` possibly undefined. Narrow on the key's presence instead.
export type State = { stores: StoreStatus[] } | { error: string };
