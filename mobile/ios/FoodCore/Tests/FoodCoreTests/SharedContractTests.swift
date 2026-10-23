import XCTest
@testable import FoodCore

private final class SharedFakeJev: JevProvider, @unchecked Sendable {
    let response: JevResponse
    init(_ response: JevResponse) { self.response = response }
    func decide(state: [String: Any], questions: [String: Any]) async throws -> JevResponse {
        response
    }
}

final class SharedContractTests: XCTestCase {
    private func fixture(_ name: String) throws -> [String: Any] {
        guard let data = SharedContract.fixtureData(name),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw XCTSkip("missing shared fixture \(name)")
        }
        return object
    }

    func testSharedResourcesLoaded() throws {
        XCTAssertFalse(SharedContract.prompts["canonicalize"]?.isEmpty ?? true)
        XCTAssertFalse(SharedContract.prompts["research"]?.isEmpty ?? true)
        XCTAssertFalse(SharedContract.jev.dayCriteria.isEmpty)
        XCTAssertFalse(SharedContract.jev.storageCriteria.isEmpty)
        XCTAssertFalse(SharedContract.costcoQuery.isEmpty)
        XCTAssertTrue(try SharedContract.schemaSQL().contains("CREATE TABLE IF NOT EXISTS products"))
    }

    func testSchemaUsesSharedDDL() throws {
        let db = try Database.inMemory()
        try Schema.initDB(db)
        let rows = try db.query(
            "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
        )
        let names = Set(rows.compactMap { $0["name"]?.stringValue })
        XCTAssertTrue(names.contains("products"))
        XCTAssertTrue(names.contains("shelf_life_embedding"))
        let version = try db.query("SELECT version FROM schema_version").first?["version"]?.intValue
        XCTAssertEqual(version, 2)
    }

    func testNormalizeCostcoGolden() throws {
        let fixture = try fixture("normalize_costco")
        let receipts = Normalizer.normalizeCostco(fixture["raw"] as Any)
        let expected = try XCTUnwrap(fixture["expected"] as? [String: Any])
        let receipt = try XCTUnwrap(receipts.first)
        XCTAssertEqual(receipt.externalID, expected["external_id"] as? String)
        XCTAssertEqual(receipt.purchasedOn, expected["purchased_on"] as? String)
        XCTAssertEqual(receipt.store, expected["store"] as? String)
        XCTAssertEqual(receipt.totalCents, expected["total_cents"] as? Int)
        let expectedItems = try XCTUnwrap(expected["items"] as? [[String: Any]])
        XCTAssertEqual(receipt.items.count, expectedItems.count)
        let item = try XCTUnwrap(receipt.items.first)
        let expectedItem = try XCTUnwrap(expectedItems.first)
        XCTAssertEqual(item.rawDescription, expectedItem["raw_description"] as? String)
        XCTAssertEqual(item.itemKey, expectedItem["item_key"] as? String)
        XCTAssertEqual(item.quantity, expectedItem["quantity"] as? Double)
        XCTAssertEqual(item.unitPriceCents, expectedItem["unit_price_cents"] as? Int)
        XCTAssertEqual(item.lineTotalCents, expectedItem["line_total_cents"] as? Int)

        let db = try Database.inMemory()
        try Schema.initDB(db)
        _ = try Store.store(db, retailer: "costco", receipts: receipts)
        let stored = try db.query("SELECT raw_json FROM receipts").first
        XCTAssertNotNil(stored?["raw_json"]?.stringValue)
    }

    func testRRFGolden() throws {
        let fixture = try fixture("rrf")
        let lists = try XCTUnwrap(fixture["lists"] as? [[Int]])
        let weights = try XCTUnwrap(fixture["weights"] as? [Double])
        let c = try XCTUnwrap(fixture["c"] as? Double)
        let expected = try XCTUnwrap(fixture["expected"] as? [Int])
        XCTAssertEqual(
            Reference.reciprocalRankFusion(lists, weights: weights, c: c), expected
        )
    }

    func testJevVerdictsGolden() async throws {
        let fixture = try fixture("jev_verdicts")
        let items = try XCTUnwrap(fixture["items"] as? [[String: Any]])
        let rawShortlists = try XCTUnwrap(fixture["shortlists"] as? [String: [[String: Any]]])
        let shortlists = Dictionary(uniqueKeysWithValues: rawShortlists.map {
            (Int($0.key)!, $0.value)
        })
        let answersData = try JSONSerialization.data(
            withJSONObject: try XCTUnwrap(fixture["answers"])
        )
        let answers = try JSONDecoder().decode([String: JevAnswer].self, from: answersData)
        let response = JevResponse(
            model: "fixture", answers: answers, usage: nil, requestID: nil
        )
        let expected = try XCTUnwrap(fixture["expected"] as? [String: [String: Any]])

        let verdicts = await ShelfLifeAgent.jevVerdicts(
            items, shortlists: shortlists, findings: "fixture notes",
            jev: SharedFakeJev(response)
        )
        for (key, want) in expected {
            let id = try XCTUnwrap(Int(key))
            let got = try XCTUnwrap(verdicts[id])
            XCTAssertEqual(got.source, want["source"] as? String, "source \(id)")
            XCTAssertEqual(
                got.shelfLifeDays, want["shelf_life_days"] as? Int,
                "days \(id)"
            )
            XCTAssertEqual(got.storage, want["storage"] as? String, "storage \(id)")
            XCTAssertEqual(
                got.isPerishable, want["is_perishable"] as? Bool,
                "perishable \(id)"
            )
            XCTAssertEqual(
                got.confidence, want["confidence"] as? Double ?? 0,
                accuracy: 0.0001, "confidence \(id)"
            )
        }
    }
}
