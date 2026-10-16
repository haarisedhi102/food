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
canonicalize.py   LLM: name, brand, category, unit, storage, FoodKeeper match
      ▼
shelflife.py      FoodKeeper value when matched, else the LLM's estimate
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

`OPENROUTER_API_KEY` is optional. Without it, FoodKeeper matching is keyword-only; with it,
`embed-ref` builds a semantic index and matching becomes hybrid (keyword + embeddings). The
default embedding model is free.

## Use

```bash
uv run food sync-ref                  # load the FoodKeeper shelf-life table (once)
uv run food embed-ref                 # embed it for hybrid search (once; needs OPENROUTER_API_KEY)
uv run food sync --retailer costco    # log in when Chrome opens (MFA)
uv run food sync --retailer kroger
uv run food classify                  # canonicalize new items (batched, parallel)
uv run food stock                     # build/refresh the fridge & pantry
uv run food status                    # counts, review queue, LLM calls today
uv run food digest                    # "use it or lose it" suggestions
uv run food serve                     # dashboard at http://127.0.0.1:8000
```

Refresh loop: `food sync && food classify && food stock`.

### Commands

| Command | What it does |
|---|---|
| `sync-ref` | (Re)load USDA FoodKeeper into `shelf_life_ref` |
| `embed-ref` | Embed FoodKeeper rows for hybrid (keyword + semantic) matching |
| `sync [--retailer …]` | Pull receipts via a real logged-in Chrome |
| `import <file.json> --retailer …` | Re-run the pipeline from a saved raw payload |
| `classify` | LLM canonicalization of unmapped items (parallel, cached by `item_key`) |
| `stock` | Build/refresh inventory and show what's expiring |
| `status` | Counts, needs-review, per-purpose LLM usage |
| `review` | List the needs-review queue |
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
- **Shelf life.** USDA FoodKeeper (public domain) is the reference table. Matching is split
  out from canonicalization: `reference.py` retrieves candidate rows with hybrid keyword +
  semantic search (embeddings from OpenRouter, fused by reciprocal rank), and the LLM maps the
  item onto them. When there's a clear match the table value wins, otherwise the LLM supplies
  an estimate in the same shape. Units are converted from FoodKeeper's `*_Metric`
  (Weeks/Months/…), and qualitative values ("Package use-by date") fall through to the LLM.
  Each product records `shelf_life_source` (foodkeeper / llm / manual).
- **Costs.** Classification runs on `xiaomi/mimo-v2.6-flash` (won a head-to-head benchmark:
  30/30 valid items in 52s vs 89s and 121s) with cheaper/free fallbacks. Batches run 6-wide.
  Chat and digest are cached and budgeted separately so they can't starve classification.
- **Consumption.** Receipts say what you bought, not what's left. Inventory decays: rows
  expire at `acquired_on + shelf_life_days`, repeat purchases decrement oldest-first, and
  long-dead rows archive automatically. Mark items used/tossed from the dashboard to keep it
  honest.

## Privacy

`data/` holds session cookies, raw receipts and purchase history. It is gitignored — keep it
out of synced backups. The dashboard binds `127.0.0.1` only and has no auth.

## Attribution

Shelf-life guidance: USDA FoodKeeper (public domain).
