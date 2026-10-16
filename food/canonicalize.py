"""LLM canonicalization: reconcile Kroger and Costco line items into one product schema.

Both retailers flow through a single prompt and a single output schema, so their structural
differences disappear at the boundary. Results are cached per (retailer, item_key) in
`item_map`, so each product is canonicalized exactly once. Shelf life is taken from FoodKeeper
when the model picks a candidate id, otherwise from the model's own estimate.
"""

from __future__ import annotations

import json
import sqlite3
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Any

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
  foodkeeper_id (int or null), shelf_life_days (int or null),
  shelf_life_days_opened (int or null), confidence (0.0-1.0).

Rules:
- If one of the provided FoodKeeper candidates is a clear match, set foodkeeper_id to its id.
- Otherwise set foodkeeper_id to null and give shelf_life_days from your own knowledge.
- Non-food items (apparel, housewares, electronics, flowers, tobacco) get is_food=false and
  is_perishable=false.
- Items that do not spoil quickly (coffee, rice, canned goods, spices, oil) are
  is_perishable=false.
- If you are unsure, lower confidence rather than guessing wildly.

Examples:
  "KS ORG A2 PR"      -> {"canonical_name":"Organic A2 Milk","brand":"Kirkland Signature","category":"Dairy Products & Eggs","pkg_size":"1/2 gal","unit":"volume","is_food":true,"is_perishable":true,"storage":"fridge","confidence":0.8}
  "KS COLMBIAN"       -> {"canonical_name":"Colombian Coffee","brand":"Kirkland Signature","category":"Beverages","pkg_size":null,"unit":"count","is_food":true,"is_perishable":false,"storage":"pantry","confidence":0.75}
  "PASTURE EGGS"      -> {"canonical_name":"Pasture-Raised Eggs","brand":null,"category":"Dairy Products & Eggs","pkg_size":null,"unit":"count","is_food":true,"is_perishable":true,"storage":"fridge","confidence":0.8}
  "MWCHINOPANT"       -> {"canonical_name":"Apparel","brand":null,"category":null,"pkg_size":null,"unit":"count","is_food":false,"is_perishable":false,"storage":"pantry","confidence":0.6}
  "SHRIMP 31/40"      -> {"canonical_name":"Shrimp","brand":null,"category":"Seafood","pkg_size":null,"unit":"weight","is_food":true,"is_perishable":true,"storage":"freezer","confidence":0.7}

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


def _build_user(items: list[dict], conn: sqlite3.Connection) -> str:
    payload = []
    for it in items:
        # give retrieval both the description and any package-size hint
        query = " ".join(
            p for p in (it.get("raw_description"), it.get("raw_pkg_size")) if p
        )
        cands = reference.search(conn, query, limit=5)
        payload.append(
            {
                "item_key": it["item_key"],
                "retailer": it["retailer"],
                "raw_description": it["raw_description"],
                "pkg_size_hint": it.get("raw_pkg_size"),
                "foodkeeper_candidates": [
                    {"id": c["foodkeeper_id"], "name": c["name"], "subtitle": c["subtitle"]}
                    for c in cands
                ],
            }
        )
    return json.dumps({"items": payload}, ensure_ascii=False)


def _store(conn: sqlite3.Connection, retailer: str, item: dict, ci: CanonicalItem) -> None:
    # Shelf life: FoodKeeper value wins; else the model's estimate.
    days = ci.shelf_life_days
    source = "llm" if days is not None else None
    if ci.foodkeeper_id is not None:
        fk = shelflife.days_for(conn, ci.foodkeeper_id, ci.storage or "fridge")
        if fk is not None:
            days, source = fk, "foodkeeper"
    needs_review = ci.confidence < 0.4 or (ci.is_perishable and days is None)

    cur = conn.execute(
        """INSERT INTO products
           (canonical_name, brand, category, pkg_size, unit, is_food, is_perishable, storage,
            shelf_life_days, shelf_life_days_opened, shelf_life_source, foodkeeper_id,
            review_state, llm_model, llm_confidence, classified_at)
           VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,datetime('now'))""",
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
            ci.foodkeeper_id,
            "needs_review" if needs_review else "ok",
            llm.config.MODEL,
            ci.confidence,
        ),
    )
    conn.execute(
        """INSERT OR IGNORE INTO item_map (retailer, item_key, raw_description, product_id)
           VALUES (?, ?, ?, ?)""",
        (retailer, item["item_key"], item.get("raw_description"), cur.lastrowid),
    )


def _fallback(conn: sqlite3.Connection, retailer: str, item: dict) -> None:
    """A model we couldn't parse: keep the pipeline moving via the manual review queue."""
    cur = conn.execute(
        """INSERT INTO products (canonical_name, is_food, is_perishable, review_state, llm_confidence)
           VALUES (?, 1, 0, 'needs_review', 0.0)""",
        (item.get("raw_description") or item["item_key"],),
    )
    conn.execute(
        """INSERT OR IGNORE INTO item_map (retailer, item_key, raw_description, product_id)
           VALUES (?, ?, ?, ?)""",
        (retailer, item["item_key"], item.get("raw_description"), cur.lastrowid),
    )


def _call_batch(batch: list[dict], user: str, models: list[str]) -> dict:
    """Runs in a worker thread, so it needs its own connection."""
    wc = db.connect()
    try:
        return llm.chat_json(wc, "canonicalize", SYSTEM, user, models=models)
    finally:
        wc.close()


def _apply(conn: sqlite3.Connection, batch: list[dict], data: dict, stats: dict) -> list[dict]:
    by_key: dict[str, Any] = {}
    for raw in data.get("items", []) or []:
        if isinstance(raw, dict) and raw.get("item_key") is not None:
            by_key[str(raw["item_key"])] = raw

    failed = []
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
        _store(conn, item["retailer"], item, ci)
        stats["ok"] += 1
    conn.commit()
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
    models = [config.MODEL, *config.FALLBACK_MODELS]

    def run(batches: list[list[dict]]) -> list[tuple[list[dict], dict]]:
        # prompts are built in the main thread (search_candidates needs this connection)
        work = [(b, _build_user(b, conn)) for b in batches]
        out: list[tuple[list[dict], dict]] = []
        with ThreadPoolExecutor(max_workers=workers) as ex:
            futures = {ex.submit(_call_batch, b, u, models): b for b, u in work}
            for fut in as_completed(futures):
                batch = futures[fut]
                try:
                    out.append((batch, fut.result()))
                except Exception as e:  # noqa: BLE001 - degrade to the review queue
                    print(f"    canonicalize call failed: {e}")
                    out.append((batch, {"items": []}))
        return out

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


def needs_review(conn: sqlite3.Connection) -> int:
    row = conn.execute(
        "SELECT COUNT(*) n FROM products WHERE review_state = 'needs_review'"
    ).fetchone()
    return row["n"]
