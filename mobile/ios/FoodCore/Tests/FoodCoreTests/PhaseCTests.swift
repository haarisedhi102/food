import XCTest
@testable import FoodCore

/// A provider stub so the LLM-dependent ports are testable without network.
final class FakeProvider: LLMProvider, @unchecked Sendable {
    var chatResponses: [[String: Any]]
    var embedVectors: [[Float]]
    private(set) var chatCalls = 0

    init(chatResponses: [[String: Any]] = [], embedVectors: [[Float]] = []) {
        self.chatResponses = chatResponses
        self.embedVectors = embedVectors
    }

    func chatJSON(system: String, user: String, temperature: Double) async throws -> ChatResponse {
        let idx = min(chatCalls, chatResponses.count - 1)
        chatCalls += 1
        guard idx >= 0 else { throw LLMError.badResponse("no canned response") }
        return ChatResponse(json: chatResponses[idx], model: "fake-model")
    }

    func embed(_ texts: [String]) async throws -> [[Float]] {
        Array(embedVectors.prefix(texts.count))
    }

    /// Keeps canonicalization tests fast: research yields notes, synthesis yields an empty
    /// verdict, so the resolver has nothing to apply and never retries.
    func chat(
        messages: [[String: Any]], tools: [[String: Any]]?, temperature: Double, forceTool: String?
    ) async throws -> ChatCompletion {
        let system = messages.first { ($0["role"] as? String) == "system" }?["content"] as? String
        if system == ShelfLifeAgent.researchSystem {
            return ChatCompletion(content: "notes", toolCalls: [], model: "fake-model")
        }
        return ChatCompletion(
            content: nil,
            toolCalls: [ToolCall(
                id: "v1",
                name: ShelfLifeAgent.verdictToolName,
                arguments: #"{"items":[]}"#
            )],
            model: "fake-model"
        )
    }
}

final class PhaseCTests: XCTestCase {
    private func db() throws -> Database {
        let d = try Database.inMemory()
        try Schema.initDB(d)
        return d
    }

    // MARK: - JSON extraction

    func testExtractJSONHandlesFencesAndProse() throws {
        XCTAssertEqual(try JSONExtract.extract("{\"a\":1}")["a"] as? Int, 1)
        XCTAssertEqual(try JSONExtract.extract("```json\n{\"a\":2}\n```")["a"] as? Int, 2)
        XCTAssertEqual(try JSONExtract.extract("Here you go: {\"a\":3} done")["a"] as? Int, 3)
        XCTAssertThrowsError(try JSONExtract.extract("no json here"))
    }

    // MARK: - Reciprocal rank fusion

    func testReciprocalRankFusionPrefersDocsInBothLists() {
        let fused = Reference.reciprocalRankFusion([[1, 2], [2, 3]], weights: [0.5, 0.5])
        // id 2 appears in both (rank 1 and rank 0) -> wins; then 1 (rank 0) beats 3 (rank 1)
        XCTAssertEqual(fused, [2, 1, 3])
    }

    // MARK: - Canonicalization

    func testCanonicalizeStoresProductAndCachesItemMap() async throws {
        let d = try db()
        try d.run("INSERT INTO receipts (retailer, external_id, purchased_on) VALUES ('kroger','k1','2026-01-01')")
        let rid = d.lastInsertRowID
        try d.run(
            "INSERT INTO receipt_items (receipt_id, raw_description, item_key, quantity) VALUES (?, 'Horizon Organic Whole Milk', 'upc1', 1)",
            [.int(rid)]
        )
        XCTAssertEqual(try Canonicalize.pendingCount(d), 1)

        let provider = FakeProvider(chatResponses: [[
            "items": [[
                "item_key": "upc1",
                "canonical_name": "Organic Whole Milk",
                "brand": "Horizon",
                "category": "Dairy Products & Eggs",
                "is_food": true,
                "is_perishable": true,
                "storage": "fridge",
                "shelf_life_days": 7,
                "confidence": 0.9,
            ]]
        ]])
        let stats = try await Canonicalize.canonicalize(d, provider: provider)
        XCTAssertEqual(stats.ok, 1)
        XCTAssertEqual(try Canonicalize.pendingCount(d), 0)

        let product = try d.query("SELECT * FROM products").first
        XCTAssertEqual(product?["canonical_name"]?.stringValue, "Organic Whole Milk")
        // Shelf life is resolved by ShelfLifeAgent afterwards, not during canonicalization.
        XCTAssertNil(product?["shelf_life_days"]?.intValue)
        XCTAssertNil(product?["shelf_life_source"]?.stringValue)
        XCTAssertEqual(try d.query("SELECT COUNT(*) c FROM item_map").first?["c"]?.intValue, 1)
    }

    func testCanonicalizeFallbackKeepsPipelineMoving() async throws {
        let d = try db()
        try d.run("INSERT INTO receipts (retailer, external_id, purchased_on) VALUES ('kroger','k1','2026-01-01')")
        try d.run(
            "INSERT INTO receipt_items (receipt_id, raw_description, item_key, quantity) VALUES (?, 'Weird Item', 'upc9', 1)",
            [.int(d.lastInsertRowID)]
        )
        // provider always returns an empty item list -> the item falls through to a placeholder
        let provider = FakeProvider(chatResponses: [["items": []]])
        let stats = try await Canonicalize.canonicalize(d, provider: provider)
        XCTAssertEqual(stats.ok, 0)
        XCTAssertEqual(stats.fallback, 1)
        let product = try d.query("SELECT canonical_name FROM products").first
        XCTAssertEqual(product?["canonical_name"]?.stringValue, "Weird Item")
    }

    // MARK: - Hybrid retrieval

    func testHybridShortlistFusesLexicalAndVector() async throws {
        let d = try db()
        try d.run("INSERT INTO shelf_life_ref (foodkeeper_id, name, keywords) VALUES (1, 'Eggs', 'eggs shell')")
        try d.run("INSERT INTO shelf_life_ref (foodkeeper_id, name, keywords) VALUES (2, 'Milk', 'milk dairy')")
        try d.run(
            "INSERT INTO shelf_life_embedding (foodkeeper_id, model, dim, vector) VALUES (1, 'm', 2, ?)",
            [.blob(Reference.pack([1, 0]))]
        )
        try d.run(
            "INSERT INTO shelf_life_embedding (foodkeeper_id, model, dim, vector) VALUES (2, 'm', 2, ?)",
            [.blob(Reference.pack([0, 1]))]
        )
        let provider = FakeProvider(embedVectors: [[1, 0]])  // query "eggs"

        let hybrid = try await Reference.hybridShortlist(d, query: "eggs", limit: 5, provider: provider, model: "m")
        XCTAssertEqual(hybrid.first?["foodkeeper_id"]?.intValue, 1)

        // without a provider/model it degrades to lexical-only
        let lexical = try await Reference.hybridShortlist(d, query: "eggs", limit: 5)
        XCTAssertEqual(lexical.first?["foodkeeper_id"]?.intValue, 1)
        XCTAssertEqual(lexical.count, 1)  // "Milk" shares no token
    }
}
