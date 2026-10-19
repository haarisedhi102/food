# Virtual Fridge & Pantry

Track your Kroger and Costco purchases, and know what's about to go bad.

Pulls your receipts from both retailers through a real logged-in Chrome, uses an LLM to
reconcile their very different line-item formats into one canonical grocery schema, grounds
shelf life in the USDA FoodKeeper dataset, and builds a decaying fridge / freezer / pantry
you can query.

## How it works

```
real Chrome (Playwright, persistent profile)
      │  fetch() inside the page, so requests carry your real cookies + TLS
      ▼
ingest/costco.py · ingest/kroger.py ──► data/imports/*.json  (raw, archived)
      ▼
normalize.py      deterministic per-retailer adapters → provisional records
      ▼
canonicalize.py   LLM: name, brand, category, unit, storage, is_food, is_perishable
      ▼
resolve.py        shortlist each item in FoodKeeper, then a research agent + one forced
                  structured synthesis call → shelf life + source
      ▼
inventory.py      expires_on, remaining qty, FIFO consumption, auto-archive
      ▼
web/app.py        dashboard: shelves, expiring soon, price history, chat
```

**Keying.** `item_map` is keyed on the retailer's own stable id — Costco `itemNumber`,
Kroger `upc` — never the description (the least stable field). Each product is canonicalized
exactly once and reused across every receipt.

## Setup

```bash
uv sync
uv run playwright install chrome      # uses your installed Google Chrome
cp .env.example .env                  # then set CMD_API_KEY
```

`CMD_API_KEY` comes from Command Code Studio → API keys, and is used against the provider
endpoint `https://api.commandcode.ai/provider/v1`.

`OPENROUTER_API_KEY` is optional. Without it, FoodKeeper candidate search is keyword-only;
with it, `embed-ref` builds a semantic index and search becomes hybrid (keyword +
embeddings). The default embedding model is a cheap paid one (`baai/bge-base-en-v1.5`).

### Tracing (optional)

Watch every LLM call (canonicalization, shelf-life resolution, chat) in a local
[Arize Phoenix](https://arize.com/docs/phoenix) UI. Off unless `PHOENIX_ENABLED=1`:

```bash
uv sync --group tracing               # one-time: Phoenix server + OpenInference instrumentors
uv run phoenix serve                  # UI at http://localhost:6006
PHOENIX_ENABLED=1 uv run food classify
```

`PHOENIX_PROJECT` names the project (default `food`); set `PHOENIX_COLLECTOR_ENDPOINT` to
ship to Phoenix Cloud instead of the local server. Instrumentation is automatic, so both
the OpenAI client and the LangChain stack are traced.

## Use

```bash
# Fresh setup in one shot: FoodKeeper reference + `--days` of receipts + classify + inventory.
uv run food bootstrap --days 90        # add --serve to open the dashboard when it finishes

# Incremental update — safe to re-run on an interval (cron / launchd / systemd timer).
uv run food refresh

uv run food serve                      # dashboard at http://127.0.0.1:8000
uv run food status                     # counts, LLM calls today
uv run food digest                     # "use it or lose it" suggestions
```

`bootstrap` and `refresh` both open a real Chrome to sync receipts, so neither is fully
unattended: log in once (MFA) and the persistent profile is reused. On an interval, prefer
`food refresh` (sync + classify + stock) — it only pulls what's new.

The steps are also available individually:

```bash
uv run food sync-ref                   # load the FoodKeeper shelf-life table (once)
uv run food embed-ref                  # embed it for hybrid search (once; needs OPENROUTER_API_KEY)
uv run food sync --retailer costco     # log in when Chrome opens (MFA)
uv run food classify                   # canonicalize + resolve each item's shelf life
uv run food stock                      # build/refresh the fridge & pantry
```

### Commands

| Command | What it does |
|---|---|
| `bootstrap [--days N] [--skip-ref] [--serve]` | Fresh setup: reference + N days of receipts + classify + stock |
| `refresh [--lookback N] [--serve]` | Incremental sync + classify + stock, for an interval |
| `sync-ref` | (Re)load USDA FoodKeeper into `shelf_life_ref` |
| `embed-ref` | Embed FoodKeeper rows for hybrid (keyword + semantic) search |
| `sync [--retailer …]` | Pull receipts via a real logged-in Chrome |
| `import <file.json> --retailer …` | Re-run the pipeline from a saved raw payload |
| `classify` | Canonicalize unmapped items and resolve each item's shelf life (batched, cached) |
| `resolve [--refresh] [--ids …] [--limit N]` | (Re)resolve shelf lives for stored products; default fills only the gaps |
| `stock` | Build/refresh inventory and show what's expiring |
| `status` | Counts and per-purpose LLM usage |
| `digest` | LLM "use it or lose it" plan |
| `serve` | Dashboard (binds `127.0.0.1`) |
| `probe-kroger` | Diagnostic for the Kroger details endpoint |

## Design notes

- **Akamai.** Both retailers drop non-browser TLS fingerprints and reject headless. So every
  API call runs *inside* a real headed Chrome with a persistent profile, via `page.evaluate`.
  You log in once (MFA included); the session is reused afterwards. `sync` is therefore **not
  fully unattended**.
- **Unofficial APIs.** Costco uses its internal GraphQL (`receiptsWithCounts`), Kroger its
  `atlas` purchase-history endpoints. Raw JSON is archived in `data/imports/`, so a changed
  field needs a re-normalize, not a re-scrape. `food import` is the escape hatch when a
  scraper breaks.
- **Shelf life.** USDA FoodKeeper (public domain) is the reference table, but it is a *hint, not
  the authority*: its figures can be unrealistic (a milk row listing only a freezer value), so
  the model supplies the final number. `resolve.py` runs per chunk of items: `reference.py`
  retrieves each item's shortlist with hybrid keyword + semantic search (RRF; embeddings from
  OpenRouter), then (1) a tool-calling agent researches it — searching the web only where no row
  fits — and (2) a forced structured-output call turns the notes into one verdict per item (the
  schema is the only tool bound, so the model cannot answer in prose). Each product records
  `shelf_life_source` (foodkeeper / web / llm); units are converted from FoodKeeper's `*_Metric`
  (Weeks/Months/…), and qualitative values fall through to the model. The retriever alone is
  benchmarked in `bench/retrieval_bench.py`.
- **Costs.** Classification runs on `xiaomi/mimo-v2.6-flash` (won a head-to-head benchmark:
  30/30 valid items in 52s vs 89s and 121s) with cheaper/free fallbacks. Batches run 6-wide.
  Chat and digest are cached and budgeted separately so they can't starve classification.
- **LLM plumbing.** Built on LangChain: each model is a `ChatOpenAI` runnable wrapped with
  `.with_retry` and chained with `.with_fallbacks`, classification batches fan out through
  `.batch(max_concurrency=…)`, FoodKeeper retrieval is an `EnsembleRetriever` (lexical +
  embeddings), and the resolver's synthesis step uses `with_structured_output`.
- **Consumption.** Receipts say what you bought, not what's left. Inventory decays: rows
  expire at `acquired_on + shelf_life_days`, repeat purchases decrement oldest-first, and
  long-dead rows archive automatically. Mark items used/tossed from the dashboard to keep it
  honest.

## Client-assisted ingest (mobile POC)

Akamai doesn't only guard the *login* — it guards the *fetch*. Measured against the real
endpoints, no headless HTTP client gets through Kroger's `purchase-history/v2/details`:
`curl_cffi` (even with a Chrome TLS/JA3 + HTTP/2 fingerprint) has its HTTP/2 stream **reset**,
and `node-libcurl` (with an explicit Akamai HTTP/2 fingerprint) fails in the framing layer —
while the *very same request* from a real WebKit engine returns **200**. Akamai validates its
`_abck` bot cookie against the browser's fingerprint, which no non-browser client reproduces.

So the portable answer is to move the browser engine to the **client** and keep the server
browser-free: the phone logs in and fetches, and hands the server raw payloads that the
existing `food import` consumes unchanged.

`mobile/ios/` is a SwiftUI POC that does exactly this. Its in-app `WKWebView` (a real WebKit
engine, the same reason Google and Meta ship their own in-app browser) fetches the full
history, then:

```bash
uv run food import kroger-raw.json --retailer kroger   # → 123 receipts, 1026 items
uv run food import costco-raw.json --retailer costco   # →   4 receipts,   46 items
```

One quirk worth knowing: the details endpoint allows only ~1 batch per **page load** before it
drops connections, and retries don't recover it — the app itemizes in chunks, reloading the
page between them to re-arm the sensor (`loads=13 detailsOk=13 errors=0`). See
[`mobile/ios/README.md`](mobile/ios/README.md); the same design ports to Android WebView.

## Privacy

`data/` holds session cookies, raw receipts and purchase history. It is gitignored — keep it
out of synced backups. The dashboard binds `127.0.0.1` only and has no auth.

## Attribution

Shelf-life guidance: USDA FoodKeeper (public domain).
