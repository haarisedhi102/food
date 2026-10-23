"""SQLite connection helpers; the schema is shared with iOS in `shared/schema.sql`."""

from __future__ import annotations

import sqlite3
from pathlib import Path

from . import config

SCHEMA = (config.SHARED_DIR / "schema.sql").read_text()


def connect(db_path: Path | None = None) -> sqlite3.Connection:
    config.ensure_dirs()
    path = db_path or config.DB_PATH
    conn = sqlite3.connect(path) if str(path) == ":memory:" else sqlite3.connect(path, timeout=30)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    if str(path) != ":memory:":
        # parallel canonicalization workers write concurrently
        conn.execute("PRAGMA journal_mode = WAL")
        conn.execute("PRAGMA busy_timeout = 30000")
    return conn


def init_db(conn: sqlite3.Connection) -> None:
    conn.executescript(SCHEMA)
    # CREATE TABLE IF NOT EXISTS never adds columns, so databases created by an older build
    # need newer columns added explicitly.
    columns = {row["name"] for row in conn.execute("PRAGMA table_info(products)")}
    if "needs_review" not in columns:
        conn.execute("ALTER TABLE products ADD COLUMN needs_review INTEGER NOT NULL DEFAULT 0")
    row = conn.execute("SELECT version FROM schema_version").fetchone()
    if row is None:
        conn.execute("INSERT INTO schema_version (version) VALUES (2)")
    elif row["version"] < 2:
        conn.execute("UPDATE schema_version SET version = 2")
    conn.commit()
