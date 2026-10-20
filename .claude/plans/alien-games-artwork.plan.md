# Plan: Alien games — artwork acquisition

**Source PRD**: `.claude/prds/alien-games.prd.md`
**Selected Milestone**: 5 — Artwork acquisition
**Complexity**: Medium
**Depends on**: milestone 4 for an entry to decorate (an appid). Drivable with a hand-placed
entry; no store account strictly required for Epic (cached metadata) and none at all for GOG
(the GamesDB endpoint is unauthenticated).

## Summary

A registered entry gets grid art — portrait capsule, hero banner, logo — and when the source is
unreachable the entry keeps its name tile rather than failing. Art is set through Steam's own
`SetCustomArtworkForApp`, consistent with milestone 4: Steam owns the file, so persistence is
its problem, not ours. The art comes from the **stores' own metadata**, so no SteamGridDB key —
no new secret, no new dependency (the PRD risk table wants art to degrade, never to block, and a
third-party key is the opposite of that).

Artwork is a non-blocking step after registration: it never gates the entry, and every failure
mode (no network, a missing kind, a corrupt download) leaves a usable entry behind.

## Verified before planning

| Fact | Evidence |
|---|---|
| `SetCustomArtworkForApp(appId, base64, 'jpg'\|'png', assetType)` and `ClearCustomArtworkForApp(appId, assetType)` exist on the arm64 client | `@decky/ui` `App.ts:567,62`; probed live 2026-10-20 |
| `ELibraryAssetType = {Capsule:0, Hero:1, Logo:2, Header:3, Icon:4, HeroBlur:5}` | `App.ts:744` |
| **Epic art is already on the device** — legendary caches `keyImages` per game under OUR store home, no network | `<LEGENDARY_CONFIG_PATH>/metadata/<app>.json`, verified live: `DieselGameBox` (wide) + `DieselGameBoxTall` (portrait). unifideck reads `~/.config/legendary` — wrong for us; we use the configured path |
| **GOG art is one unauthenticated GET** | `https://gamesdb.gog.com/platforms/gog/external_releases/<id>` → `vertical_cover`/`background`/`logo`/`square_icon`, verified live for both owned titles. No token, so root may fetch it without touching a credential |
| unifideck names grid files by the UNSIGNED appid (`<u>p.jpg`, `<u>_hero.jpg`, `<u>_logo.png`) under `<userdata>/<id>/config/grid/` | `services/artwork/fetcher.py:32-64` — the fallback path if the API does not persist |
| Our milestone-4 registry already maps `store:id → {appid, title}` | `shortcuts.py` |

## Design

**Set through the API, verify persistence at the gate.** `SetCustomArtworkForApp` from the
frontend bridge, one call per kind. It writes Steam's grid dir under the hood, so it should
survive a restart the way the entry does (milestone 4) — the gate confirms it, and the fallback
if it does not is to write the grid files directly by unsigned appid (unifideck's way, filenames
already known).

**Three kinds, each optional**, mapped to the asset types the library actually shows:

| kind | ELibraryAssetType | Epic keyImages (priority) | GOG GamesDB |
|---|---|---|---|
| capsule (portrait tile) | Capsule (0) | DieselGameBoxTall, OfferImageTall, Thumbnail | vertical_cover |
| hero (banner) | Hero (1) | DieselGameBox, DieselGameBoxWide | background |
| logo (transparent) | Logo (2) | DieselGameBoxLogo | logo |

A kind with no source is simply not set; the capsule is the one that matters for a non-broken
tile, and even it is best-effort.

**Store-native source, no new secret.**
- Epic: read legendary's cached metadata JSON from `<LEGENDARY_CONFIG_PATH>/metadata/<gid>.json`
  through `status.open_user_file` (owner-checked, like every other store read), pick a URL per
  kind by priority.
- GOG: one GET to the GamesDB endpoint; unauthenticated, so no token and no `store-gog-owned`
  round-trip.

**Download is untrusted input, treated as such** (the download is the one new network surface):
- https only — reject any other scheme, and do not fetch a redirect that leaves https.
- A hard size cap (8 MB) read incrementally, so a hostile or truncated response cannot exhaust
  memory.
- Magic-byte validation: JPEG (`FF D8 FF`) or PNG (`89 50 4E 47`) before the bytes are handed to
  the client; anything else is discarded as "no art for this kind", never forwarded.
- A per-request timeout; a stall is a skipped kind, not a hang.

**Non-blocking, and separate from registration.** `apply_artwork(store, gid, appid)` is its own
backend method. Milestone 7 will call it right after a successful `register_entry`, but a failure
there must never unwind the registration — the entry with a name tile is the floor, art is the
bonus. Re-running it is safe (idempotent: it re-sets the same slots).

## Patterns to Mirror

| Category | Source | Pattern |
|---|---|---|
| Frontend executes, backend decides | milestone 4 `shortcutBridge.ts` + `shortcut_op`/`shortcut_result` | A second op kind on the same bridge, same req/result pairing |
| Owner-checked store read | `status.open_user_file` | Reading legendary metadata as the plugin (root) without trusting the path |
| Best-effort, never block | `launchWrapper.ts` null-contract | A kind that cannot be had is skipped silently |
| Offline tests | `tests/test-store-shortcuts.sh` | Fixture metadata JSON and GamesDB JSON; a fake downloader asserts magic-byte rejection |

## Files to Change

| File | Action | Why |
|---|---|---|
| `apps/decky/novadeck-stores/py_modules/novadeck_stores/artwork.py` | CREATE | URL resolution per store, the download+validate, the kind→assetType map |
| `apps/decky/novadeck-stores/src/lib/shortcutBridge.ts` | UPDATE | An `artwork` op calling SetCustomArtworkForApp per kind |
| `apps/decky/novadeck-stores/src/index.tsx` | UPDATE | Route the artwork op (the op union already flows through one listener) |
| `apps/decky/novadeck-stores/main.py` | UPDATE | `apply_artwork(store, gid, appid)`, non-blocking, its own method |
| `tests/test-store-artwork.sh` | CREATE | Every decision above, offline |
| `Makefile` | UPDATE | The new suite in `make test` |
| `.claude/prds/alien-games.prd.md` | UPDATE | Milestone 5 row on completion |

## Tasks

### Task 1: URL resolution per store
- `artwork.py`: `epic_urls(gid, p)` from legendary metadata (owner-checked read), `gog_urls(gid)`
  from GamesDB. Each returns `{kind: url}` with https URLs only.
- **Validate**: fixture metadata JSON (Epic keyImages, GOG GamesDB shape); priority order asserted;
  a non-https url is dropped.

### Task 2: Download and validate
- `fetch_image(url)` → `(bytes, "jpg"|"png")` or None: https scheme, 8 MB cap read incrementally,
  magic-byte check, timeout.
- **Validate**: a fake opener feeds JPEG/PNG magic (accepted), HTML/oversized/truncated/`file://`
  (each rejected to None). No real network in the suite.

### Task 3: The bridge op and asset-type map
- `shortcutBridge.ts`: `{op:"artwork", req, appid, images:[{assetType, base64, imageType}]}` →
  one `SetCustomArtworkForApp` per image, result back through `shortcut_result`.
- `KIND_ASSET = {capsule:0, hero:1, logo:2}` lives in `artwork.py`; the payload carries the
  resolved ints so the frontend holds no mapping.
- **Validate**: `make decky-plugin` builds; the payload shape asserted from the backend side.

### Task 4: Backend, non-blocking
- `apply_artwork(store, gid, appid)`: resolve urls, download each kind, base64-encode, emit the
  artwork op, await the result. Returns `{applied: [kinds]}` or `{error}`; a download failure for
  one kind drops that kind and continues. Never raises into a caller.
- **Validate**: fakes the downloader and the frontend callback; a network-cut simulation (all
  downloads None) returns `{applied: []}` and emits nothing, proving art never blocks.

### Task 5: Hardware gate
- On the Pocket FIT, Steam running, driven over SSH (backend via drive.py, bridge via the gate
  one-shot CDP evaluate):
  1. Register a hand-placed Epic entry and a GOG one; `apply_artwork` each.
  2. Confirm the capsule/hero/logo are set (appStore overview art fields, or the grid files
     by unsigned appid).
  3. **Does it persist?** Steam restart + reboot — the art is still there, or the gate says it is
     not and the fallback (direct grid-file write) is the answer.
  4. **Network cut**: `apply_artwork` during a wlan cut returns `{applied: []}`, the entry keeps
     its name tile, nothing crashes.
  5. Sweep: no oversized writes, grid files (if any) deck-owned.

## Validation

```bash
bash tests/test-store-artwork.sh        # offline, every decision above
source dev.env && make test             # all suites
source dev.env && make decky-plugin     # the bridge compiles
```

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| `SetCustomArtworkForApp` does not persist across a restart | Medium | The gate's central check; fallback is the direct grid-file write, filenames already known |
| A store CDN serves a hostile or huge body | Low | https-only, 8 MB incremental cap, magic-byte validation before the client sees a byte |
| A URL from store metadata points somewhere internal (SSRF) | Low | Scheme restricted to https; the URLs originate from the stores' own metadata, not user input |
| Epic logo / a kind is simply absent | Common | Each kind optional; the capsule is what prevents a broken tile and even it is best-effort |
| Art blocks or unwinds a good registration | Must not | Its own method, awaited separately; every failure returns, never raises |

## Acceptance

- [ ] A registered Epic and GOG entry each get a capsule, from the store's own metadata
- [ ] Art is set through Steam's API; no third-party service or key
- [ ] A kind with no source, or an unreachable source, is skipped — the entry keeps a usable tile
- [ ] A download is https-only, size-capped, and magic-byte validated before the client sees it
- [ ] Art survives a restart and reboot — or the gate states it does not and the fallback is taken
- [ ] `make test` green with the new suite
