"""Inventory: the consumption model.

A receipt tells you what you *bought*, not what's still in the kitchen. So inventory is a
decaying view: each purchase becomes a row that expires on `acquired_on + shelf_life_days`,
repeat purchases are decremented FIFO (oldest first), and rows long past expiry are archived
so the fridge doesn't fill with phantom spoilage.
"""

from __future__ import annotations

import sqlite3
from datetime import date, timedelta

from . import config

OPEN_STATUSES = ("active", "partial")


def _expiry(purchased_on: str, shelf_life_days: int | None) -> str | None:
    if not shelf_life_days:
        return None
    return (date.fromisoformat(purchased_on) + timedelta(days=shelf_life_days)).isoformat()


def build(conn: sqlite3.Connection) -> int:
    """Create inventory rows for food items that don't have one yet (idempotent)."""
    rows = conn.execute(
        """
        SELECT ri.id AS receipt_item_id, ri.quantity, r.purchased_on,
               p.id AS product_id, p.storage, p.shelf_life_days, p.is_perishable, p.unit
        FROM receipt_items ri
        JOIN receipts r ON r.id = ri.receipt_id
        JOIN item_map m ON m.retailer = r.retailer AND m.item_key = ri.item_key
        JOIN products p ON p.id = m.product_id
        WHERE p.is_food = 1
        """
    ).fetchall()

    created = 0
    for row in rows:
        expires = (
            _expiry(row["purchased_on"], row["shelf_life_days"]) if row["is_perishable"] else None
        )
        cur = conn.execute(
            """INSERT OR IGNORE INTO inventory
               (product_id, quantity, remaining_qty, unit, acquired_on, expires_on,
                location, status, source_receipt_item_id)
               VALUES (?, ?, ?, ?, ?, ?, ?, 'active', ?)""",
            (
                row["product_id"],
                row["quantity"],
                row["quantity"],
                row["unit"],
                row["purchased_on"],
                expires,
                row["storage"],
                row["receipt_item_id"],
            ),
        )
        created += cur.rowcount
    conn.commit()
    return created


def refresh_status(conn: sqlite3.Connection, today: date | None = None) -> dict[str, int]:
    """Flip past-expiry rows to `expired`, then archive the long-dead ones."""
    today = today or date.today()
    expired = conn.execute(
        """UPDATE inventory SET status = 'expired'
           WHERE status IN ('active', 'partial')
             AND expires_on IS NOT NULL AND expires_on < ?""",
        (today.isoformat(),),
    ).rowcount
    cutoff = (today - timedelta(days=config.ARCHIVE_AFTER_DAYS)).isoformat()
    archived = conn.execute(
        """UPDATE inventory SET status = 'archived'
           WHERE status IN ('expired', 'consumed', 'tossed')
             AND expires_on IS NOT NULL AND expires_on < ?""",
        (cutoff,),
    ).rowcount
    conn.commit()
    return {"expired": expired, "archived": archived}


def consume_fifo(
    conn: sqlite3.Connection, product_id: int, qty: float = 1.0, reason: str = "consumed"
) -> float:
    """Decrement the oldest active rows first. Returns the quantity actually applied."""
    rows = conn.execute(
        """SELECT id, remaining_qty FROM inventory
           WHERE product_id = ? AND status IN ('active', 'partial', 'expired')
           ORDER BY COALESCE(expires_on, '9999-12-31') ASC, id ASC""",
        (product_id,),
    ).fetchall()

    remaining = qty
    for row in rows:
        if remaining <= 0:
            break
        take = min(remaining, row["remaining_qty"])
        left = row["remaining_qty"] - take
        remaining -= take
        if left <= 0:
            status = "tossed" if reason == "tossed" else "consumed"
        else:
            status = "partial"
        conn.execute(
            "UPDATE inventory SET remaining_qty = ?, status = ? WHERE id = ?",
            (max(left, 0.0), status, row["id"]),
        )
    conn.commit()
    return qty - remaining


def set_status(conn: sqlite3.Connection, inventory_id: int, status: str) -> None:
    conn.execute(
        "UPDATE inventory SET status = ?, remaining_qty = CASE WHEN ? IN ('consumed','tossed') THEN 0 ELSE remaining_qty END WHERE id = ?",
        (status, status, inventory_id),
    )
    conn.commit()


def active(conn: sqlite3.Connection, include_archived: bool = False) -> list[dict]:
    where = "" if include_archived else "AND i.status IN ('active', 'partial', 'expired')"
    rows = conn.execute(
        f"""
        SELECT i.*, p.canonical_name, p.brand, p.category, p.pkg_size, p.is_perishable, p.shelf_life_source
        FROM inventory i
        JOIN products p ON p.id = i.product_id
        WHERE 1 = 1 {where}
        ORDER BY COALESCE(i.expires_on, '9999-12-31') ASC, p.canonical_name ASC
        """
    ).fetchall()
    return [dict(r) for r in rows]


def expiring_soon(conn: sqlite3.Connection, days: int = 3, today: date | None = None) -> list[dict]:
    today = today or date.today()
    horizon = (today + timedelta(days=days)).isoformat()
    rows = conn.execute(
        """SELECT i.*, p.canonical_name, p.brand, p.category
           FROM inventory i JOIN products p ON p.id = i.product_id
           WHERE i.status IN ('active', 'partial')
             AND i.expires_on IS NOT NULL AND i.expires_on <= ?
           ORDER BY i.expires_on ASC""",
        (horizon,),
    ).fetchall()
    return [dict(r) for r in rows]
