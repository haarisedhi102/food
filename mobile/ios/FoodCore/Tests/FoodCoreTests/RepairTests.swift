import XCTest
@testable import FoodCore

/// Raw-name fallbacks are recoverable: dropping the placeholder product and its mapping makes
/// the receipt line pending again, so a retry can classify it.
final class RepairTests: XCTestCase {
    func testRepairFallbacksReopensTheReceiptLine() throws {
        let db = try Database.inMemory()
        try Schema.initDB(db)

        try db.run(
            "INSERT INTO receipts (retailer, external_id, purchased_on) "
                + "VALUES ('costco', 'r1', '2026-10-09')"
        )
        let receiptID = db.lastInsertRowID
        try db.run(
            "INSERT INTO receipt_items (receipt_id, raw_description, item_key, quantity) "
                + "VALUES (?, 'PASTURE EGGS', 'k1', 1)",
            [.int(receiptID)]
        )
        let receiptItemID = db.lastInsertRowID
        try db.run(
            "INSERT INTO products (canonical_name, is_food, is_perishable, llm_confidence) "
                + "VALUES ('PASTURE EGGS', 1, 0, 0.0)"
        )
        let productID = db.lastInsertRowID
        try db.run(
            "INSERT INTO item_map (retailer, item_key, raw_description, product_id) "
                + "VALUES ('costco', 'k1', 'PASTURE EGGS', ?)",
            [.int(productID)]
        )
        try db.run(
            "INSERT INTO inventory (product_id, quantity, remaining_qty, acquired_on, status, "
                + "source_receipt_item_id) VALUES (?, 1, 1, '2026-10-09', 'active', ?)",
            [.int(productID), .int(receiptItemID)]
        )

        XCTAssertEqual(try Canonicalize.pendingCount(db), 0)
        XCTAssertEqual(try Canonicalize.repairableCount(db), 1)

        XCTAssertEqual(try Canonicalize.repairFallbacks(db), 1)

        XCTAssertEqual(try Canonicalize.pendingCount(db), 1)
        XCTAssertEqual(try Canonicalize.repairableCount(db), 1)
        XCTAssertEqual(try db.query("SELECT COUNT(*) n FROM inventory").first?["n"]?.intValue, 0)
    }
}
