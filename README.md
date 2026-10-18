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
uv run food sync-ref                  # load the FoodKeeper shelf-life table (once)
uv run food embed-ref                 # embed it for hybrid search (once; needs OPENROUTER_API_KEY)
uv run food sync --retailer costco    # log in when Chrome opens (MFA)
uv run food sync --retailer kroger
uv run food classify                  # canonicalize + resolve each item's shelf life
uv run food stock                     # build/refresh the fridge & pantry
uv run food status                    # counts, LLM calls today
uv run food digest                    # "use it or lose it" suggestions
uv run food serve                     # dashboard at http://127.0.0.1:8000
```

Refresh loop: `food sync && food classify && food stock`.

### Commands

| Command | What it does |
|---|---|
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

## Privacy

`data/` holds session cookies, raw receipts and purchase history. It is gitignored — keep it
out of synced backups. The dashboard binds `127.0.0.1` only and has no auth.

## Attribution

Shelf-life guidance: USDA FoodKeeper (public domain).
