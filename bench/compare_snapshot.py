"""Dump the same order-independent snapshot as `foodcore-cli`, and diff two of them.

Row `id`s are insertion-order artifacts, so the snapshot is keyed on natural identity
(receipts by external_id, items by retailer|external_id|item_key|description, products via
their item_map entry). That makes the Swift port and the Python pipeline comparable row for row
regardless of iteration order.

    # small: the redacted fixtures
    SW=..... swift run foodcore-cli import tests/fixtures/kroger_sample.redacted.json --retailer kroger --db /tmp/swift.db
    swift run foodcore-cli snapshot --db /tmp/swift.db > /tmp/swift.json
    uv run python bench/compare_snapshot.py import tests/fixtures/kroger_sample.redacted.json --retailer kroger --db /tmp/py.db
    uv run python bench/compare_snapshot.py snapshot --db /tmp/py.db > /tmp/py.json
    uv run python bench/compare_snapshot.py diff /tmp/swift.json /tmp/py.json
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from food import db as fdb  # noqa: E402
from food import normalize  # noqa: E402

PRODUCT_FIELDS = [
    "canonical_name", "brand", "category", "pkg_size", "unit", "is_food", "is_perishable",
    "storage", "shelf_life_days", "shelf_life_days_opened", "shelf_life_source",
]


def _cell(v):
    return "" if v is None else str(v)


def snapshot(conn) -> dict:
    out: dict = {}

    out["receipts"] = {
        r["external_id"]: {
            "purchased_on": r["purchased_on"],
            "store": r["store"],
            "total_cents": r["total_cents"],
        }
        for r in conn.execute("SELECT external_id, purchased_on, store, total_cents FROM receipts")
    }

    items = {}
    for r in conn.execute(
        """SELECT r.retailer, r.external_id, ri.item_key, ri.raw_description, ri.raw_pkg_size,
                  ri.quantity, ri.unit_price_cents, ri.line_total_cents
           FROM receipt_items ri JOIN receipts r ON r.id = ri.receipt_id"""
    ):
        key = "|".join(_cell(r[c]) for c in ("retailer", "external_id", "item_key", "raw_description"))
        items[key] = {
            "raw_pkg_size": r["raw_pkg_size"],
            "quantity": r["quantity"],
            "unit_price_cents": r["unit_price_cents"],
            "line_total_cents": r["line_total_cents"],
        }
    out["receipt_items"] = items

    item_map = {}
    for r in conn.execute(
        f"""SELECT m.retailer, m.item_key, m.raw_description, {', '.join('p.' + c for c in PRODUCT_FIELDS)}
            FROM item_map m LEFT JOIN products p ON p.id = m.product_id"""
    ):
        key = f"{r['retailer']}|{r['item_key']}"
        product = None
        if r["canonical_name"] is not None:
            product = {c: r[c] for c in PRODUCT_FIELDS}
        item_map[key] = {"raw_description": r["raw_description"], "product": product}
    out["item_map"] = item_map

    inventory = {}
    for r in conn.execute(
        """SELECT r.retailer, ri.item_key, r.external_id, i.acquired_on,
                  i.quantity, i.remaining_qty, i.unit, i.expires_on, i.location, i.status
           FROM inventory i
           JOIN products p ON p.id = i.product_id
           JOIN item_map m ON m.product_id = p.id
           JOIN receipt_items ri ON ri.id = i.source_receipt_item_id
           JOIN receipts r ON r.id = ri.receipt_id"""
    ):
        key = "|".join(_cell(r[c]) for c in ("retailer", "item_key", "acquired_on", "external_id"))
        inventory[key] = {
            "quantity": r["quantity"],
            "remaining_qty": r["remaining_qty"],
            "unit": r["unit"],
            "expires_on": r["expires_on"],
            "location": r["location"],
            "status": r["status"],
        }
    out["inventory"] = inventory
    return out


def cmd_import(args) -> None:
    conn = fdb.connect(Path(args.db))
    fdb.init_db(conn)
    raw = json.loads(Path(args.payload).read_text())
    receipts = normalize.NORMALIZERS[args.retailer](raw)
    new_r, new_i = normalize.store(conn, args.retailer, receipts)
    conn.close()
    print(json.dumps({"receipts": len(receipts), "new": new_r, "items": new_i}))


def cmd_snapshot(args) -> None:
    conn = fdb.connect(Path(args.db))
    fdb.init_db(conn)
    out = snapshot(conn)
    conn.close()
    print(json.dumps(out, indent=2, sort_keys=True, default=str))


def _same(a, b) -> bool:
    """Compare structurally, with a tolerance for float representation noise (Foundation's
    JSON parser and Python's can differ by an ULP on some decimals)."""
    if isinstance(a, dict) and isinstance(b, dict):
        return a.keys() == b.keys() and all(_same(a[k], b[k]) for k in a)
    if isinstance(a, list) and isinstance(b, list):
        return len(a) == len(b) and all(_same(x, y) for x, y in zip(a, b))
    if isinstance(a, (int, float)) and isinstance(b, (int, float)) and not isinstance(a, bool) and not isinstance(b, bool):
        return math.isclose(a, b, rel_tol=1e-9, abs_tol=1e-12)
    return a == b


def cmd_diff(args) -> None:
    a = json.loads(Path(args.left).read_text())
    b = json.loads(Path(args.right).read_text())
    ok = True
    for section in ("receipts", "receipt_items", "item_map", "inventory"):
        ma, mb = a.get(section, {}), b.get(section, {})
        missing = sorted(set(ma) - set(mb))
        extra = sorted(set(mb) - set(ma))
        differs = [k for k in set(ma) & set(mb) if not _same(ma[k], mb[k])]
        tag = f"{section:14}"
        if missing or extra or differs:
            ok = False
            print(f"{tag} {len(ma)} vs {len(mb)}  missing={len(missing)} extra={len(extra)} differing={len(differs)}")
            for k in (missing[:2] + extra[:2] + differs[:2]):
                which = "missing" if k in missing else "extra" if k in extra else "differs"
                print(f"      [{which}] {k}")
                if which == "differs":
                    print(f"        left : {json.dumps(ma[k])}")
                    print(f"        right: {json.dumps(mb[k])}")
        else:
            print(f"{tag} OK  ({len(ma)} records identical)")
    print("\nRESULT:", "IDENTICAL" if ok else "DIFFERENCES FOUND")
    sys.exit(0 if ok else 1)


def main() -> None:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("import")
    p.add_argument("payload")
    p.add_argument("--retailer", required=True)
    p.add_argument("--db", required=True)
    p.set_defaults(func=cmd_import)
    p = sub.add_parser("snapshot")
    p.add_argument("--db", required=True)
    p.set_defaults(func=cmd_snapshot)
    p = sub.add_parser("diff")
    p.add_argument("left")
    p.add_argument("right")
    p.set_defaults(func=cmd_diff)
    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
