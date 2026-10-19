import Foundation

/// An order-independent, key-based dump for comparing the Swift port against the Python
/// pipeline. Row `id`s are insertion-order artifacts (Swift sorts JSON keys, Python keeps the
/// original order), so we key on natural identity instead: receipts by `external_id`, items by
/// `retailer|external_id|item_key|description`, and products via their `item_map` entry.
public enum Snapshot {
    public static func canonical(_ db: Database) throws -> [String: Any] {
        var out: [String: Any] = [:]

        var receipts: [String: Any] = [:]
        for r in try db.query("SELECT external_id, purchased_on, store, total_cents FROM receipts") {
            receipts[r["external_id"]?.stringValue ?? ""] = [
                "purchased_on": any(r["purchased_on"] ?? .null),
                "store": any(r["store"] ?? .null),
                "total_cents": any(r["total_cents"] ?? .null),
            ]
        }
        out["receipts"] = receipts

        var items: [String: Any] = [:]
        for r in try db.query(
            """
            SELECT r.retailer, r.external_id, ri.item_key, ri.raw_description, ri.raw_pkg_size,
                   ri.quantity, ri.unit_price_cents, ri.line_total_cents
            FROM receipt_items ri JOIN receipts r ON r.id = ri.receipt_id
            """
        ) {
            let key = join(r, ["retailer", "external_id", "item_key", "raw_description"])
            items[key] = [
                "raw_pkg_size": any(r["raw_pkg_size"] ?? .null),
                "quantity": any(r["quantity"] ?? .null),
                "unit_price_cents": any(r["unit_price_cents"] ?? .null),
                "line_total_cents": any(r["line_total_cents"] ?? .null),
            ]
        }
        out["receipt_items"] = items

        var itemMap: [String: Any] = [:]
        for r in try db.query(
            """
            SELECT m.retailer, m.item_key, m.raw_description,
                   p.canonical_name, p.brand, p.category, p.pkg_size, p.unit, p.is_food,
                   p.is_perishable, p.storage, p.shelf_life_days, p.shelf_life_days_opened,
                   p.shelf_life_source, p.foodkeeper_id
            FROM item_map m LEFT JOIN products p ON p.id = m.product_id
            """
        ) {
            let key = join(r, ["retailer", "item_key"])
            var product: Any = NSNull()
            if r["canonical_name"]?.stringValue != nil {
                var p: [String: Any] = [:]
                for col in [
                    "canonical_name", "brand", "category", "pkg_size", "unit", "is_food",
                    "is_perishable", "storage", "shelf_life_days", "shelf_life_days_opened",
                    "shelf_life_source", "foodkeeper_id",
                ] {
                    p[col] = any(r[col] ?? .null)
                }
                product = p
            }
            itemMap[key] = [
                "raw_description": any(r["raw_description"] ?? .null),
                "product": product,
            ]
        }
        out["item_map"] = itemMap

        var inventory: [String: Any] = [:]
        for r in try db.query(
            """
            SELECT r.retailer, ri.item_key, r.external_id, i.acquired_on,
                   i.quantity, i.remaining_qty, i.unit, i.expires_on, i.location, i.status
            FROM inventory i
            JOIN products p ON p.id = i.product_id
            JOIN item_map m ON m.product_id = p.id
            JOIN receipt_items ri ON ri.id = i.source_receipt_item_id
            JOIN receipts r ON r.id = ri.receipt_id
            """
        ) {
            let key = join(r, ["retailer", "item_key", "acquired_on", "external_id"])
            inventory[key] = [
                "quantity": any(r["quantity"] ?? .null),
                "remaining_qty": any(r["remaining_qty"] ?? .null),
                "unit": any(r["unit"] ?? .null),
                "expires_on": any(r["expires_on"] ?? .null),
                "location": any(r["location"] ?? .null),
                "status": any(r["status"] ?? .null),
            ]
        }
        out["inventory"] = inventory
        return out
    }

    public static func string(_ db: Database) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: try canonical(db), options: [.sortedKeys, .prettyPrinted]
        )
        return String(decoding: data, as: UTF8.self)
    }

    static func join(_ row: [String: SQLValue], _ cols: [String]) -> String {
        cols.map { row[$0]?.stringValue ?? "" }.joined(separator: "|")
    }

    static func any(_ value: SQLValue) -> Any {
        switch value {
        case .null: return NSNull()
        case .int(let i): return i
        case .double(let d): return d
        case .text(let s): return s
        case .blob(let d): return d.base64EncodedString()
        }
    }
}
