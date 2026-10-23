# FoodCapture — macOS / iOS app

A native SwiftUI app that logs into Kroger or Costco in a real `WKWebView`, fetches the raw
receipt payloads from inside that page, and runs the whole pipeline on-device via `FoodCore`.
There is no server and no browser-automation framework.

Receipt endpoints reject headless HTTP clients, so the fetch happens in the same engine that
holds the authenticated session. The resulting payloads are byte-compatible with
`food import <file> --retailer …`.

## What it does

- **Fetch** — navigates to the retailer's origin, then runs the same requests the Python
  ingest makes (`purchase-history-search` + `v2/details` batches for Kroger;
  `receiptsWithCounts` GraphQL for Costco) via in-page `fetch()`. Kroger's details endpoint
  allows only a small number of batches per page load, so the app itemizes one chunk, reloads
  the page to re-arm it, and accumulates the chunks in Swift (`receiptsPerLoad` / `attempts`
  in `WebModel.swift`).
- **Sync** — runs normalize → store → canonicalize → resolve → inventory on-device, then
  refreshes the Kitchen.
- **Import** — accepts an archived payload from **Settings → Sync receipts → Import…**, so the
  pipeline can be exercised without touching a retailer.
- **Capture / Probe** — diagnostics: dump the cookie jar and origin storage, or run one search
  plus one details POST from inside the page and print the statuses.

Repeat syncs are incremental. The app reads the `external_id`s already in its database, so
Kroger itemizes only unseen receipts and with nothing new it skips the details calls and their
page reloads. Costco's GraphQL window starts from the newest stored purchase date with a 2-day
overlap. The first sync fetches the full history.

## The app

Two tabs, all backed by `FoodCore`:

- **Kitchen** — the dashboard. It leads with **Use soon**: everything expiring within 7 days,
  across every shelf, soonest-first. Below it, one section per shelf (fridge / freezer / pantry
  / counter) holds only what's left, so nothing appears twice. Long shelves collapse behind
  **Show N more**. Rows show the product name, brand (when it adds something), quantity and a
  relative date; swipe for **Used** / **Tossed**, tap for the item detail. Search filters every
  shelf by name, brand or category. When products are flagged, a **Needs review** section at
  the top offers one **Re-resolve N flagged items** action.
- **Settings** — provider API key, base URL, model, optional embeddings, **Sync receipts**
  (the in-app browser + Fetch/Import + Sync), and **Retry pending** when receipt lines are
  unmapped or still carry raw receipt text.

Item detail shows shelf life, its source, category, stock and price history. The **Shelf life**
section has a day stepper, **Save shelf life** (stores `source=user`, updates inventory expiry,
applies to future purchases of the same product) and **Mark as wrong** (flags it for the next
resolve pass; **Clear review** removes the flag).

The web dashboard (`food/web/`) mirrors the Kitchen: same relative-date phrasing
(`relative()` ↔ `Chat.relative`), same 7-day horizon (`USE_SOON_DAYS` ↔
`AppModel.useSoonDays`), same pantry-collapse rule (`COLLAPSE_THRESHOLD` ↔
`AppModel.collapseThreshold`), same brand-on-the-row rule and same name/brand/category search.
Keep the two in step when you change either.

`project.yml` signs with `DEVELOPMENT_TEAM: 6H5AQ9JDNV` (automatic), so physical-device runs
work; the simulator ignores signing.

### Keys on a device

A device build can't read your shell environment or the repo's `.env`. Put provider settings in
`mobile/ios/Secrets.env` (gitignored — copy `Secrets.env.example` to start); Debug builds copy
it into the app bundle (Release/archive builds do not). Precedence is **Settings UI
(UserDefaults) > process env (Xcode scheme / `devicectl`) > `Secrets.env` > built-in defaults**.

### Tracing

The app initializes Rig's OpenTelemetry exporter at launch. A Debug build sends OTLP to
`http://127.0.0.1:6006/v1/traces` (local Phoenix) unless `RIG_POC_OTLP_ENDPOINT` /
`OTEL_EXPORTER_OTLP_ENDPOINT` is set; `FOOD_TRACING_DISABLED=1` turns it off. Spans carry
`openinference.project.name` from `PHOENIX_PROJECT` (default `food`), so they land beside the
Python traces. A physical device needs your Mac's LAN address instead of `127.0.0.1`.

### Visual checks

Launch-time hooks make screenshots scriptable without tapping:

| Env var | Effect |
|---|---|
| `FOOD_DB_PATH` | Use a prepared database (absolute path) instead of Application Support/`food.db` |
| `FOOD_TAB` | `0` Kitchen, `2` Settings |
| `FOOD_ITEM` | Open that inventory id's detail view |

```bash
# seed a DB with the CLI, copy it into the app container, then:
SIMCTL_CHILD_FOOD_TAB=0 xcrun simctl launch booted ai.commandcode.food.capture
xcrun simctl io booted screenshot shot.png
```

## Build & run

Needs Xcode + [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`), plus
Rust 1.97.1 (pinned in `Rig/rust-toolchain.toml`) to build the Rig transport. `run.sh` and
`run-mac.sh` build the XCFramework automatically; when building FoodCore directly, run
`FoodCore/scripts/build-rig.sh` first (its outputs are gitignored):

```bash
# iOS: boot a simulator first, e.g.:
xcrun simctl boot "iPhone 17 Pro" && open "$(xcode-select -p)/../Applications/DeviceHub.app"
./run.sh            # build Rig, generate project, build, install, launch

# macOS:
./run-mac.sh        # build Rig, generate project, build, launch FoodCaptureMac
```

All LLM/embedding/Jev traffic goes Swift → generated UniFFI bindings → Rust (`Rig`) →
provider. Domain behavior (resolver, canonicalize, tool loop) stays in Swift for Python parity.

## Notes / limits

- No cap: every receipt is itemized, one batch per page load, so a large history means many
  reloads and a large raw payload.
- Kroger fetches via same-origin `fetch` on `www.kroger.com`; Costco's GraphQL is on
  `ecom-api.costco.com` and must run from the orders page for Origin/CORS, so the app navigates
  there first.
- Captured sessions and raw payloads contain purchase history; treat them as sensitive.
- Both the app and the Python client stop at the first `429`/`403` from a retailer. The throttle
  is per IP, so retrying only extends it.
