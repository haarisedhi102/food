import sqlite3

import pytest

from food import canonicalize, cli, db, inventory, resolve


def _product(conn, **values):
    base = {
        "canonical_name": "Milk",
        "is_food": 1,
        "is_perishable": 1,
        "storage": "fridge",
        "shelf_life_days": None,
        "shelf_life_days_opened": None,
        "shelf_life_source": None,
        "needs_review": 0,
    }
    base.update(values)
    columns = ", ".join(base)
    marks = ", ".join("?" * len(base))
    cur = conn.execute(
        f"INSERT INTO products ({columns}) VALUES ({marks})", tuple(base.values())
    )
    conn.commit()
    return cur.lastrowid


def test_user_value_is_sticky_and_can_be_saved_twice(conn):
    pid = _product(conn)

    assert resolve.set_user_shelf_life(conn, pid, 10) == 1
    assert resolve.set_user_shelf_life(conn, pid, 12) == 1

    product = conn.execute("SELECT * FROM products WHERE id = ?", (pid,)).fetchone()
    assert product["shelf_life_days"] == 12
    assert product["shelf_life_source"] == "user"
    assert product["needs_review"] == 0

    # An automatic verdict cannot replace an unflagged user value.
    verdict = {pid: resolve.ItemVerdict(item_id=pid, source="llm", shelf_life_days=3)}
    assert resolve.apply(conn, [{"id": pid}], verdict) == 0
    product = conn.execute("SELECT * FROM products WHERE id = ?", (pid,)).fetchone()
    assert product["shelf_life_days"] == 12
    assert product["shelf_life_source"] == "user"


def test_flag_allows_replacement_and_the_verdict_clears_it(conn):
    pid = _product(conn)
    resolve.set_user_shelf_life(conn, pid, 10)

    assert resolve.flag_for_review(conn, pid) == 1
    product = conn.execute("SELECT * FROM products WHERE id = ?", (pid,)).fetchone()
    assert product["needs_review"] == 1

    verdict = {pid: resolve.ItemVerdict(item_id=pid, source="llm", shelf_life_days=3)}
    assert resolve.apply(conn, [{"id": pid}], verdict) == 1

    product = conn.execute("SELECT * FROM products WHERE id = ?", (pid,)).fetchone()
    assert product["shelf_life_days"] == 3
    assert product["shelf_life_source"] == "llm"
    assert product["needs_review"] == 0


def test_saving_while_flagged_clears_the_flag(conn):
    pid = _product(conn)
    resolve.flag_for_review(conn, pid)

    assert resolve.set_user_shelf_life(conn, pid, 9) == 1
    product = conn.execute("SELECT * FROM products WHERE id = ?", (pid,)).fetchone()
    assert product["shelf_life_source"] == "user"
    assert product["needs_review"] == 0


def test_opened_days_are_preserved_when_not_supplied(conn):
    pid = _product(conn)
    resolve.set_user_shelf_life(conn, pid, 10, opened_days=4)
    resolve.set_user_shelf_life(conn, pid, 12)

    product = conn.execute("SELECT * FROM products WHERE id = ?", (pid,)).fetchone()
    assert product["shelf_life_days_opened"] == 4


def test_user_value_updates_active_inventory_expiry(conn):
    pid = _product(conn)
    conn.execute(
        """INSERT INTO inventory (product_id, quantity, remaining_qty, acquired_on, status)
           VALUES (?, 1, 1, '2026-10-10', 'active')""",
        (pid,),
    )
    conn.commit()

    resolve.set_user_shelf_life(conn, pid, 10)
    row = conn.execute(
        "SELECT expires_on FROM inventory WHERE product_id = ?", (pid,)
    ).fetchone()
    assert row["expires_on"] == "2026-10-20"


def test_pending_selection_includes_gaps_and_flags_but_not_pinned(conn):
    pinned = _product(conn, canonical_name="Pinned", shelf_life_days=5, shelf_life_source="user")
    flagged = _product(
        conn,
        canonical_name="Flagged",
        shelf_life_days=5,
        shelf_life_source="user",
        needs_review=1,
    )
    gap = _product(conn, canonical_name="Gap")
    stable = _product(
        conn, canonical_name="Stable", is_perishable=0, storage="pantry"
    )

    default = resolve.pending(conn)
    ids = [row["id"] for row in default]
    assert ids == [flagged, gap]
    assert pinned not in ids and stable not in ids

    refreshed = resolve.pending(conn, refresh=True)
    refreshed_ids = [row["id"] for row in refreshed]
    assert refreshed_ids == [flagged, gap, stable]
    assert pinned not in refreshed_ids


def test_pending_ids_never_returns_a_pinned_value(conn):
    pinned = _product(conn, shelf_life_days=5, shelf_life_source="user")
    flagged = _product(conn, shelf_life_days=5, shelf_life_source="user", needs_review=1)

    assert [r["id"] for r in resolve.pending(conn, ids=[pinned, flagged])] == [flagged]


def test_run_classify_resolves_an_existing_flagged_product(conn, monkeypatch):
    pid = _product(conn)
    resolve.set_user_shelf_life(conn, pid, 10)
    resolve.flag_for_review(conn, pid)

    monkeypatch.setattr(cli, "_warn_if_lexical", lambda conn: None)
    monkeypatch.setattr(
        canonicalize, "canonicalize", lambda conn, limit=None: {
            "ok": 0, "batches": 0, "fallback": 0, "resolved": 0
        }
    )
    monkeypatch.setattr(
        resolve, "resolve_batch",
        lambda conn, items: {
            row["id"]: resolve.ItemVerdict(
                item_id=row["id"], source="llm", shelf_life_days=3
            )
            for row in items
        },
    )

    stats = cli._run_classify(conn)

    product = conn.execute("SELECT * FROM products WHERE id = ?", (pid,)).fetchone()
    assert product["shelf_life_days"] == 3
    assert product["needs_review"] == 0
    assert stats["resolved"] == 1


def test_new_purchase_inherits_the_user_value(conn):
    pid = _product(conn)
    for purchased_on, key in (("2026-01-01", "milk-1"), ("2026-02-01", "milk-2")):
        cur = conn.execute(
            "INSERT INTO receipts (retailer, external_id, purchased_on) VALUES ('kroger', ?, ?)",
            (key, purchased_on),
        )
        conn.execute(
            """INSERT INTO receipt_items (receipt_id, raw_description, item_key, quantity)
               VALUES (?, 'Milk', ?, 1)""",
            (cur.lastrowid, key),
        )
        conn.execute(
            """INSERT INTO item_map (retailer, item_key, product_id)
               VALUES ('kroger', ?, ?)""",
            (key, pid),
        )
    conn.commit()

    resolve.set_user_shelf_life(conn, pid, 10)
    inventory.build(conn)

    rows = conn.execute(
        "SELECT acquired_on, expires_on FROM inventory WHERE product_id = ? ORDER BY acquired_on",
        (pid,),
    ).fetchall()
    assert [(r["acquired_on"], r["expires_on"]) for r in rows] == [
        ("2026-01-01", "2026-01-11"),
        ("2026-02-01", "2026-02-11"),
    ]



def test_pending_limit_caps_the_backfill(conn):
    for index in range(3):
        _product(conn, canonical_name=f"Gap {index}")

    assert len(resolve.pending(conn, limit=2)) == 2
