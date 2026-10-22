import Foundation

/// The SQLite schema comes from the shared `shared/schema.sql` resource, so Python and iOS
/// execute exactly the same DDL.
public enum Schema {
    /// Create the schema and apply migrations. Idempotent (mirrors `db.init_db`).
    public static func initDB(_ db: Database) throws {
        try db.exec(try SharedContract.schemaSQL())
        let rows = try db.query("SELECT version FROM schema_version")
        if let first = rows.first, case let .int(v) = first["version"] ?? .null {
            if v < 2 {
                try db.run("UPDATE schema_version SET version = 2")
            }
        } else {
            try db.run("INSERT INTO schema_version (version) VALUES (2)")
        }
    }
}
