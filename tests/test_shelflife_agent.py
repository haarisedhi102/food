import sqlite3

from food import db, inventory, shelflife_agent


def _mem():
    conn = sqlite3.connect(":memory:")
    conn.row_factory = sqlite3.Row
    db.init_db(conn)
    return conn


def _seed(conn, perishable=1, shelf_life=None):
    conn.execute(
        """INSERT INTO products (canonical_name, category, is_food, is_perishable,
                                 shelf_life_days)
           VALUES ('Mystery Greens', 'Produce', 1, ?, ?)""",
        (perishable, shelf_life),
    )
    pid = conn.execute("SELECT last_insert_rowid() id").fetchone()["id"]
    conn.execute(
        "INSERT INTO receipts (retailer, external_id, purchased_on) VALUES ('kroger','R1','2026-10-10')"
    )
    rid = conn.execute("SELECT last_insert_rowid() id").fetchone()["id"]
    conn.execute(
        """INSERT INTO receipt_items (receipt_id, raw_description, item_key, quantity)
           VALUES (?, 'Mystery Greens', 'K1', 1)""",
        (rid,),
    )
    conn.execute(
        """INSERT OR IGNORE INTO item_map (retailer, item_key, raw_description, product_id)
           VALUES ('kroger','K1','Mystery Greens',?)""",
        (pid,),
    )
    conn.commit()
    return pid


def _guess(**kw):
    kw.setdefault("confidence", 0.9)
    return shelflife_agent.ShelfLifeGuess(**kw)


def test_resolve_missing_fills_shelf_life_and_syncs_inventory(monkeypatch):
    conn = _mem()
    pid = _seed(conn)
    inventory.build(conn)
    assert conn.execute("SELECT expires_on FROM inventory").fetchone()["expires_on"] is None

    monkeypatch.setattr(
        shelflife_agent,
        "resolve",
        lambda name, description=None, category=None: _guess(
            shelf_life_days=5, storage="fridge"
        ),
    )
    stats = shelflife_agent.resolve_missing(conn)
    assert stats == {"resolved": 1, "unresolved": 0, "errors": 0}

    p = conn.execute("SELECT * FROM products WHERE id = ?", (pid,)).fetchone()
    assert p["shelf_life_days"] == 5
    assert p["shelf_life_source"] == "web"
    assert p["storage"] == "fridge"

    inv = conn.execute("SELECT expires_on FROM inventory WHERE product_id = ?", (pid,)).fetchone()
    assert inv["expires_on"] == "2026-10-15"  # 2026-10-10 + 5


def test_agent_answer_is_trusted_even_at_low_confidence(monkeypatch):
    conn = _mem()
    pid = _seed(conn)
    monkeypatch.setattr(
        shelflife_agent,
        "resolve",
        lambda name, description=None, category=None: _guess(shelf_life_days=5, confidence=0.1),
    )
    stats = shelflife_agent.resolve_missing(conn)
    assert stats["resolved"] == 1
    days = conn.execute("SELECT shelf_life_days FROM products WHERE id = ?", (pid,)).fetchone()
    assert days["shelf_life_days"] == 5


def test_items_with_a_known_shelf_life_are_untouched(monkeypatch):
    conn = _mem()
    _seed(conn, shelf_life=30)

    def _boom(*a, **k):
        raise AssertionError("should not be called")

    monkeypatch.setattr(shelflife_agent, "resolve", _boom)
    stats = shelflife_agent.resolve_missing(conn)
    assert stats == {"resolved": 0, "unresolved": 0, "errors": 0}


def test_non_perishable_verdict_clears_expiry(monkeypatch):
    conn = _mem()
    pid = _seed(conn)
    inventory.build(conn)
    monkeypatch.setattr(
        shelflife_agent,
        "resolve",
        lambda name, description=None, category=None: _guess(
            is_perishable=False, shelf_life_days=None
        ),
    )
    stats = shelflife_agent.resolve_missing(conn)
    assert stats["resolved"] == 1
    p = conn.execute("SELECT is_perishable FROM products WHERE id = ?", (pid,)).fetchone()
    assert p["is_perishable"] == 0


def test_agent_error_is_counted_not_fatal(monkeypatch):
    conn = _mem()
    _seed(conn)

    def boom(*a, **k):
        raise RuntimeError("agent down")

    monkeypatch.setattr(shelflife_agent, "resolve", boom)
    stats = shelflife_agent.resolve_missing(conn)
    assert stats == {"resolved": 0, "unresolved": 0, "errors": 1}


def test_resolve_returns_the_structured_response(monkeypatch):
    class _FakeAgent:
        def invoke(self, payload):
            return {"structured_response": shelflife_agent.ShelfLifeGuess(shelf_life_days=3)}

    monkeypatch.setattr(shelflife_agent, "_agent", lambda: _FakeAgent())
    guess = shelflife_agent.resolve("Milk")
    assert guess.shelf_life_days == 3
