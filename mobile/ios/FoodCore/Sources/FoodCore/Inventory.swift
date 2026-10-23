import Foundation

/// Port of `food/inventory.py` — the consumption model. A receipt says what you *bought*,
/// so inventory is a decaying view: each purchase expires at
/// `acquired_on + shelf_life_days`, repeats decrement oldest-first, and long-dead rows archive.
public enum Inventory {
    static let openStatuses = ["active", "partial"]

    /// `yyyy-MM-dd` + n days, using UTC so it matches the Python (date + timedelta).
    static func addDays(_ iso: String, _ days: Int) -> String? {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "UTC")
        df.dateFormat = "yyyy-MM-dd"
        guard let date = df.date(from: iso) else { return nil }
        guard let shifted = Dates.calendar().date(
            byAdding: .day, value: days, to: date
        ) else { return nil }
        return df.string(from: shifted)
    }

    static func today() -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "UTC")
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: Date())
    }

    /// Create inventory rows for food items that don't have one yet (idempotent).
    @discardableResult
    public static func build(_ db: Database) throws -> Int {
        let rows = try db.query(
            """
            SELECT ri.id AS receipt_item_id, ri.quantity, r.purchased_on,
                   p.id AS product_id, p.storage, p.shelf_life_days, p.is_perishable, p.unit
            FROM receipt_items ri
            JOIN receipts r ON r.id = ri.receipt_id
            JOIN item_map m ON m.retailer = r.retailer AND m.item_key = ri.item_key
            JOIN products p ON p.id = m.product_id
            WHERE p.is_food = 1
            """
        )
        var created = 0
        for row in rows {
            let perishable = row["is_perishable"]?.intValue ?? 0
            let shelf = row["shelf_life_days"]?.intValue
            let purchased = row["purchased_on"]?.stringValue ?? ""
            var expires: SQLValue = .null
            if perishable != 0, let shelf = shelf, let e = addDays(purchased, shelf) {
                expires = .text(e)
            }
            created += try db.run(
                """
                INSERT OR IGNORE INTO inventory
                (product_id, quantity, remaining_qty, unit, acquired_on, expires_on,
                 location, status, source_receipt_item_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, 'active', ?)
                """,
                [
                    row["product_id"] ?? .null,
                    row["quantity"] ?? .double(1),
                    row["quantity"] ?? .double(1),
                    row["unit"] ?? .null,
                    .text(purchased),
                    expires,
                    row["storage"] ?? .null,
                    row["receipt_item_id"] ?? .null,
                ]
            )
        }
        return created
    }

    /// Flip past-expiry rows to `expired`, then archive the long-dead ones.
    @discardableResult
    public static func refreshStatus(
        _ db: Database, today: String? = nil, archiveAfterDays: Int = 14
    ) throws -> (expired: Int, archived: Int) {
        let day = today ?? Self.today()
        let expired = try db.run(
            """
            UPDATE inventory SET status = 'expired'
            WHERE status IN ('active', 'partial')
              AND expires_on IS NOT NULL AND expires_on < ?
            """,
            [.text(day)]
        )
        let cutoff = addDays(day, -archiveAfterDays) ?? day
        let archived = try db.run(
            """
            UPDATE inventory SET status = 'archived'
            WHERE status IN ('expired', 'consumed', 'tossed')
              AND expires_on IS NOT NULL AND expires_on < ?
            """,
            [.text(cutoff)]
        )
        return (expired, archived)
    }

    /// Decrement the oldest active rows first. Returns the quantity actually applied.
    @discardableResult
    public static func consumeFIFO(
        _ db: Database, productID: Int, qty: Double = 1.0, reason: String = "consumed"
    ) throws -> Double {
        let rows = try db.query(
            """
            SELECT id, remaining_qty FROM inventory
            WHERE product_id = ? AND status IN ('active', 'partial', 'expired')
            ORDER BY COALESCE(expires_on, '9999-12-31') ASC, id ASC
            """,
            [.int(Int64(productID))]
        )
        var remaining = qty
        for row in rows {
            if remaining <= 0 { break }
            let have = row["remaining_qty"]?.doubleValue ?? 0
            let take = min(remaining, have)
            let left = have - take
            remaining -= take
            let status = left <= 0 ? (reason == "tossed" ? "tossed" : "consumed") : "partial"
            try db.run(
                "UPDATE inventory SET remaining_qty = ?, status = ? WHERE id = ?",
                [.double(max(left, 0)), .text(status), row["id"] ?? .null]
            )
        }
        return qty - remaining
    }

    public static func setStatus(_ db: Database, inventoryID: Int, status: String) throws {
        try db.run(
            """
            UPDATE inventory SET status = ?,
                remaining_qty = CASE WHEN ? IN ('consumed','tossed') THEN 0 ELSE remaining_qty END
            WHERE id = ?
            """,
            [.text(status), .text(status), .int(Int64(inventoryID))]
        )
    }

    public static func active(_ db: Database, includeArchived: Bool = false) throws -> [[String: SQLValue]] {
        let whereClause = includeArchived ? "" : "AND i.status IN ('active', 'partial', 'expired')"
        return try db.query(
            """
            SELECT i.*, p.canonical_name, p.brand, p.category, p.is_perishable, p.shelf_life_source
            FROM inventory i
            JOIN products p ON p.id = i.product_id
            WHERE 1 = 1 \(whereClause)
            ORDER BY COALESCE(i.expires_on, '9999-12-31') ASC, p.canonical_name ASC
            """
        )
    }

    public static func expiringSoon(
        _ db: Database, days: Int = 3, today: String? = nil
    ) throws -> [[String: SQLValue]] {
        let day = today ?? Self.today()
        let horizon = addDays(day, days) ?? day
        return try db.query(
            """
            SELECT i.*, p.canonical_name, p.brand, p.category
            FROM inventory i JOIN products p ON p.id = i.product_id
            WHERE i.status IN ('active', 'partial')
              AND i.expires_on IS NOT NULL AND i.expires_on <= ?
            ORDER BY i.expires_on ASC
            """,
            [.text(horizon)]
        )
    }
}
