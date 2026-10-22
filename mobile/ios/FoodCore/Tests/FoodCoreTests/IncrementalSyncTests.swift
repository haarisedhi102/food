import XCTest
@testable import FoodCore

/// The fetch side uses these queries to decide what is new, so they must be scoped per retailer.
final class IncrementalSyncTests: XCTestCase {
    private func db() throws -> Database {
        let d = try Database.inMemory()
        try Schema.initDB(d)
        return d
    }

    func testKnownExternalIDsAreScopedToRetailer() throws {
        let d = try db()
        try d.run(
            "INSERT INTO receipts (retailer, external_id, purchased_on) VALUES ('kroger', 'k1', '2026-01-01')"
        )
        try d.run(
            "INSERT INTO receipts (retailer, external_id, purchased_on) VALUES ('kroger', 'k2', '2026-01-02')"
        )
        try d.run(
            "INSERT INTO receipts (retailer, external_id, purchased_on) VALUES ('costco', 'c1', '2026-01-03')"
        )

        XCTAssertEqual(try Store.knownExternalIDs(d, retailer: "kroger"), ["k1", "k2"])
        XCTAssertEqual(try Store.knownExternalIDs(d, retailer: "costco"), ["c1"])
        XCTAssertEqual(try Store.knownExternalIDs(d, retailer: "other"), [])
    }

    func testLatestPurchaseDateUsesNewestForRetailer() throws {
        let d = try db()
        try d.run(
            "INSERT INTO receipts (retailer, external_id, purchased_on) VALUES ('kroger', 'k1', '2026-01-01')"
        )
        try d.run(
            "INSERT INTO receipts (retailer, external_id, purchased_on) VALUES ('kroger', 'k2', '2026-02-07')"
        )
        try d.run(
            "INSERT INTO receipts (retailer, external_id, purchased_on) VALUES ('costco', 'c1', '2026-03-09')"
        )

        XCTAssertEqual(try Store.latestPurchaseDate(d, retailer: "kroger"), "2026-02-07")
        XCTAssertEqual(try Store.latestPurchaseDate(d, retailer: "costco"), "2026-03-09")
        XCTAssertNil(try Store.latestPurchaseDate(d, retailer: "other"))
    }
}
