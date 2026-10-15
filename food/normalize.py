"""Deterministic, per-retailer structural adapters.

Turns each retailer's raw receipt JSON into provisional canonical records keyed
on the retailer's *stable* identifier (Costco itemNumber, Kroger upc). No LLM here.
"""

from __future__ import annotations

import hashlib
import json
import re
import sqlite3
from datetime import datetime
from typing import Any


def _cents(v: Any) -> int | None:
    if v is None:
        return None
    if isinstance(v, (int, float)):
        return int(round(float(v) * 100))
    m = re.search(r"-?\d+(?:\.\d+)?", str(v).replace(",", ""))
    return int(round(float(m.group(0)) * 100)) if m else None


def _local_date(s: Any) -> str | None:
    if not s:
        return None
    s = str(s).strip().replace("Z", "")
    try:
        return datetime.fromisoformat(s).date().isoformat()
    except ValueError:
        pass
    for fmt in ("%m/%d/%Y", "%m/%d/%y", "%Y/%m/%d"):
        try:
            return datetime.strptime(s[:10], fmt).date().isoformat()
        except ValueError:
            continue
    return None


def _fallback_key(*parts: Any) -> str:
    joined = " ".join(str(p).strip().lower() for p in parts if p)
    return "desc:" + hashlib.sha1(joined.encode()).hexdigest()[:16]


def normalize_costco(raw: Any) -> list[dict]:
    from .ingest import costco

    receipts = []
    for r in costco.extract_receipts(raw):
        items = []
        for it in r.get("itemArray") or []:
            desc = " ".join(
                str(it.get(k)).strip()
                for k in ("itemDescription01", "itemDescription02")
                if it.get(k)
            ).strip()
            unit = it.get("unit")
            # skip returns (negative unit) and "/<item>" discount lines
            if (isinstance(unit, (int, float)) and unit < 0) or desc.startswith("/"):
                continue
            number = str(it.get("itemNumber") or "").strip()
            items.append(
                {
                    "raw_description": desc,
                    "item_key": number or _fallback_key(desc),
                    "raw_pkg_size": None,
                    "quantity": float(unit) if isinstance(unit, (int, float)) else 1.0,
                    "unit_price_cents": _cents(it.get("itemUnitPriceAmount")),
                    "line_total_cents": _cents(it.get("amount")),
                }
            )
        ext = str(
            r.get("transactionBarcode")
            or f"{r.get('warehouseNumber')}-{r.get('transactionNumber')}-{r.get('transactionDate')}"
        )
        receipts.append(
            {
                "external_id": ext,
                "purchased_on": _local_date(r.get("transactionDateTime") or r.get("transactionDate")),
                "store": r.get("warehouseName"),
                "total_cents": _cents(r.get("total")),
                "items": items,
                "raw": r,
            }
        )
    return receipts


def normalize_kroger(raw: Any) -> list[dict]:
    from .ingest import kroger

    search = raw.get("search") or []
    details = raw.get("details") or {}
    meta = {str(r.get("receiptKey")): r for r in search if r.get("receiptKey")}

    receipts = []
    for key, payload in details.items():
        rec = meta.get(key, {})
        if rec.get("purchaseType") and rec.get("purchaseType") not in kroger.GROCERY_TYPES:
            continue
        # archives may hold either the raw payload or the whole fetch result dict
        if isinstance(payload, dict) and "json" in payload:
            payload = payload["json"]

        # A batch request returns one receipt per key, each self-identifying by
        # purchaseId.receiptId. Keep only *this* key's receipt, or every receipt in
        # the batch would be attributed to every key.
        match = None
        for detail in kroger.extract_details(payload):
            rid = (detail.get("purchaseId") or {}).get("receiptId")
            if rid is None or str(rid) == str(key):
                match = detail
                break
        if match is None:
            continue

        items = []
        for item in match.get("items") or []:
            pd = item.get("purchasedData") or {}
            di = pd.get("displayInfo") or {}
            desc = di.get("description") or ""
            upc = str(pd.get("upc") or "").strip()
            qty = (pd.get("quantityInfo") or {}).get("received", 1)
            pricing = pd.get("pricingInfo") or {}
            items.append(
                {
                    "raw_description": desc,
                    "item_key": upc or _fallback_key(desc),
                    "raw_pkg_size": di.get("customerFacingSize"),
                    "quantity": float(qty) if isinstance(qty, (int, float)) else 1.0,
                    "unit_price_cents": _cents(pricing.get("unitPricePaid")),
                    "line_total_cents": _cents(pricing.get("totalPricePaid")),
                }
            )

        total = (match.get("costSummary") or {}).get("total") or rec.get("total")
        receipts.append(
            {
                "external_id": key,
                "purchased_on": _local_date((rec.get("createdDateTime") or {}).get("value")),
                "store": rec.get("handoffStoreId"),
                "total_cents": _cents(total),
                "items": items,
                "raw": {"search": rec, "details": match},
            }
        )
    return receipts


NORMALIZERS = {"costco": normalize_costco, "kroger": normalize_kroger}


def store(conn: sqlite3.Connection, retailer: str, receipts: list[dict]) -> tuple[int, int]:
    new_receipts = new_items = 0
    for r in receipts:
        cur = conn.execute(
            "SELECT id FROM receipts WHERE retailer = ? AND external_id = ?",
            (retailer, r["external_id"]),
        )
        row = cur.fetchone()
        if row:
            rid = row["id"]
        else:
            cur = conn.execute(
                """INSERT INTO receipts (retailer, external_id, purchased_on, store, total_cents, raw_json)
                   VALUES (?, ?, ?, ?, ?, ?)""",
                (
                    retailer,
                    r["external_id"],
                    r["purchased_on"] or "1970-01-01",
                    r.get("store"),
                    r.get("total_cents"),
                    json.dumps(r.get("raw")),
                ),
            )
            rid = cur.lastrowid
            new_receipts += 1
        for it in r["items"]:
            cur = conn.execute(
                """INSERT OR IGNORE INTO receipt_items
                   (receipt_id, raw_description, item_key, raw_pkg_size, quantity, unit_price_cents, line_total_cents)
                   VALUES (?, ?, ?, ?, ?, ?, ?)""",
                (
                    rid,
                    it["raw_description"],
                    it["item_key"],
                    it.get("raw_pkg_size"),
                    it.get("quantity", 1.0),
                    it.get("unit_price_cents"),
                    it.get("line_total_cents"),
                ),
            )
            new_items += cur.rowcount
    conn.commit()
    return new_receipts, new_items
