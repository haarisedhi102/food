# FoodCapture — mobile in-app browser POC (iOS)

A small SwiftUI app that logs into Kroger/Costco in a **real WebKit engine** and pulls the
raw receipt payloads from *inside* that engine. It exists because of a concrete finding:

> Akamai fronting Kroger and Costco rejects **every headless HTTP client** on the receipt
> endpoints — `curl_cffi`, even with a Chrome TLS/JA3 + HTTP/2 fingerprint, and
> `node-libcurl` with an explicit Akamai HTTP/2 fingerprint, both get their HTTP/2 stream
> **reset**. The same request from the app's WebKit engine returns **200** with identical
> cookies. Akamai validates its `_abck` bot cookie against the browser's fingerprint and
> behaviour, which no non-browser client reproduces.

So the browser engine isn't just needed for the *login* (Google/Meta-style in-app browser) —
it's needed for the *fetch*. The server becomes browser-free; the phone does the fetching.

## What it does

- **Fetch** — navigates to the retailer's origin, then runs the same requests the Python
  ingest makes (`purchase-history-search` + `v2/details` batches for Kroger;
  `receiptsWithCounts` GraphQL for Costco) via in-page `fetch()`, and writes
  `kroger-raw.json` / `costco-raw.json`. Those files are **byte-compatible with
  `food import <file> --retailer …`** — the existing escape hatch — so no backend change is
  needed to consume them.
- **Capture** — reads the full cookie jar (incl. httpOnly) and origin `localStorage` (Costco's
  `idToken`) into a JSON file, for inspecting the authenticated session. Handy for debugging;
  the **Fetch** above does not depend on it (it runs inside the logged-in page).
- **Probe** — runs one search + one details POST from inside the page and prints the statuses.
  This is the ground-truth check that proved the Akamai finding (`details: 200` here vs stream
  reset from HTTP clients).

## The per-page-load wall (important)

Kroger's `purchase-history/v2/details` allows only **~1 batch per page load**, then starts
dropping connections with `TypeError: Load failed` — and **retries never recover**, because the
limit isn't time-based. Observed twice: exactly the first 2 batches returned 200 and the other
11 failed, with backoff making no difference (Akamai's `_abck` sensor validates a couple of
requests per page load, then stops).

The fix is not more retries — it's **re-arming the page**: itemize one batch, reload the page
(which re-runs the sensor), itemize the next, and accumulate across loads in Swift. With that,
a full run is clean:

```
search=157 keys=123 new=123 loads=13 detailsOk=13 errors=0 retries=0
→ food import kroger-raw.json --retailer kroger
→ kroger: 123 receipts, 123 new, 1026 new items
```

`receiptsPerLoad` / `attempts` in `WebModel.swift` tune the chunk size and retry budget.

Repeat syncs are incremental. The app reads the `external_id`s already in its database and
passes them to the fetch, so Kroger itemizes only receipts it has not seen — with nothing new,
it skips the details calls and their page reloads entirely. (It still pages the small search
list rather than stopping early, matching Python's `skip_keys` behaviour and avoiding any
assumption about result ordering.) Costco's GraphQL window starts from the newest stored
purchase date (with a 2-day overlap for late-posted receipts) instead of pulling the full 90
days again. The first sync still fetches the whole history.

## The app

Two tabs, all backed by `FoodCore` on-device (no server):

- **Kitchen** — the dashboard, and the app's reason to exist. It leads with **Use soon**: everything
  expiring within 7 days, across every shelf, soonest-first — the daily action list. Below it, one
  section per shelf (fridge / freezer / pantry / counter) holds *only what's left* (beyond the
  horizon), so nothing is listed twice and the tab reads "act on these, browse the rest". Long
  shelves collapse — the pantry (365 mostly shelf-stable rows) folds behind **Show N more**, so the
  default tab is a screenful rather than a 400-row wall. Rows show the full product name, brand
  (when it adds something — omitted if missing or already in the name), quantity, and a friendly
  relative date ("today", "in 3 days"); swipe for **Used** / **Tossed**; tap for the item detail
  (shelf-life source, category, price history, used/tossed actions). The search field filters
  across every shelf by name, brand or category.
- **Settings** — provider API key, base URL, model, and optional embeddings (persisted in
  UserDefaults; a blank field falls back to the built-in default or an injected env var), plus
  **Sync receipts**: the in-app browser (Kroger / Costco) and **Sync**, which runs
  normalize → store → canonicalize → resolve → inventory on the device and refreshes the dashboard.

Receipt fetching is an occasional action, so it lives behind **Settings → Sync receipts** rather
than in the tab bar — the tab bar stays for navigation, per Apple's HIG.

The web dashboard (`food/web/`) mirrors this: the same relative-date phrasing (`relative()` in
`app.py` ↔ `Chat.relative` in Swift), the same 7-day "Use soon" horizon (`USE_SOON_DAYS` ↔
`AppModel.useSoonDays`), the same pantry-collapse rule (`COLLAPSE_THRESHOLD` ↔
`AppModel.collapseThreshold`, expanded with `/?show=pantry`), the same brand-on-the-row rule
(`brand_of()` ↔ `ItemRow.brandText`, both suppressing a brand already in the name), and the same
name/brand/category search (`/?q=` ↔ the `.searchable` field). Keep the two in step when you
change either.

`project.yml` signs with `DEVELOPMENT_TEAM: 6H5AQ9JDNV` (automatic), so physical-device runs
work: an unsigned device build fails to launch. The simulator ignores signing either way.

### Keys on a device

A device build can't read your shell environment or the repo's `.env`. Put the provider
settings in `mobile/ios/Secrets.env` (gitignored — copy `Secrets.env.example` to start); Debug
builds copy it into the app bundle (Release/archive builds deliberately do not, so keys can't
leak in an `.ipa`). Precedence is **Settings UI (UserDefaults) > process env (Xcode scheme /
`devicectl`) > `Secrets.env` > built-in defaults**. `project.yml` changed, so regenerate with
`./run.sh` or `xcodegen generate` once.

### Visual checks

Launch-time hooks make screenshots scriptable without tapping:

| Env var | Effect |
|---|---|
| `FOOD_DB_PATH` | Use a prepared database instead of Application Support/`food.db` |
| `FOOD_TAB` | `0` Kitchen, `2` Settings |
| `FOOD_ITEM` | Open that inventory id's detail view |

```bash
# seed a DB with the CLI (schema + sample rows), copy it into the app container, then:
SIMCTL_CHILD_FOOD_TAB=0 xcrun simctl launch booted ai.commandcode.food.capture
xcrun simctl io booted screenshot shot.png
```

## Build & run

Needs Xcode + [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`), plus
Rust 1.97.1 (pinned in `Rig/rust-toolchain.toml`) to build the Rig transport. `run.sh` generates
the XCFramework automatically; when building FoodCore directly, run
`FoodCore/scripts/build-rig.sh` first (its outputs are gitignored):

```bash
# boot a simulator first, e.g.:
xcrun simctl boot "iPhone 17 Pro" && open "$(xcode-select -p)/../Applications/DeviceHub.app"
./run.sh            # build Rig, generate project, build, install, launch
```

For a native macOS app (same sources, AppKit/UIKit differences behind `#if os`):

```bash
./run-mac.sh        # build Rig, generate project, build, launch FoodCaptureMac
```

All LLM/embedding/Jev traffic goes Swift -> generated UniFFI bindings -> Rust (`Rig`) ->
provider. Domain behavior (resolver, canonicalize, tool loop) stays in Swift for Python parity.

In the app: pick the retailer, log in, tap **Fetch**. Then **Share** the produced
`*-raw.json` off the device (or pull it from the simulator):

```bash
./pull.sh                       # session.json
# raw files:
xcrun simctl get_app_container booted ai.commandcode.food.capture data
#   -> <container>/tmp/{kroger,costco}-raw.json

# feed the pipeline (no Chrome, no server-side scraping):
uv run food import kroger-raw.json --retailer kroger
uv run food import costco-raw.json --retailer costco
uv run food classify && uv run food stock
```

## Notes / limits

- There's no cap: every receipt is itemized, one batch per page load (`receiptsPerLoad`), so a
  large history means many page reloads and a ~20 MB file (each receipt's details is ~180 KB).
- Kroger fetches via same-origin `fetch` on `www.kroger.com`; Costco's GraphQL is on
  `ecom-api.costco.com` and needs to run from the orders page for its Origin/CORS to be right
  — the app navigates there first.
- The app stores live session data in the simulator/web view; treat the captured session and
  the raw payloads as sensitive (they contain purchase history).
- Android equivalent: the same design works with `android.webkit.WebView` +
  `evaluateJavascript` / `addJavascriptInterface`; no browser-automation framework required.
