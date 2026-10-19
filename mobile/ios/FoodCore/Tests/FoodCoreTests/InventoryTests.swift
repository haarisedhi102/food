import XCTest
@testable import FoodCore

final class InventoryTests: XCTestCase {
    private func seeded() throws -> (Database, productID: Int64, itemID: Int64) {
        let db = try Database.inMemory()
        try Schema.initDB(db)
        try db.run(
            """
            INSERT INTO products (canonical_name, is_food, is_perishable, shelf_life_days, storage)
            VALUES ('Organic A2 Milk', 1, 1, 7, 'fridge')
            """
        )
        let pid = db.lastInsertRowID
        try db.run(
            "INSERT INTO receipts (retailer, external_id, purchased_on) VALUES ('kroger', 'k1', '2026-01-01')"
        )
        let rid = db.lastInsertRowID
        try db.run(
            "INSERT INTO receipt_items (receipt_id, raw_description, item_key, quantity) VALUES (?, 'milk', 'upc1', 1)",
            [.int(rid)]
        )
        let riid = db.lastInsertRowID
        try db.run(
            "INSERT INTO item_map (retailer, item_key, raw_description, product_id) VALUES ('kroger', 'upc1', 'milk', ?)",
            [.int(pid)]
        )
        return (db, pid, riid)
    }

    func testBuildCreatesRowExpiringOnPurchasePlusShelfLife() throws {
        let (db, _, _) = try seeded()
        XCTAssertEqual(try Inventory.build(db), 1)
        // idempotent
        XCTAssertEqual(try Inventory.build(db), 0)

        let rows = try db.query("SELECT expires_on, status FROM inventory")
        XCTAssertEqual(rows.first?["expires_on"]?.stringValue, "2026-01-08")
        XCTAssertEqual(rows.first?["status"]?.stringValue, "active")
    }

    func testRefreshExpiresThenArchives() throws {
        let (db, _, _) = try seeded()
        try Inventory.build(db)

        // just past expiry, but within the 14-day archive window
        let res = try Inventory.refreshStatus(db, today: "2026-01-10", archiveAfterDays: 14)
        XCTAssertEqual(res.expired, 1)
        XCTAssertEqual(res.archived, 0)

        // now well past the archive cutoff
        let res2 = try Inventory.refreshStatus(db, today: "2026-03-01", archiveAfterDays: 14)
        XCTAssertEqual(res2.archived, 1)
        let status = try db.query("SELECT status FROM inventory").first?["status"]?.stringValue
        XCTAssertEqual(status, "archived")
    }

    func testExpiringSoonHorizon() throws {
        let (db, _, _) = try seeded()
        try Inventory.build(db)

        let soon = try Inventory.expiringSoon(db, days: 3, today: "2026-01-06")
        XCTAssertEqual(soon.count, 1)  // 01-08 <= 01-09

        let none = try Inventory.expiringSoon(db, days: 3, today: "2026-01-01")
        XCTAssertEqual(none.count, 0)  // 01-08 > 01-04
    }

    func testFIFOConsumeAndStatus() throws {
        let (db, pid, _) = try seeded()
        try Inventory.build(db)
        let applied = try Inventory.consumeFIFO(db, productID: Int(pid), qty: 1)
        XCTAssertEqual(applied, 1)
        let status = try db.query("SELECT status, remaining_qty FROM inventory").first
        XCTAssertEqual(status?["status"]?.stringValue, "consumed")
        XCTAssertEqual(status?["remaining_qty"]?.doubleValue, 0)
    }
}
