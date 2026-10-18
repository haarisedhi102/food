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
search=157 keys=123 loads=13 detailsOk=13 errors=0 retries=0
→ food import kroger-raw.json --retailer kroger
→ kroger: 123 receipts, 123 new, 1026 new items
```

`receiptsPerLoad` / `attempts` in `WebModel.swift` tune the chunk size and retry budget.

## Build & run

Needs Xcode + [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
# boot a simulator first, e.g.:
xcrun simctl boot "iPhone 17 Pro" && open "$(xcode-select -p)/../Applications/DeviceHub.app"
./run.sh            # generate project, build, install, launch
```

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
