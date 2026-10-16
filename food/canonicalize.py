"""LLM canonicalization: reconcile Kroger and Costco line items into one product schema.

Both retailers flow through a single prompt and a single output schema, so their structural
differences disappear at the boundary. Results are cached per (retailer, item_key) in
`item_map`, so each product is canonicalized exactly once.

Naming and reference matching are separate stages: this module decides what an item *is*
(canonical name, category, storage, and a shelf-life estimate); `reference.match` then
grounds that readable name in a FoodKeeper row. Matching the canonical name instead of the
raw receipt code is worth ~0.1 recall@1 — see `bench/retrieval_bench.py`.
"""

from __future__ import annotations

import json
import sqlite3
from typing import Any

from langchain_core.runnables import RunnableLambda
from pydantic import ValidationError

from . import config, db, llm, reference, shelflife
from .models import CanonicalItem

BATCH_SIZE = 30
SYSTEM = """You normalize grocery receipt line items into canonical product records.
You will receive items from Costco (heavily abbreviated, e.g. "KS ORG A2 PR") and Kroger
(readable, e.g. "Horizon Organic Whole Milk"). Return ONE object per item, keyed by item_key.

For each item return exactly these fields:
  item_key (string, echo the input), canonical_name (string),
  brand (string or null), category (string or null),
  pkg_size (string or null, e.g. "1/2 gal", "16 oz"),
  unit ("count" | "weight" | "volume" or null),
  is_food (bool), is_perishable (bool),
  storage ("fridge" | "freezer" | "pantry" | "counter"),
  shelf_life_days (int or null), shelf_life_days_opened (int or null),
  confidence (0.0-1.0).

Rules:
- Write canonical_name as the plain, readable product name (expand abbreviations).
- If is_perishable is true, shelf_life_days is REQUIRED (whole days, never null) — give
  your best estimate.
- Non-perishable items (coffee, rice, canned goods, spices, oil) may set shelf_life_days
  null; they do not expire.
- Fresh bakery, deli, refrigerated, meat, seafood, produce, dairy and prepared foods are
  is_perishable=true with a shelf life, even when a shelf-stable version of the product
  exists (dry pasta and packaged cookies keep for months; fresh bread, naan, and
  refrigerated crusts do not).
- Non-food items (apparel, housewares, electronics, flowers, tobacco) get is_food=false,
  is_perishable=false, and shelf_life_days null.
- If you are unsure, lower confidence rather than guessing wildly.

Examples:
  "KS ORG A2 PR"      -> {"canonical_name":"Organic A2 Milk","brand":"Kirkland Signature","category":"Dairy Products & Eggs","pkg_size":"1/2 gal","unit":"volume","is_food":true,"is_perishable":true,"storage":"fridge","shelf_life_days":7,"confidence":0.8}
  "KS COLMBIAN"       -> {"canonical_name":"Colombian Coffee","brand":"Kirkland Signature","category":"Beverages","pkg_size":null,"unit":"count","is_food":true,"is_perishable":false,"storage":"pantry","shelf_life_days":null,"confidence":0.75}
  "PASTURE EGGS"      -> {"canonical_name":"Pasture-Raised Eggs","brand":null,"category":"Dairy Products & Eggs","pkg_size":null,"unit":"count","is_food":true,"is_perishable":true,"storage":"fridge","shelf_life_days":21,"confidence":0.8}
  "MWCHINOPANT"       -> {"canonical_name":"Apparel","brand":null,"category":null,"pkg_size":null,"unit":"count","is_food":false,"is_perishable":false,"storage":"pantry","shelf_life_days":null,"confidence":0.6}
  "SHRIMP 31/40"      -> {"canonical_name":"Shrimp","brand":null,"category":"Seafood","pkg_size":null,"unit":"weight","is_food":true,"is_perishable":true,"storage":"freezer","shelf_life_days":180,"confidence":0.7}
  "WW SANDWICH BREAD" -> {"canonical_name":"Whole Wheat Sandwich Bread","brand":null,"category":"Bakery","pkg_size":null,"unit":"count","is_food":true,"is_perishable":true,"storage":"counter","shelf_life_days":7,"confidence":0.8}
  "CAULIFLOWER CRUST" -> {"canonical_name":"Cauliflower Pizza Crusts","brand":null,"category":"Bakery","pkg_size":null,"unit":"count","is_food":true,"is_perishable":true,"storage":"fridge","shelf_life_days":21,"confidence":0.7}
  "NAAN DIPPERS"      -> {"canonical_name":"Naan Dippers","brand":null,"category":"Bakery","pkg_size":null,"unit":"count","is_food":true,"is_perishable":true,"storage":"pantry","shelf_life_days":5,"confidence":0.75}
  "ORG ORANGE JUICE"  -> {"canonical_name":"Orange Juice","brand":null,"category":"Beverages","pkg_size":"1/2 gal","unit":"volume","is_food":true,"is_perishable":true,"storage":"fridge","shelf_life_days":10,"confidence":0.8}
  "PACKAGED COOKIES"  -> {"canonical_name":"Packaged Cookies","brand":null,"category":"Snacks","pkg_size":null,"unit":"count","is_food":true,"is_perishable":false,"storage":"pantry","shelf_life_days":null,"confidence":0.75}
  "JASMINE RICE"      -> {"canonical_name":"Jasmine Rice","brand":null,"category":"Pantry Staples","pkg_size":null,"unit":"weight","is_food":true,"is_perishable":false,"storage":"pantry","shelf_life_days":null,"confidence":0.85}
  "CLOVER HONEY"      -> {"canonical_name":"Honey","brand":null,"category":"Condiments & Sauces","pkg_size":null,"unit":"count","is_food":true,"is_perishable":false,"storage":"pantry","shelf_life_days":null,"confidence":0.85}

Respond with ONLY JSON: {"items": [ ... ]}"""


def pending(conn: sqlite3.Connection, limit: int | None = None) -> list[dict]:
    """Distinct items seen on receipts that have no product mapping yet."""
    sql = """
        SELECT ri.item_key AS item_key, r.retailer AS retailer,
               MAX(ri.raw_description) AS raw_description,
               MAX(ri.raw_pkg_size) AS raw_pkg_size
        FROM receipt_items ri
        JOIN receipts r ON r.id = ri.receipt_id
        LEFT JOIN item_map m ON m.retailer = r.retailer AND m.item_key = ri.item_key
        WHERE m.id IS NULL
        GROUP BY r.retailer, ri.item_key
        ORDER BY COUNT(*) DESC
    """
    if limit:
        sql += f" LIMIT {int(limit)}"
    return [dict(r) for r in conn.execute(sql)]


def pending_count(conn: sqlite3.Connection) -> int:
    row = conn.execute(
        """
        SELECT COUNT(*) n FROM (
            SELECT r.retailer, ri.item_key
            FROM receipt_items ri
            JOIN receipts r ON r.id = ri.receipt_id
            LEFT JOIN item_map m ON m.retailer = r.retailer AND m.item_key = ri.item_key
            WHERE m.id IS NULL
            GROUP BY r.retailer, ri.item_key
        )
        """
    ).fetchone()
    return row["n"]


def _build_user(items: list[dict]) -> str:
    payload = [
        {
            "item_key": it["item_key"],
            "retailer": it["retailer"],
            "raw_description": it["raw_description"],
            "pkg_size_hint": it.get("raw_pkg_size"),
        }
        for it in items
    ]
    return json.dumps({"items": payload}, ensure_ascii=False)


def _store(conn: sqlite3.Connection, retailer: str, item: dict, ci: CanonicalItem) -> int:
    # Shelf life starts as the model's estimate; FoodKeeper grounding happens afterwards
    # in `_ground`, once the whole batch is stored, so it can be done in one rerank call.
    days = ci.shelf_life_days
    source = "llm" if days is not None else None

    cur = conn.execute(
        """INSERT INTO products
           (canonical_name, brand, category, pkg_size, unit, is_food, is_perishable, storage,
            shelf_life_days, shelf_life_days_opened, shelf_life_source, foodkeeper_id,
            llm_model, llm_confidence, classified_at)
           VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,datetime('now'))""",
        (
            ci.canonical_name,
            ci.brand,
            ci.category,
            ci.pkg_size,
            ci.unit,
            int(ci.is_food),
            int(ci.is_perishable),
            ci.storage,
            days,
            ci.shelf_life_days_opened,
            source,
            None,
            llm.config.MODEL,
            ci.confidence,
        ),
    )
    conn.execute(
        """INSERT OR IGNORE INTO item_map (retailer, item_key, raw_description, product_id)
           VALUES (?, ?, ?, ?)""",
        (retailer, item["item_key"], item.get("raw_description"), cur.lastrowid),
    )
    return cur.lastrowid


def _ground(conn: sqlite3.Connection, stored: list[tuple[int, str, str]]) -> None:
    """Ground stored products in FoodKeeper: hybrid shortlist per name, one batched rerank."""
    if not stored:
        return
    picks = reference.match_batch(conn, [name for _, name, _ in stored])
    for pid, name, storage in stored:
        fid = picks.get(name)
        if fid is None:
            continue
        days = shelflife.days_for(conn, fid, storage)
        if days is None:
            continue
        conn.execute(
            """UPDATE products
               SET foodkeeper_id = ?, shelf_life_days = ?, shelf_life_source = 'foodkeeper'
               WHERE id = ?""",
            (fid, days, pid),
        )
    conn.commit()


def _fallback(conn: sqlite3.Connection, retailer: str, item: dict) -> None:
    """A model output we couldn't parse: keep the pipeline moving with a placeholder row."""
    cur = conn.execute(
        """INSERT INTO products (canonical_name, is_food, is_perishable, llm_confidence)
           VALUES (?, 1, 0, 0.0)""",
        (item.get("raw_description") or item["item_key"],),
    )
    conn.execute(
        """INSERT OR IGNORE INTO item_map (retailer, item_key, raw_description, product_id)
           VALUES (?, ?, ?, ?)""",
        (retailer, item["item_key"], item.get("raw_description"), cur.lastrowid),
    )


def _call_batch(payload: tuple[list[dict], str]) -> tuple[list[dict], dict]:
    """Runs in a LangChain worker thread, so it needs its own connection."""
    batch, user = payload
    wc = db.connect()
    try:
        return batch, llm.chat_json(wc, "canonicalize", SYSTEM, user)
    except Exception as e:  # noqa: BLE001 - degrade to the review queue
        print(f"    canonicalize call failed: {e}")
        return batch, {"items": []}
    finally:
        wc.close()


def _apply(
    conn: sqlite3.Connection, batch: list[dict], data: dict, stats: dict
) -> list[dict]:
    by_key: dict[str, Any] = {}
    for raw in data.get("items", []) or []:
        if isinstance(raw, dict) and raw.get("item_key") is not None:
            by_key[str(raw["item_key"])] = raw

    failed = []
    stored: list[tuple[int, str, str]] = []
    for item in batch:
        raw = by_key.get(str(item["item_key"]))
        if raw is None:
            failed.append(item)
            continue
        try:
            ci = CanonicalItem(**raw)
        except ValidationError:
            failed.append(item)
            continue
        pid = _store(conn, item["retailer"], item, ci)
        stored.append((pid, ci.canonical_name, ci.storage or "fridge"))
        stats["ok"] += 1
    conn.commit()
    _ground(conn, stored)
    return failed


def canonicalize(
    conn: sqlite3.Connection, limit: int | None = None, workers: int | None = None
) -> dict[str, int]:
    """Canonicalize pending items. Batches run concurrently; each product is cached in
    `item_map`, so re-running only touches items that failed."""
    workers = workers or config.CLASSIFY_WORKERS
    stats = {"batches": 0, "ok": 0, "fallback": 0}
    items = pending(conn, limit)
    if not items:
        return stats
    call = RunnableLambda(_call_batch)

    def run(batches: list[list[dict]]) -> list[tuple[list[dict], dict]]:
        # prompts are built in the main thread
        work = [(b, _build_user(b)) for b in batches]
        return call.batch(work, config={"max_concurrency": workers})

    batches = [items[i : i + BATCH_SIZE] for i in range(0, len(items), BATCH_SIZE)]
    failed: list[dict] = []
    for batch, data in run(batches):
        stats["batches"] += 1
        failed += _apply(conn, batch, data, stats)

    if failed:  # one retry for everything that came back malformed or missing
        retry = [failed[i : i + BATCH_SIZE] for i in range(0, len(failed), BATCH_SIZE)]
        still: list[dict] = []
        for batch, data in run(retry):
            still += _apply(conn, batch, data, stats)
        for item in still:
            _fallback(conn, item["retailer"], item)
            stats["fallback"] += 1
        conn.commit()

    return stats
