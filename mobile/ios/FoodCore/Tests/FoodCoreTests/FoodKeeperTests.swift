import XCTest
@testable import FoodCore

final class FoodKeeperTests: XCTestCase {
    private func loadFixture() throws -> Any {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "foodkeeper_sample", withExtension: "json", subdirectory: "Fixtures")
        )
        return try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    }

    private func seeded() throws -> Database {
        let db = try Database.inMemory()
        try Schema.initDB(db)
        _ = try FoodKeeper.load(db, payload: try loadFixture())
        return db
    }

    func testToDaysConvertsMetrics() {
        XCTAssertEqual(FoodKeeper.toDays(3, 5, "Weeks"), 21)
        XCTAssertEqual(FoodKeeper.toDays(1, 1, "Months"), 30)
        XCTAssertEqual(FoodKeeper.toDays(1, 2, "Days"), 1)
        XCTAssertNil(FoodKeeper.toDays(3, 3, "Not Recommended"))
        XCTAssertNil(FoodKeeper.toDays(1, 1, "Package use-by date"))
        XCTAssertNil(FoodKeeper.toDays(nil, nil, "Weeks"))
    }

    func testLoadInsertsProductsAndCategories() throws {
        let db = try seeded()
        XCTAssertEqual(try db.query("SELECT COUNT(*) c FROM shelf_life_ref").first?["c"]?.intValue, 4)
        let eggs = try db.query("SELECT * FROM shelf_life_ref WHERE foodkeeper_id = 21").first
        XCTAssertEqual(eggs?["name"]?.stringValue, "Eggs")
        XCTAssertEqual(eggs?["category"]?.stringValue, "Dairy Products & Eggs")
        XCTAssertEqual(eggs?["dop_refrigerate_days"]?.intValue, 21)
        let onions = try db.query("SELECT * FROM shelf_life_ref WHERE foodkeeper_id = 294").first
        XCTAssertEqual(onions?["category"]?.stringValue, "Produce / Fresh Fruits")
        XCTAssertEqual(onions?["pantry_days"]?.intValue, 30)
    }

    func testDaysForPicksStorageColumn() throws {
        let db = try seeded()
        XCTAssertEqual(FoodKeeper.daysFor(db, foodkeeperID: 21, storage: "fridge"), 21)  // eggs
        XCTAssertEqual(FoodKeeper.daysFor(db, foodkeeperID: 27, storage: "freezer"), 90) // milk, 3 Months
        XCTAssertEqual(FoodKeeper.daysFor(db, foodkeeperID: 33, storage: "fridge", opened: true), 1) // yogurt
        XCTAssertEqual(FoodKeeper.daysFor(db, foodkeeperID: 294, storage: "pantry"), 30) // onions
    }

    func testLexicalShortlistRanksByTokenOverlap() throws {
        let db = try seeded()
        let eggs = try Reference.lexicalShortlist(db, query: "Organic Eggs")
        XCTAssertEqual(eggs.first?["foodkeeper_id"]?.intValue, 21)

        let milk = try Reference.lexicalShortlist(db, query: "Whole Milk")
        XCTAssertEqual(milk.first?["foodkeeper_id"]?.intValue, 27)

        XCTAssertTrue(try Reference.lexicalShortlist(db, query: "zzzz").isEmpty)  // no overlap -> empty
    }
}
