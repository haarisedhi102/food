from datetime import date

from food import inventory


def test_expires_on_is_purchase_plus_shelf_life(conn, make):
    product, purchase = make
    product(shelf_life=3)
    purchase("2026-10-10", "K1")

    inventory.build(conn)
    row = conn.execute("SELECT * FROM inventory").fetchone()
    assert row["expires_on"] == "2026-10-13"
    assert row["acquired_on"] == "2026-10-10"
    assert row["status"] == "active"
    assert row["remaining_qty"] == 1.0


def test_build_is_idempotent(conn, make):
    product, purchase = make
    product()
    purchase("2026-10-10", "K1")

    assert inventory.build(conn) == 1
    assert inventory.build(conn) == 0  # re-running creates nothing
    assert conn.execute("SELECT COUNT(*) n FROM inventory").fetchone()["n"] == 1


def test_non_perishable_has_no_expiry(conn, make):
    product, purchase = make
    product(shelf_life=730, perishable=0)
    purchase("2026-10-10", "K1")

    inventory.build(conn)
    assert conn.execute("SELECT expires_on FROM inventory").fetchone()["expires_on"] is None


def test_non_food_is_not_stocked(conn, make):
    product, purchase = make
    product(is_food=0, perishable=0, shelf_life=None)
    purchase("2026-10-10", "K1")

    assert inventory.build(conn) == 0


def test_past_expiry_flips_to_expired_then_archives(conn, make):
    product, purchase = make
    product(shelf_life=3)
    purchase("2026-10-01", "K1")  # expired 2026-10-04

    inventory.build(conn)

    # just past expiry -> expired
    res = inventory.refresh_status(conn, today=date(2026, 10, 5))
    assert res["expired"] == 1
    assert conn.execute("SELECT status FROM inventory").fetchone()["status"] == "expired"

    # long past expiry (beyond the archive grace) -> archived
    res = inventory.refresh_status(conn, today=date(2026, 11, 1))
    assert res["archived"] == 1
    assert conn.execute("SELECT status FROM inventory").fetchone()["status"] == "archived"


def test_expiring_soon_window(conn, make):
    product, purchase = make
    product(shelf_life=2)
    purchase("2026-10-10", "K1")  # expires 2026-10-12

    inventory.build(conn)
    soon = inventory.expiring_soon(conn, days=3, today=date(2026, 10, 10))
    assert len(soon) == 1
    assert soon[0]["canonical_name"] == "X"

    none = inventory.expiring_soon(conn, days=3, today=date(2026, 10, 1))
    assert none == []
