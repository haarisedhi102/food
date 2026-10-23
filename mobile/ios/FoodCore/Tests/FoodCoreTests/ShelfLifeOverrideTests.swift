import XCTest
@testable import FoodCore

final class ShelfLifeOverrideTests: XCTestCase {
    private func db() throws -> Database {
        let d = try Database.inMemory()
        try Schema.initDB(d)
        return d
    }

    @discardableResult
    private func product(
        _ d: Database, name: String = "Milk", days: Int? = nil, source: String? = nil,
        needsReview: Int = 0, perishable: Int = 1, storage: String? = "fridge"
    ) throws -> Int {
        try d.run(
            """
            INSERT INTO products
                (canonical_name, is_food, is_perishable, storage, shelf_life_days,
                 shelf_life_source, needs_review)
            VALUES (?, 1, ?, ?, ?, ?, ?)
            """,
            [
                .text(name), .int(Int64(perishable)),
                storage.map { SQLValue.text($0) } ?? .null,
                days.map { SQLValue.int(Int64($0)) } ?? .null,
                source.map { SQLValue.text($0) } ?? .null,
                .int(Int64(needsReview)),
            ]
        )
        return Int(d.lastInsertRowID)
    }

    private func row(_ d: Database, _ id: Int) throws -> [String: SQLValue] {
        try XCTUnwrap(d.query("SELECT * FROM products WHERE id = ?", [.int(Int64(id))]).first)
    }

    private func auto(_ pid: Int, days: Int) -> ShelfLifeAgent.ItemVerdict {
        ShelfLifeAgent.ItemVerdict(
            itemID: pid, source: "llm", shelfLifeDays: days, shelfLifeDaysOpened: nil,
            storage: nil, isPerishable: true, confidence: 0.5
        )
    }

    func testSavingTwiceUpdatesAUserValue() throws {
        let d = try db()
        let pid = try product(d)

        XCTAssertEqual(try ShelfLifeAgent.setUserShelfLife(d, productID: pid, days: 10), 1)
        XCTAssertEqual(try ShelfLifeAgent.setUserShelfLife(d, productID: pid, days: 12), 1)

        let p = try row(d, pid)
        XCTAssertEqual(p["shelf_life_days"]?.intValue, 12)
        XCTAssertEqual(p["shelf_life_source"]?.stringValue, "user")
        XCTAssertEqual(p["needs_review"]?.intValue, 0)
    }

    func testApplySkipsAnUnflaggedUserValue() throws {
        let d = try db()
        let pid = try product(d)
        try ShelfLifeAgent.setUserShelfLife(d, productID: pid, days: 10)

        let applied = try ShelfLifeAgent.apply(
            d, items: [["id": pid]], verdicts: [pid: auto(pid, days: 3)]
        )

        XCTAssertEqual(applied, 0)
        XCTAssertEqual(try row(d, pid)["shelf_life_days"]?.intValue, 10)
    }

    func testFlaggedUserValueIsOverwrittenAndCleared() throws {
        let d = try db()
        let pid = try product(d)
        try ShelfLifeAgent.setUserShelfLife(d, productID: pid, days: 10)
        try ShelfLifeAgent.flagForReview(d, productID: pid)

        let applied = try ShelfLifeAgent.apply(
            d, items: [["id": pid]], verdicts: [pid: auto(pid, days: 3)]
        )

        XCTAssertEqual(applied, 1)
        let p = try row(d, pid)
        XCTAssertEqual(p["shelf_life_days"]?.intValue, 3)
        XCTAssertEqual(p["shelf_life_source"]?.stringValue, "llm")
        XCTAssertEqual(p["needs_review"]?.intValue, 0)
    }

    func testSavingWhileFlaggedClearsTheFlag() throws {
        let d = try db()
        let pid = try product(d, needsReview: 1)

        XCTAssertEqual(try ShelfLifeAgent.setUserShelfLife(d, productID: pid, days: 9), 1)
        XCTAssertEqual(try row(d, pid)["needs_review"]?.intValue, 0)
    }

    func testOpenedDaysArePreservedWhenNotSupplied() throws {
        let d = try db()
        let pid = try product(d)

        try ShelfLifeAgent.setUserShelfLife(d, productID: pid, days: 10, openedDays: 4)
        try ShelfLifeAgent.setUserShelfLife(d, productID: pid, days: 12)

        XCTAssertEqual(try row(d, pid)["shelf_life_days_opened"]?.intValue, 4)
    }

    func testUserValueUpdatesActiveInventoryExpiry() throws {
        let d = try db()
        let pid = try product(d)
        try d.run(
            """
            INSERT INTO inventory (product_id, quantity, remaining_qty, acquired_on, status)
            VALUES (?, 1, 1, '2026-10-10', 'active')
            """,
            [.int(Int64(pid))]
        )

        try ShelfLifeAgent.setUserShelfLife(d, productID: pid, days: 10)

        let expires = try d.query(
            "SELECT expires_on FROM inventory WHERE product_id = ?", [.int(Int64(pid))]
        ).first?["expires_on"]?.stringValue
        XCTAssertEqual(expires, "2026-10-20")
    }

    func testResolveMissingSelectsFlaggedButNotPinned() async throws {
        let d = try db()
        let pinned = try product(d, name: "Pinned", days: 7, source: "user")
        let flagged = try product(
            d, name: "Flagged", days: 7, source: "user", needsReview: 1
        )
        let gap = try product(d, name: "Gap")

        let stats = try await ShelfLifeAgent.resolveMissing(
            d,
            provider: ScriptedProvider(completions: [
                ChatCompletion(content: "notes", toolCalls: [], model: "fake"),
                verdictCall([(pinned, 3), (flagged, 3), (gap, 3)]),
            ]),
            search: { _ in "results" }
        )

        XCTAssertEqual(stats.resolved, 2)
        XCTAssertEqual(try row(d, pinned)["shelf_life_days"]?.intValue, 7)
        XCTAssertEqual(try row(d, flagged)["shelf_life_source"]?.stringValue, "llm")
        XCTAssertEqual(try row(d, flagged)["needs_review"]?.intValue, 0)
        XCTAssertEqual(try row(d, gap)["shelf_life_source"]?.stringValue, "llm")
    }

    func testRefreshSelectsEveryUnpinnedProduct() async throws {
        let d = try db()
        let pinned = try product(d, name: "Pinned", days: 7, source: "user")
        let automatic = try product(d, name: "Automatic", days: 20, source: "llm")

        let stats = try await ShelfLifeAgent.resolveMissing(
            d,
            provider: ScriptedProvider(completions: [
                ChatCompletion(content: "notes", toolCalls: [], model: "fake"),
                verdictCall([(pinned, 3), (automatic, 3)]),
            ]),
            refresh: true,
            search: { _ in "results" }
        )

        XCTAssertEqual(stats.resolved, 1)
        XCTAssertEqual(try row(d, pinned)["shelf_life_days"]?.intValue, 7)
        XCTAssertEqual(try row(d, automatic)["shelf_life_days"]?.intValue, 3)
    }

    func testRepairPreservesAUserSetFallback() throws {
        let d = try db()
        let user = try product(d, name: "Raw receipt text", days: 7, source: "user")
        let fallback = try product(d, name: "Another raw line")
        for (pid, key) in [(user, "user-key"), (fallback, "fallback-key")] {
            try d.run(
                """
                INSERT INTO item_map (retailer, item_key, raw_description, product_id)
                VALUES ('kroger', ?, 'raw', ?)
                """,
                [.text(key), .int(Int64(pid))]
            )
        }

        XCTAssertEqual(try Canonicalize.repairableCount(d), 1)
        XCTAssertEqual(try Canonicalize.repairFallbacks(d), 1)

        XCTAssertNotNil(try row(d, user)["id"])
        XCTAssertTrue(try d.query("SELECT * FROM products WHERE id = ?", [.int(Int64(fallback))]).isEmpty)
    }

    private func verdictCall(_ items: [(Int, Int)]) -> ChatCompletion {
        let payload: [String: Any] = [
            "items": items.map { id, days in
                [
                    "item_id": id, "source": "llm", "shelf_life_days": days,
                    "is_perishable": true, "storage": "fridge", "confidence": 0.5,
                ] as [String: Any]
            }
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return ChatCompletion(
            content: nil,
            toolCalls: [ToolCall(
                id: "v1", name: ShelfLifeAgent.verdictToolName,
                arguments: String(data: data, encoding: .utf8)!
            )],
            model: "fake"
        )
    }
}
