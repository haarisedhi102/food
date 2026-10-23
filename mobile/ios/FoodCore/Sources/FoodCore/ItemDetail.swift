import Foundation

/// Port of the item-detail queries in `food/web/app.py` — product, purchase history and stock.
public enum ItemDetail {
    public static func product(_ db: Database, id: Int) throws -> [String: SQLValue]? {
        try db.query("SELECT * FROM products WHERE id = ?", [.int(Int64(id))]).first
    }

    /// Purchase history for a product, oldest first.
    public static func history(_ db: Database, productID: Int) throws -> [[String: SQLValue]] {
        try db.query(
            """
            SELECT r.purchased_on, ri.unit_price_cents, ri.line_total_cents, r.retailer
            FROM receipt_items ri JOIN receipts r ON r.id = ri.receipt_id
            JOIN item_map m ON m.retailer = r.retailer AND m.item_key = ri.item_key
            WHERE m.product_id = ? ORDER BY r.purchased_on ASC
            """,
            [.int(Int64(productID))]
        )
    }

    public static func stock(_ db: Database, productID: Int) throws -> [[String: SQLValue]] {
        try db.query(
            "SELECT * FROM inventory WHERE product_id = ? ORDER BY acquired_on DESC",
            [.int(Int64(productID))]
        )
    }

    /// `{date, price}` points for a price-history chart.
    public static func pricePoints(_ db: Database, productID: Int) throws -> [[String: Any]] {
        try history(db, productID: productID).compactMap { row in
            guard let cents = row["unit_price_cents"]?.intValue else { return nil }
            return ["date": row["purchased_on"]?.stringValue ?? "", "price": Double(cents) / 100.0]
        }
    }
}
