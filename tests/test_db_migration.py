import sqlite3

from food import db


def _mem():
    conn = sqlite3.connect(":memory:")
    conn.row_factory = sqlite3.Row
    return conn


def test_migration_creates_embedding_table():
    conn = _mem()
    db.init_db(conn)
    assert conn.execute("SELECT version FROM schema_version").fetchone()["version"] == 2
    cols = {r["name"] for r in conn.execute("PRAGMA table_info(shelf_life_embedding)")}
    assert {"foodkeeper_id", "model", "dim", "vector"} <= cols


def test_migration_is_idempotent():
    conn = _mem()
    db.init_db(conn)
    db.init_db(conn)
    assert conn.execute("SELECT version FROM schema_version").fetchone()["version"] == 2


def test_fresh_schema_has_review_column():
    conn = _mem()
    db.init_db(conn)
    cols = {r["name"]: r for r in conn.execute("PRAGMA table_info(products)")}
    assert "needs_review" in cols
    assert cols["needs_review"]["notnull"] == 1
    assert cols["needs_review"]["dflt_value"] == "0"


def test_init_db_backfills_review_column_on_a_legacy_db():
    conn = _mem()
    db.init_db(conn)
    conn.execute("ALTER TABLE products DROP COLUMN needs_review")
    assert "needs_review" not in {r["name"] for r in conn.execute("PRAGMA table_info(products)")}

    db.init_db(conn)

    assert "needs_review" in {r["name"] for r in conn.execute("PRAGMA table_info(products)")}

