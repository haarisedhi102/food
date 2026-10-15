from food import inventory


def test_fifo_consumes_oldest_first(conn, make):
    product, purchase = make
    product(shelf_life=30)
    purchase("2026-10-01", "K1", qty=1.0)  # oldest
    purchase("2026-10-10", "K2", qty=1.0)  # newer

    inventory.build(conn)
    applied = inventory.consume_fifo(conn, product_id=1, qty=1.5)
    assert applied == 1.5

    rows = conn.execute(
        "SELECT expires_on, remaining_qty, status FROM inventory ORDER BY expires_on"
    ).fetchall()
    assert rows[0]["remaining_qty"] == 0
    assert rows[0]["status"] == "consumed"
    assert rows[1]["remaining_qty"] == 0.5
    assert rows[1]["status"] == "partial"


def test_consume_more_than_stocked(conn, make):
    product, purchase = make
    product(shelf_life=30)
    purchase("2026-10-01", "K1", qty=1.0)

    inventory.build(conn)
    applied = inventory.consume_fifo(conn, product_id=1, qty=5.0)
    assert applied == 1.0  # only what existed
    assert conn.execute("SELECT status FROM inventory").fetchone()["status"] == "consumed"


def test_used_all_of_product(conn, make):
    product, purchase = make
    product(shelf_life=30)
    purchase("2026-10-01", "K1", qty=2.0)
    purchase("2026-10-03", "K2", qty=3.0)

    inventory.build(conn)
    inventory.consume_fifo(conn, product_id=1, qty=100)
    statuses = [r["status"] for r in conn.execute("SELECT status FROM inventory")]
    assert statuses == ["consumed", "consumed"]


def test_set_status(conn, make):
    product, purchase = make
    product(shelf_life=30)
    purchase("2026-10-01", "K1")

    inventory.build(conn)
    iid = conn.execute("SELECT id FROM inventory").fetchone()["id"]
    inventory.set_status(conn, iid, "tossed")
    row = conn.execute("SELECT status, remaining_qty FROM inventory").fetchone()
    assert row["status"] == "tossed"
    assert row["remaining_qty"] == 0
