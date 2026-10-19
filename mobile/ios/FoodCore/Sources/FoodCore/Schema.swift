import Foundation

/// The SQLite schema, copied verbatim from `food/db.py` so an on-device database has exactly
/// the same tables, columns and constraints as the server pipeline. The v2 migration (the
/// embeddings table) is carried even though v1 does not use embeddings, so a future build can
/// adopt hybrid search without a schema break.
public enum Schema {
    static let ddl = """
    CREATE TABLE IF NOT EXISTS schema_version (
        version INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS receipts (
        id            INTEGER PRIMARY KEY,
        retailer      TEXT NOT NULL,
        external_id   TEXT NOT NULL,
        purchased_on  TEXT NOT NULL,            -- local date, YYYY-MM-DD
        store         TEXT,
        total_cents   INTEGER,
        raw_json      TEXT,
        pulled_at     TEXT NOT NULL DEFAULT (datetime('now')),
        UNIQUE (retailer, external_id)
    );

    CREATE TABLE IF NOT EXISTS receipt_items (
        id                INTEGER PRIMARY KEY,
        receipt_id        INTEGER NOT NULL REFERENCES receipts(id) ON DELETE CASCADE,
        raw_description   TEXT,
        item_key          TEXT NOT NULL,
        raw_pkg_size      TEXT,
        quantity          REAL NOT NULL DEFAULT 1,
        unit_price_cents  INTEGER,
        line_total_cents  INTEGER,
        UNIQUE (receipt_id, item_key, raw_description)
    );

    CREATE TABLE IF NOT EXISTS products (
        id                       INTEGER PRIMARY KEY,
        canonical_name           TEXT NOT NULL,
        brand                    TEXT,
        category                 TEXT,
        pkg_size                 TEXT,
        unit                     TEXT,
        is_food                  INTEGER NOT NULL DEFAULT 1,
        is_perishable            INTEGER NOT NULL DEFAULT 0,
        storage                  TEXT,
        shelf_life_days          INTEGER,
        shelf_life_days_opened   INTEGER,
        shelf_life_source        TEXT,          -- foodkeeper | llm | manual
        foodkeeper_id            INTEGER,
        llm_model                TEXT,
        llm_confidence           REAL,
        classified_at            TEXT
    );

    CREATE TABLE IF NOT EXISTS item_map (
        id               INTEGER PRIMARY KEY,
        retailer         TEXT NOT NULL,
        item_key         TEXT NOT NULL,
        raw_description  TEXT,
        product_id       INTEGER NOT NULL REFERENCES products(id),
        UNIQUE (retailer, item_key)
    );

    CREATE TABLE IF NOT EXISTS shelf_life_ref (
        foodkeeper_id                    INTEGER PRIMARY KEY,
        name                             TEXT,
        subtitle                         TEXT,
        category                         TEXT,
        keywords                         TEXT,
        pantry_days                      INTEGER,
        dop_refrigerate_days             INTEGER,
        refrigerate_after_opening_days   INTEGER,
        dop_freeze_days                  INTEGER,
        raw_json                         TEXT
    );

    CREATE TABLE IF NOT EXISTS inventory (
        id                     INTEGER PRIMARY KEY,
        product_id             INTEGER NOT NULL REFERENCES products(id),
        quantity               REAL NOT NULL DEFAULT 1,
        remaining_qty          REAL NOT NULL DEFAULT 1,
        unit                   TEXT,
        acquired_on            TEXT NOT NULL,
        expires_on             TEXT,
        location               TEXT,
        status                 TEXT NOT NULL DEFAULT 'active',
        source_receipt_item_id INTEGER REFERENCES receipt_items(id),
        UNIQUE (source_receipt_item_id)
    );
    CREATE INDEX IF NOT EXISTS idx_inventory_status_expires
        ON inventory (status, expires_on);

    CREATE TABLE IF NOT EXISTS prompt_cache (
        cache_key     TEXT PRIMARY KEY,
        response_json TEXT NOT NULL,
        created_at    TEXT NOT NULL DEFAULT (datetime('now'))
    );

    CREATE TABLE IF NOT EXISTS llm_calls (
        id                 INTEGER PRIMARY KEY,
        purpose            TEXT NOT NULL,
        model              TEXT,
        prompt_tokens      INTEGER,
        completion_tokens  INTEGER,
        created_at         TEXT NOT NULL DEFAULT (datetime('now'))
    );
    """

    /// (target_version, script) — forward-only, applied in order (mirrors `db.MIGRATIONS`).
    static let migrations: [(Int, String)] = [
        (
            2,
            """
            CREATE TABLE IF NOT EXISTS shelf_life_embedding (
                foodkeeper_id INTEGER PRIMARY KEY REFERENCES shelf_life_ref(foodkeeper_id) ON DELETE CASCADE,
                model         TEXT NOT NULL,
                dim           INTEGER NOT NULL,
                vector        BLOB NOT NULL,
                created_at    TEXT NOT NULL DEFAULT (datetime('now'))
            );
            """
        )
    ]

    /// Create the schema and apply migrations. Idempotent (mirrors `db.init_db`).
    public static func initDB(_ db: Database) throws {
        try db.exec(ddl)
        let version: Int
        let rows = try db.query("SELECT version FROM schema_version")
        if let first = rows.first, case let .int(v) = first["version"] ?? .null {
            version = Int(v)
        } else {
            try db.run("INSERT INTO schema_version (version) VALUES (1)")
            version = 1
        }
        for (target, script) in migrations where target > version {
            try db.exec(script)
            try db.run("UPDATE schema_version SET version = ?", [.int(Int64(target))])
        }
    }
}
