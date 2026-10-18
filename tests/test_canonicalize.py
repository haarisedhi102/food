import sqlite3

from food import canonicalize, db


def _mem() -> sqlite3.Connection:
    conn = sqlite3.connect(":memory:")
    conn.row_factory = sqlite3.Row
    db.init_db(conn)
    conn.execute(
        "INSERT INTO receipts (retailer, external_id, purchased_on) VALUES ('kroger', 'R1', '2026-10-05')"
    )
    conn.execute(
        "INSERT INTO receipts (retailer, external_id, purchased_on) VALUES ('costco', 'C1', '2026-10-09')"
    )
    items = [
        (1, "Horizon Organic Whole Milk", "0001", None),
        (1, "Jumbo Yellow Onions", "0002", "1 ct"),
        (2, "KS ORG A2 PR", "1462714", None),
    ]
    for rid, desc, key, pkg in items:
        conn.execute(
            """INSERT INTO receipt_items (receipt_id, raw_description, item_key, raw_pkg_size)
               VALUES (?, ?, ?, ?)""",
            (rid, desc, key, pkg),
        )
    conn.commit()
    return conn


def test_pending_lists_unmapped_items():
    conn = _mem()
    assert canonicalize.pending_count(conn) == 3
    keys = {i["item_key"] for i in canonicalize.pending(conn)}
    assert keys == {"0001", "0002", "1462714"}


def test_mapped_items_are_not_pending():
    conn = _mem()
    conn.execute("INSERT INTO products (canonical_name) VALUES ('x')")
    conn.execute(
        "INSERT INTO item_map (retailer, item_key, raw_description, product_id) VALUES ('kroger','0001','m',1)"
    )
    conn.commit()
    assert canonicalize.pending_count(conn) == 2


def test_canonicalize_stores_and_falls_back(monkeypatch):
    conn = _mem()

    # Model returns only 2 of the 3 items; the third must retry then fall back.
    def fake_chat_json(conn, purpose, system, user, **kwargs):
        return {
            "items": [
                {
                    "item_key": "0001",
                    "canonical_name": "Whole Milk",
                    "category": "Dairy Products & Eggs",
                    "unit": "volume",
                    "is_food": True,
                    "is_perishable": True,
                    "storage": "fridge",
                    "confidence": 0.9,
                },
                {
                    "item_key": "0002",
                    "canonical_name": "Yellow Onions",
                    "category": "Produce",
                    "unit": "count",
                    "is_food": True,
                    "is_perishable": True,
                    "storage": "pantry",
                    "confidence": 0.8,
                },
            ]
        }

    monkeypatch.setattr(canonicalize.llm, "chat_json", fake_chat_json)
    monkeypatch.setattr(canonicalize.resolve, "resolve_batch", lambda *a, **k: {})

    stats = canonicalize.canonicalize(conn)
    assert stats["ok"] == 2
    assert stats["fallback"] == 1
    assert stats["resolved"] == 0
    assert canonicalize.pending_count(conn) == 0

    # the unresolved one still got a placeholder product row (no review queue)
    placeholder = conn.execute(
        "SELECT COUNT(*) n FROM products WHERE canonical_name = 'KS ORG A2 PR'"
    ).fetchone()
    assert placeholder["n"] == 1


def test_canonicalize_resolves_shelf_life_for_food_only(monkeypatch):
    conn = _mem()
    seen = {}

    def fake_chat_json(conn, purpose, system, user, **kwargs):
        return {
            "items": [
                {
                    "item_key": "0001",
                    "canonical_name": "Eggs",
                    "is_food": True,
                    "is_perishable": True,
                    "storage": "fridge",
                    "confidence": 0.9,
                },
                {
                    "item_key": "0002",
                    "canonical_name": "Paper Towels",
                    "category": "Household Supplies",
                    "is_food": False,
                    "is_perishable": False,
                    "storage": "pantry",
                    "confidence": 0.9,
                },
            ]
        }

    def fake_resolve(conn_, items, **kwargs):
        seen["names"] = [it["name"] for it in items]
        return {
            it["id"]: canonicalize.resolve.ItemVerdict(
                item_id=it["id"], source="llm", shelf_life_days=21
            )
            for it in items
        }

    monkeypatch.setattr(canonicalize.llm, "chat_json", fake_chat_json)
    monkeypatch.setattr(canonicalize.resolve, "resolve_batch", fake_resolve)

    stats = canonicalize.canonicalize(conn)

    # non-food never reaches the resolver; the food item's verdict is written back
    assert seen["names"] == ["Eggs"]
    assert stats["resolved"] == 1
    eggs = conn.execute("SELECT * FROM products WHERE canonical_name = 'Eggs'").fetchone()
    assert eggs["shelf_life_days"] == 21
    assert eggs["shelf_life_source"] == "llm"
