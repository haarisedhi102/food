"""LLM canonicalization: reconcile Kroger and Costco line items into one product schema.

Both retailers flow through a single prompt and a single output schema, so their structural
differences disappear at the boundary. Results are cached per (retailer, item_key) in
`item_map`, so each product is canonicalized exactly once.

Naming and shelf-life resolution are separate stages: this module decides what an item *is*
(canonical name, category, storage, and a shelf-life estimate); `resolve.resolve_batch` then
grounds that readable name in FoodKeeper (or the web) in one batched agent run. Matching the
canonical name instead of the raw receipt code is worth ~0.1 recall@1 — see
`bench/retrieval_bench.py`.
"""

from __future__ import annotations

import json
import math
import sqlite3
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Any

from pydantic import ValidationError

from . import config, db, llm, resolve
from .models import CanonicalItem

BATCH_SIZE = 30
# When there are fewer full batches than workers, split them so the provider concurrency
# is actually used. 10 was the best split in the benchmark (3x10 beat 1x30 and 6x5).
MIN_BATCH_SIZE = 10
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
  confidence (0.0-1.0).

Shelf life is resolved in a later stage — do not estimate it here.

Rules:
- Write canonical_name as the plain, readable product name (expand abbreviations).
- Fresh bakery, deli, refrigerated, meat, seafood, produce, dairy and prepared foods are
  is_perishable=true, even when a shelf-stable version of the product exists (dry pasta and
  packaged cookies are shelf-stable; fresh bread, naan and refrigerated crusts are not).
- Non-perishable items (coffee, rice, canned goods, spices, oil) are is_perishable=false;
  they do not expire.
- Non-food items (apparel, housewares, electronics, flowers, tobacco) get is_food=false,
  is_perishable=false.
- If you are unsure, lower confidence rather than guessing wildly.

Examples:
  "KS ORG A2 PR"      -> {"canonical_name":"Organic A2 Milk","brand":"Kirkland Signature","category":"Dairy Products & Eggs","pkg_size":"1/2 gal","unit":"volume","is_food":true,"is_perishable":true,"storage":"fridge","confidence":0.8}
  "KS COLMBIAN"       -> {"canonical_name":"Colombian Coffee","brand":"Kirkland Signature","category":"Beverages","pkg_size":null,"unit":"count","is_food":true,"is_perishable":false,"storage":"pantry","confidence":0.75}
  "PASTURE EGGS"      -> {"canonical_name":"Pasture-Raised Eggs","brand":null,"category":"Dairy Products & Eggs","pkg_size":null,"unit":"count","is_food":true,"is_perishable":true,"storage":"fridge","confidence":0.8}
  "MWCHINOPANT"       -> {"canonical_name":"Apparel","brand":null,"category":null,"pkg_size":null,"unit":"count","is_food":false,"is_perishable":false,"storage":"pantry","confidence":0.6}
  "SHRIMP 31/40"      -> {"canonical_name":"Shrimp","brand":null,"category":"Seafood","pkg_size":null,"unit":"weight","is_food":true,"is_perishable":true,"storage":"freezer","confidence":0.7}
  "WW SANDWICH BREAD" -> {"canonical_name":"Whole Wheat Sandwich Bread","brand":null,"category":"Bakery","pkg_size":null,"unit":"count","is_food":true,"is_perishable":true,"storage":"counter","confidence":0.8}
  "CAULIFLOWER CRUST" -> {"canonical_name":"Cauliflower Pizza Crusts","brand":null,"category":"Bakery","pkg_size":null,"unit":"count","is_food":true,"is_perishable":true,"storage":"fridge","confidence":0.7}
  "NAAN DIPPERS"      -> {"canonical_name":"Naan Dippers","brand":null,"category":"Bakery","pkg_size":null,"unit":"count","is_food":true,"is_perishable":true,"storage":"pantry","confidence":0.75}
  "ORG ORANGE JUICE"  -> {"canonical_name":"Orange Juice","brand":null,"category":"Beverages","pkg_size":"1/2 gal","unit":"volume","is_food":true,"is_perishable":true,"storage":"fridge","confidence":0.8}
  "PACKAGED COOKIES"  -> {"canonical_name":"Packaged Cookies","brand":null,"category":"Snacks","pkg_size":null,"unit":"count","is_food":true,"is_perishable":false,"storage":"pantry","confidence":0.75}
  "JASMINE RICE"      -> {"canonical_name":"Jasmine Rice","brand":null,"category":"Pantry Staples","pkg_size":null,"unit":"weight","is_food":true,"is_perishable":false,"storage":"pantry","confidence":0.85}
  "CLOVER HONEY"      -> {"canonical_name":"Honey","brand":null,"category":"Condiments & Sauces","pkg_size":null,"unit":"count","is_food":true,"is_perishable":false,"storage":"pantry","confidence":0.85}

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
    # Shelf life is not estimated here — `resolve` fills it for the whole batch afterwards.
    cur = conn.execute(
        """INSERT INTO products
           (canonical_name, brand, category, pkg_size, unit, is_food, is_perishable, storage,
            shelf_life_days, shelf_life_days_opened, shelf_life_source,
            llm_model, llm_confidence, classified_at)
           VALUES (?,?,?,?,?,?,?,?,NULL,NULL,NULL,?,?,datetime('now'))""",
        (
            ci.canonical_name,
            ci.brand,
            ci.category,
            ci.pkg_size,
            ci.unit,
            int(ci.is_food),
            int(ci.is_perishable),
            ci.storage,
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
        if llm.is_rate_limit_error(e):
            return batch, {"items": [], "_rate_limited": True}
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
    stored: list[dict] = []
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
        if ci.is_food:
            stored.append(
                {
                    "id": pid,
                    "name": ci.canonical_name,
                    "category": ci.category,
                    "storage": ci.storage,
                    "is_perishable": ci.is_perishable,
                }
            )
        stats["ok"] += 1
    conn.commit()

    # Non-perishables do not need a shelf-life decision at all. Resolve only the
    # perishables. Exact repurchases are already served by `item_map`, which is keyed by
    # the deterministic (retailer, item_key) pair.
    perishable = [s for s in stored if s.get("is_perishable")]
    if perishable:
        stats["resolved"] += resolve.apply(
            conn, perishable, resolve.resolve_batch(conn, perishable)
        )
    return failed


def _batches(items: list[dict], workers: int) -> list[list[dict]]:
    """Target roughly `workers` in-flight calls, with chunks between 10 and 30 items."""
    if not items:
        return []
    workers = max(1, workers)
    size = min(BATCH_SIZE, max(MIN_BATCH_SIZE, math.ceil(len(items) / workers)))
    return [items[i : i + size] for i in range(0, len(items), size)]


def _run_batches(
    conn: sqlite3.Connection, batches: list[list[dict]], workers: int, stats: dict
) -> tuple[list[dict], bool]:
    """Canonicalize batches concurrently; apply/resolve each as it finishes.

    Resolving inside this loop (rather than after all batches return) overlaps the
    resolver with the remaining canonicalize calls.
    """
    failed: list[dict] = []
    rate_limited = False
    if not batches:
        return failed, rate_limited
    with ThreadPoolExecutor(max_workers=max(1, min(workers, len(batches)))) as pool:
        futures = {
            pool.submit(_call_batch, (batch, _build_user(batch))): batch
            for batch in batches
        }
        for future in as_completed(futures):
            batch = futures[future]
            try:
                batch, data = future.result()
            except Exception as e:  # noqa: BLE001 - keep the other batches moving
                print(f"    canonicalize batch failed: {e}")
                data = {"items": []}
            stats["batches"] += 1
            if data.get("_rate_limited"):
                rate_limited = True
            failed += _apply(conn, batch, data, stats)
    return failed, rate_limited


def canonicalize(
    conn: sqlite3.Connection, limit: int | None = None, workers: int | None = None
) -> dict[str, int]:
    """Canonicalize pending items, resolving each batch as soon as it returns.

    The batch size is chosen to keep roughly `workers` calls in flight: one 30-item
    request is split into 3x10, while six full batches stay at 30 to avoid extra
    prompt overhead.
    """
    workers = workers or config.CLASSIFY_WORKERS
    stats = {"batches": 0, "ok": 0, "fallback": 0, "resolved": 0}
    items = pending(conn, limit)
    if not items:
        return stats

    batches = _batches(items, workers)
    failed, rate_limited = _run_batches(conn, batches, workers, stats)

    if failed and not rate_limited:
        # One retry for malformed/missing output. A rate limit stops here instead of
        # firing more requests; the items stay pending for the next sync.
        retry = _batches(failed, workers)
        still, _ = _run_batches(conn, retry, workers, stats)
        for item in still:
            _fallback(conn, item["retailer"], item)
            stats["fallback"] += 1
        conn.commit()
    elif failed and rate_limited:
        print(f"    rate limited; leaving {len(failed)} items pending for the next sync")

    return stats
