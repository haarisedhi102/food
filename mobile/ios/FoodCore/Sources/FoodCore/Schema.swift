import Foundation

/// The SQLite schema comes from the shared `shared/schema.sql` resource, so Python and iOS
/// execute exactly the same DDL.
public enum Schema {
    /// Create the schema and apply migrations. Idempotent (mirrors `db.init_db`).
    public static func initDB(_ db: Database) throws {
        try db.exec(try SharedContract.schemaSQL())
        // `CREATE TABLE IF NOT EXISTS` never adds columns, so a database created by an older
        // build needs the newer ones added explicitly.
        try ensureColumn(
            db, table: "products", column: "needs_review",
            ddl: "ALTER TABLE products ADD COLUMN needs_review INTEGER NOT NULL DEFAULT 0"
        )
        let rows = try db.query("SELECT version FROM schema_version")
        if let first = rows.first, case let .int(v) = first["version"] ?? .null {
            if v < 2 {
                try db.run("UPDATE schema_version SET version = 2")
            }
        } else {
            try db.run("INSERT INTO schema_version (version) VALUES (2)")
        }
    }

    private static func ensureColumn(
        _ db: Database, table: String, column: String, ddl: String
    ) throws {
        let columns = try db.query("PRAGMA table_info(\(table))")
        guard !columns.contains(where: { $0["name"]?.stringValue == column }) else { return }
        try db.run(ddl)
    }
}
