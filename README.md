# Virtual Fridge & Pantry

Track your Kroger and Costco purchases, and know what's about to go bad.

Receipts are pulled through a real logged-in browser, reconciled by an LLM into one grocery
schema, grounded against USDA FoodKeeper, and turned into a decaying fridge / freezer / pantry.
The same pipeline runs in the Python CLI + dashboard and on-device in the macOS/iOS app.

## How it works

```
real browser session (Playwright profile, or the app's WKWebView)
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

The mobile app runs the same stages on-device (`FoodCore`); Rust `Rig` owns only LLM,
embedding and Jev transport.

**Keying.** `item_map` is keyed on the retailer's own stable id — Costco `itemNumber`,
Kroger `upc` — never the description. Each product is canonicalized exactly once and reused
across every receipt, including repeat purchases.

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
embeddings). The default embedding model is `baai/bge-base-en-v1.5`.

### Tracing (optional)

Watch every LLM call (canonicalization, shelf-life resolution, chat) in a local
[Arize Phoenix](https://arize.com/docs/phoenix) UI. Off unless `PHOENIX_ENABLED=1`:

```bash
uv sync --group tracing               # one-time: Phoenix server + OpenInference instrumentors
uv run phoenix serve                  # UI at http://localhost:6006
PHOENIX_ENABLED=1 uv run food classify
```

`PHOENIX_PROJECT` names the project (default `food`); set `PHOENIX_COLLECTOR_ENDPOINT` to
ship to Phoenix Cloud instead of the local server. The app emits the same `gen_ai.*` spans
into the same project.

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

`bootstrap` and `refresh` open a real Chrome to sync receipts, so neither is fully
unattended: log in once (MFA) and the persistent profile is reused. On an interval, prefer
`food refresh` — it only pulls what's new.

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
| `resolve [--refresh] [--ids …] [--limit N]` | Fill shelf-life gaps and re-resolve flagged items; `--refresh` also re-resolves unpinned values |
| `shelf-life <product_id> --days N [--opened N]` | Pin a shelf life; it applies to every future purchase |
| `review <product_id> [--clear]` | Flag a product as wrong (re-resolved on the next pass), or clear the flag |
| `stock` | Build/refresh inventory and show what's expiring |
| `status` | Counts and per-purpose LLM usage |
| `digest` | LLM "use it or lose it" plan |
| `serve` | Dashboard (binds `127.0.0.1`) |
| `probe-kroger` | Diagnostic for the Kroger details endpoint |

## Design notes

- **Fronted retailers.** Both receipt endpoints reject headless HTTP clients, so calls run
  inside a real browser with a persistent profile. Log in once (MFA included); the session is
  reused. `sync` is therefore not fully unattended, and the edge throttles per IP — the clients
  stop at the first `429`/`403` rather than retrying.
- **Unofficial APIs.** Costco uses its internal GraphQL (`receiptsWithCounts`), Kroger its
  `atlas` purchase-history endpoints. Raw JSON is archived in `data/imports/`, so a changed
  field needs a re-normalize, not a re-scrape. `food import` is the escape hatch when a
  scraper breaks.
- **Shelf life.** USDA FoodKeeper is the reference table but only a *hint*: its figures can be
  unrealistic, so the model supplies the final number. `resolve.py` runs per chunk:
  `reference.py` retrieves a shortlist with hybrid keyword + semantic search (RRF; embeddings
  from OpenRouter), then (1) a tool-calling agent researches it — searching the web only where
  no row fits — and (2) a forced structured-output call produces one verdict per item. Each
  product records `shelf_life_source` (`foodkeeper` / `web` / `llm` / `jev` / `user`).
- **User overrides.** A value set with `shelf-life` (or the app's item page) is stored with
  `source=user` and is sticky: automatic passes leave it alone, and future purchases inherit
  it. `review` flags a product so the next resolve pass redoes it; a successful verdict clears
  the flag. `--refresh` re-resolves every food item except pinned values unless flagged.
- **Costs.** Classification runs on `xiaomi/mimo-v2.6-flash` with cheaper/free fallbacks.
  Batches run 6-wide. Chat and digest are cached and budgeted separately so they can't starve
  classification.
- **LLM plumbing.** Built on LangChain: each model is a `ChatOpenAI` runnable wrapped with
  `.with_retry` and chained with `.with_fallbacks`, classification batches fan out through
  `.batch(max_concurrency=…)`, FoodKeeper retrieval is an `EnsembleRetriever` (lexical +
  embeddings), and the resolver's synthesis step uses `with_structured_output`.
- **Consumption.** Receipts say what you bought, not what's left. Rows expire at
  `acquired_on + shelf_life_days`, repeat purchases consume oldest-first, and long-dead rows
  archive automatically. Mark items used/tossed from the dashboard to keep it honest.

## Mobile app (macOS / iOS)

`mobile/ios/` is a native SwiftUI app that runs the whole pipeline on-device — no server.

- The in-app `WKWebView` logs into the retailer and fetches receipts from inside the page, then
  hands the raw payloads to `FoodCore`. Same-origin fetch is what keeps the authenticated
  session intact.
- **Kitchen** leads with *Use soon*, then one section per shelf; rows show quantity and a
  relative date, with used/tossed swipe actions and an item detail (shelf life, source, price
  history, stock).
- **Shelf life** on the item detail has a day stepper, **Save shelf life** (pins the value) and
  **Mark as wrong** (queues a re-resolve). The Kitchen gains a **Needs review** section with a
  single **Re-resolve N flagged items** action.
- **Sync receipts** opens the browser; **Import…** accepts an archived payload for offline
  reproduction (e.g. a file from `data/receipts/`).

```bash
cd mobile/ios
./run-mac.sh    # native macOS app
./run.sh        # boot a simulator first; builds, installs, launches
```

See [`mobile/ios/README.md`](mobile/ios/README.md) for build details, keys and visual checks.

## Privacy

`data/` holds session cookies, raw receipts and purchase history. It is gitignored — keep it
out of synced backups. The dashboard binds `127.0.0.1` only and has no auth.

## Attribution

Shelf-life guidance: USDA FoodKeeper (public domain).
