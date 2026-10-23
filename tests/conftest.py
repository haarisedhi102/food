import sqlite3

import pytest

from food import db


@pytest.fixture(autouse=True)
def _disable_jev(monkeypatch):
    """Never make live Jev calls from the default test suite."""
    monkeypatch.setattr("food.resolve.jev.is_configured", lambda: False)


@pytest.fixture
def conn():
    c = sqlite3.connect(":memory:")
    c.row_factory = sqlite3.Row
    db.init_db(c)
    yield c
    c.close()


@pytest.fixture
def make(conn):
    """Factories for seeding products and purchases."""

    def product(pid=1, name="X", shelf_life=30, perishable=1, is_food=1, storage="fridge"):
        conn.execute(
            """INSERT INTO products (id, canonical_name, is_food, is_perishable, shelf_life_days, storage)
               VALUES (?, ?, ?, ?, ?, ?)""",
            (pid, name, is_food, perishable, shelf_life, storage),
        )
        conn.commit()
        return pid

    def purchase(purchased_on, key, qty=1.0, product_id=1, retailer="kroger"):
        ext = f"{retailer}:{key}:{purchased_on}"
        cur = conn.execute(
            "INSERT INTO receipts (retailer, external_id, purchased_on) VALUES (?, ?, ?)",
            (retailer, ext, purchased_on),
        )
        rid = cur.lastrowid
        conn.execute(
            """INSERT INTO receipt_items (receipt_id, raw_description, item_key, quantity)
               VALUES (?, ?, ?, ?)""",
            (rid, f"desc-{key}", key, qty),
        )
        conn.execute(
            """INSERT OR IGNORE INTO item_map (retailer, item_key, raw_description, product_id)
               VALUES (?, ?, ?, ?)""",
            (retailer, key, f"desc-{key}", product_id),
        )
        conn.commit()

    return product, purchase
