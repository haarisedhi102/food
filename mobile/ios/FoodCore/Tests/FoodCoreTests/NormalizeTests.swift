import XCTest
@testable import FoodCore

/// Conformance: the ported normalizers must reproduce the Python tests'
/// expectations on the same redacted fixtures (`tests/test_normalize.py`,
/// `tests/test_schema_drift.py`). This is the safety net for the port.
final class NormalizeTests: XCTestCase {
    private func load(_ name: String) throws -> Any {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
            "missing fixture \(name)"
        )
        return try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    }

    func testCostcoNormalizeDropsDiscountsAndKeysOnItemNumber() throws {
        let raw = try load("costco_sample.redacted")
        let receipts = Normalizer.normalizeCostco(raw)

        XCTAssertEqual(receipts.count, 1)
        let r = try XCTUnwrap(receipts.first)
        XCTAssertEqual(r.purchasedOn?.count, 10)
        XCTAssertFalse(r.items.isEmpty, "expected at least one item")

        for item in r.items {
            XCTAssertFalse(item.rawDescription.hasPrefix("/"), "discount line survived")
            XCTAssertFalse(item.itemKey.isEmpty)
        }

        // the fixture has a "/ <item>" discount line; it must not survive
        let rawReceipt = try XCTUnwrap(
            ((raw as? [String: Any])?["data"] as? [String: Any])?["receiptsWithCounts"]
                as? [String: Any]
        )
        let rawItems = try XCTUnwrap(rawReceipt["receipts"] as? [Any]).first as? [String: Any]
        let itemArray = try XCTUnwrap(rawItems?["itemArray"] as? [Any])
        XCTAssertLessThan(r.items.count, itemArray.count)
    }

    func testKrogerAttributesOnlyTheMatchingReceipt() throws {
        let raw = try load("kroger_sample.redacted")
        let receipts = Normalizer.normalizeKroger(raw)

        XCTAssertEqual(receipts.count, 1)
        let r = try XCTUnwrap(receipts.first)

        let details = try XCTUnwrap((raw as? [String: Any])?["details"] as? [String: Any])
        let firstPayload = try XCTUnwrap(details.values.first as? [String: Any])
        let batch = try XCTUnwrap(
            ((firstPayload["json"] as? [String: Any])?["data"] as? [String: Any])?["purchaseHistoryDetails"]
                as? [Any]
        )
        let totalInBatch = batch.reduce(0) { acc, node in
            acc + (((node as? [String: Any])?["items"] as? [Any])?.count ?? 0)
        }
        let matching = batch.first { node in
            ((node as? [String: Any])?["purchaseId"] as? [String: Any])?["receiptId"]
                .flatMap { Normalizer.str($0) } == r.externalID
        }
        let matchingCount = ((matching as? [String: Any])?["items"] as? [Any])?.count ?? 0

        XCTAssertEqual(r.items.count, matchingCount)
        XCTAssertLessThan(r.items.count, totalInBatch, "items leaked from other receipts in the batch")
        for item in r.items { XCTAssertFalse(item.itemKey.isEmpty) }
    }

    func testCentsAndDateHelpers() {
        XCTAssertEqual(Normalizer.cents(12.5), 1250)
        XCTAssertEqual(Normalizer.cents("$12.99"), 1299)
        XCTAssertEqual(Normalizer.cents("-3.00"), -300)
        XCTAssertNil(Normalizer.cents(nil))
        XCTAssertEqual(Normalizer.localDate("2026-10-17T12:00:00Z"), "2026-10-17")
        XCTAssertEqual(Normalizer.localDate("10/17/2026"), "2026-10-17")
        XCTAssertNil(Normalizer.localDate(nil))
    }
}
