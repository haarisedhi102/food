# Data model and flow

The Python schema in `food/db.py` is the source of truth. The iOS app carries an identical
schema in `mobile/ios/FoodCore/Sources/FoodCore/Schema.swift`, so both pipelines write the same
tables and run the same stages.

## ER diagram

```mermaid
erDiagram
    RECEIPTS ||--o{ RECEIPT_ITEMS : "has line items"
    PRODUCTS ||--o{ ITEM_MAP : "canonical identity"
    ITEM_MAP ||--o{ RECEIPT_ITEMS : "logical join (retailer + item_key)"
    PRODUCTS ||--o{ INVENTORY : "stocked as"
    RECEIPT_ITEMS ||--o| INVENTORY : "becomes at most one"
    SHELF_LIFE_REF ||--o| SHELF_LIFE_EMBEDDING : "vector index"
    PRODUCTS }o..o{ SHELF_LIFE_REF : "matched during resolve (no FK)"

    RECEIPTS {
        int id PK
        text retailer "costco | kroger"
        text external_id "receiptKey / transactionBarcode"
        text purchased_on "YYYY-MM-DD"
        text store
        int total_cents
        text raw_json
        text pulled_at
    }

    RECEIPT_ITEMS {
        int id PK
        int receipt_id FK
        text raw_description
        text item_key "UPC or fallback key"
        text raw_pkg_size
        real quantity
        int unit_price_cents
        int line_total_cents
    }

    PRODUCTS {
        int id PK
        text canonical_name
        text brand
        text category
        text pkg_size
        text unit
        int is_food
        int is_perishable
        text storage "fridge | freezer | pantry | counter"
        int shelf_life_days
        int shelf_life_days_opened
        text shelf_life_source "foodkeeper | web | llm"
        text llm_model
        real llm_confidence
        text classified_at
    }

    ITEM_MAP {
        int id PK
        text retailer
        text item_key
        text raw_description
        int product_id FK
    }

    INVENTORY {
        int id PK
        int product_id FK
        real quantity
        real remaining_qty
        text unit
        text acquired_on
        text expires_on
        text location
        text status "active | partial | expired | consumed | tossed | archived"
        int source_receipt_item_id FK "UNIQUE"
    }

    SHELF_LIFE_REF {
        int foodkeeper_id PK
        text name
        text subtitle
        text category
        text keywords
        int pantry_days
        int dop_refrigerate_days
        int refrigerate_after_opening_days
        int dop_freeze_days
        text raw_json
    }

    SHELF_LIFE_EMBEDDING {
        int foodkeeper_id PK "FK -> shelf_life_ref"
        text model
        int dim
        blob vector
        text created_at
    }

    PROMPT_CACHE {
        text cache_key PK
        text response_json
        text created_at
    }

    LLM_CALLS {
        int id PK
        text purpose
        text model
        int prompt_tokens
        int completion_tokens
        text created_at
    }
```

## Data flow

```mermaid
flowchart TD
    A["Retailer site<br/>Playwright Chrome / WKWebView"] -->|raw JSON| B["data/imports/*.json"]
    B --> C["normalize.py<br/>per-retailer parser"]
    C --> D[("receipts")]
    C --> E[("receipt_items")]

    E --> F{"pending()<br/>retailer+item_key<br/>missing from item_map?"}
    F -->|yes| G["LLM canonicalize<br/>(batch of 30)"]
    G --> H[("products")]
    G --> I[("item_map")]

    H --> J["resolve.py<br/>research + forced synthesis"]
    K[("shelf_life_ref")] --> J
    L[("shelf_life_embedding")] --> J
    M["web_search"] --> J
    J -->|UPDATE shelf_life_*| H
    J -->|UPDATE expires_on| N

    E --> O["inventory.build()"]
    H --> O
    I --> O
    O --> N[("inventory")]

    N --> P["Dashboard / Kitchen tab"]
    H --> P

    G -.-> Q[("llm_calls")]
    J -.-> Q
    G -.-> R[("prompt_cache")]
    J -.-> R
```

## Stage by stage

| Stage | Reads | Writes | Key rule |
|---|---|---|---|
| Fetch | Retailer API via browser | `data/imports/*.json` | Raw archive; browser profile lives outside SQLite |
| Normalize | Raw JSON | `receipts`, `receipt_items` | `UNIQUE(retailer, external_id)` makes re-pulls idempotent |
| Canonicalize | `receipt_items` LEFT JOIN `item_map` | `products`, `item_map` | One product per `(retailer, item_key)`; unseen keys only |
| Resolve | `products`, `shelf_life_ref`, embeddings, web | `products.shelf_life_*`, `inventory.expires_on` | No FK to reference; values are copied, `shelf_life_source` records provenance |
| Inventory | `receipt_items` + `receipts` + `item_map` + `products` | `inventory` | One row per receipt line; `expires_on = purchased_on + shelf_life_days` only when perishable |
| Consumption | `inventory` | `inventory.remaining_qty/status` | FIFO oldest expiry first; active → partial → consumed/tossed; expired → archived after `ARCHIVE_AFTER_DAYS` |
| Read/UI | `inventory` JOIN `products`; details JOIN `receipt_items`→`receipts` | — | Dashboard never writes, only status actions do |

## The relationships that matter

- `receipts` → `receipt_items`: 1-to-many, `ON DELETE CASCADE`.
- `item_map`: the bridge table. Its unique `(retailer, item_key)` is what lets `receipt_items`
  join to `products`; that join is **logical, not a declared FK**.
- `products` → `inventory`: 1-to-many. Repeat purchases create separate inventory rows, not
  quantity updates.
- `receipt_items` → `inventory`: 1-to-0..1, enforced by `UNIQUE(source_receipt_item_id)`.
- `shelf_life_ref` → `shelf_life_embedding`: 1-to-0..1, cascade delete.
- `products` ↔ `shelf_life_ref`: *no stored relationship*. The resolver uses the reference at
  runtime and copies the answer into `products`; `foodkeeper_id` was deliberately dropped from
  `products`.
- `prompt_cache` (cache key → JSON) and `llm_calls` (audit/budget log) are standalone side
  tables, not part of the kitchen graph.
- `schema_version` is a single-row migration marker (currently 2).

## Mental model

`receipts` is **what you bought**, `products` is **what it is**, `item_map` is **how retailer
SKUs resolve to products**, and `inventory` is **what is still in your kitchen**. The only
mutable state after ingestion is `inventory.remaining_qty/status` and the shelf-life columns on
`products`; everything else is append/upsert.

The iOS app runs the exact same schema and the same stages in `Sync.run` (fetch in `WebModel` →
`Store` → `Canonicalize` → `ShelfLifeAgent` → `Inventory`), just against the on-device SQLite
file.
