import Foundation

/// Port of the `store()` writer in `food/normalize.py` — idempotent upsert of receipts and
/// their line items. Returns (new receipts, new items).
public enum Store {
    @discardableResult
    public static func store(
        _ db: Database,
        retailer: String,
        receipts: [NormalizedReceipt]
    ) throws -> (receipts: Int, items: Int) {
        var newReceipts = 0
        var newItems = 0

        for r in receipts {
            let rid: Int64
            let existing = try db.query(
                "SELECT id FROM receipts WHERE retailer = ? AND external_id = ?",
                [.text(retailer), .text(r.externalID)]
            )
            if let id = existing.first?["id"]?.intValue {
                rid = Int64(id)
            } else {
                try db.run(
                    """
                    INSERT INTO receipts (retailer, external_id, purchased_on, store, total_cents, raw_json)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    [
                        .text(retailer),
                        .text(r.externalID),
                        .text(r.purchasedOn ?? "1970-01-01"),
                        r.store.map { SQLValue.text($0) } ?? .null,
                        r.totalCents.map { SQLValue.int(Int64($0)) } ?? .null,
                        .null,
                    ]
                )
                rid = db.lastInsertRowID
                newReceipts += 1
            }

            for it in r.items {
                newItems += try db.run(
                    """
                    INSERT OR IGNORE INTO receipt_items
                    (receipt_id, raw_description, item_key, raw_pkg_size, quantity, unit_price_cents, line_total_cents)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    [
                        .int(rid),
                        .text(it.rawDescription),
                        .text(it.itemKey),
                        it.rawPkgSize.map { SQLValue.text($0) } ?? .null,
                        .double(it.quantity),
                        it.unitPriceCents.map { SQLValue.int(Int64($0)) } ?? .null,
                        it.lineTotalCents.map { SQLValue.int(Int64($0)) } ?? .null,
                    ]
                )
            }
        }
        return (newReceipts, newItems)
    }

    /// The `external_id`s already stored for a retailer. The browser fetch passes these in so
    /// it can stop paging and itemize only receipts it has not seen.
    public static func knownExternalIDs(_ db: Database, retailer: String) throws -> Set<String> {
        let rows = try db.query(
            "SELECT external_id FROM receipts WHERE retailer = ?",
            [.text(retailer)]
        )
        return Set(rows.compactMap { $0["external_id"]?.stringValue })
    }

    /// The newest purchase date stored for a retailer (YYYY-MM-DD). A date-range fetch (Costco)
    /// starts from here instead of pulling the whole window again.
    public static func latestPurchaseDate(_ db: Database, retailer: String) throws -> String? {
        let rows = try db.query(
            "SELECT MAX(purchased_on) AS latest FROM receipts WHERE retailer = ?",
            [.text(retailer)]
        )
        return rows.first?["latest"]?.stringValue
    }
}
