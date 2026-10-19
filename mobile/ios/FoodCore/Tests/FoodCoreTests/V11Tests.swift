import XCTest
@testable import FoodCore

/// Provider double with a scripted sequence of `chat` completions plus a canned text reply.
final class ScriptedProvider: LLMProvider, @unchecked Sendable {
    var completions: [ChatCompletion]
    var text: String
    private(set) var chatCalls = 0

    init(completions: [ChatCompletion] = [], text: String = "canned") {
        self.completions = completions
        self.text = text
    }

    func chatJSON(system: String, user: String, temperature: Double) async throws -> ChatResponse {
        throw LLMError.badResponse("not used")
    }

    func embed(_ texts: [String]) async throws -> [[Float]] { [] }

    func chatText(system: String, user: String, temperature: Double) async throws -> String { text }

    func chat(messages: [[String: Any]], tools: [[String: Any]]?, temperature: Double) async throws -> ChatCompletion {
        let c = completions[min(chatCalls, max(completions.count - 1, 0))]
        chatCalls += 1
        return c
    }
}

final class Recorder: @unchecked Sendable {
    var queries: [String] = []
}

final class V11Tests: XCTestCase {
    private func db() throws -> Database {
        let d = try Database.inMemory()
        try Schema.initDB(d)
        return d
    }

    private func seedProduct(_ d: Database, name: String = "Milk", perishable: Int = 1, shelf: Int? = nil) throws -> Int64 {
        try d.run(
            "INSERT INTO products (canonical_name, is_food, is_perishable, shelf_life_days, storage) VALUES (?, 1, ?, ?, 'fridge')",
            [.text(name), .int(Int64(perishable)), shelf.map { SQLValue.int(Int64($0)) } ?? .null]
        )
        return d.lastInsertRowID
    }

    // MARK: - Shelf-life agent

    func testAgentCallsWebSearchThenAnswersJSON() async throws {
        let recorder = Recorder()
        let toolCall = ChatCompletion(
            content: nil,
            toolCalls: [ToolCall(id: "c1", name: "web_search", arguments: #"{"query":"milk shelf life"}"#)],
            model: "fake"
        )
        let answer = ChatCompletion(
            content: #"{"is_perishable":true,"storage":"fridge","shelf_life_days":7,"confidence":0.9,"rationale":"ok"}"#,
            toolCalls: [],
            model: "fake"
        )
        let provider = ScriptedProvider(completions: [toolCall, answer])

        let guess = try await ShelfLifeAgent.resolve(
            name: "Milk", provider: provider,
            search: { query in recorder.queries.append(query); return "results" }
        )
        XCTAssertEqual(guess?.shelfLifeDays, 7)
        XCTAssertEqual(guess?.storage, "fridge")
        XCTAssertEqual(recorder.queries, ["milk shelf life"])
    }

    func testResolveMissingWritesShelfLifeAndInventoryExpiry() async throws {
        let d = try db()
        let pid = try seedProduct(d)
        try d.run(
            "INSERT INTO inventory (product_id, quantity, remaining_qty, acquired_on, status) VALUES (?, 1, 1, '2026-01-01', 'active')",
            [.int(pid)]
        )
        let answer = ChatCompletion(
            content: #"{"is_perishable":true,"storage":"fridge","shelf_life_days":7,"confidence":0.9}"#,
            toolCalls: [], model: "fake"
        )
        let stats = try await ShelfLifeAgent.resolveMissing(
            d, provider: ScriptedProvider(completions: [answer]), search: { _ in "" }
        )
        XCTAssertEqual(stats.resolved, 1)

        let product = try d.query("SELECT shelf_life_days, shelf_life_source FROM products").first
        XCTAssertEqual(product?["shelf_life_days"]?.intValue, 7)
        XCTAssertEqual(product?["shelf_life_source"]?.stringValue, "web")
        let inv = try d.query("SELECT expires_on FROM inventory").first
        XCTAssertEqual(inv?["expires_on"]?.stringValue, "2026-01-08")
    }

    // MARK: - Chat / digest

    func testChatAskReturnsProviderText() async throws {
        let d = try db()
        let pid = try seedProduct(d, name: "Milk")
        try d.run(
            "INSERT INTO inventory (product_id, quantity, remaining_qty, acquired_on, expires_on, location, status) VALUES (?, 1, 1, '2026-01-01', '2026-01-05', 'fridge', 'active')",
            [.int(pid)]
        )
        let answer = try await Chat.ask(d, question: "What should I use?", provider: ScriptedProvider(text: "Use the milk."))
        XCTAssertEqual(answer, "Use the milk.")
    }

    func testDigestNilWhenNothingExpiring() async throws {
        let d = try db()
        let text = try await Chat.digest(d, days: 3, provider: ScriptedProvider(text: "x"))
        XCTAssertNil(text)
    }

    // MARK: - Item detail / price history

    func testPricePointsFromPurchaseHistory() throws {
        let d = try db()
        let pid = try seedProduct(d)
        for (i, cents) in [199, 249].enumerated() {
            try d.run(
                "INSERT INTO receipts (retailer, external_id, purchased_on) VALUES ('kroger', ?, ?)",
                [.text("r\(i)"), .text("2026-01-0\(i + 1)")]
            )
            let rid = d.lastInsertRowID
            try d.run(
                "INSERT INTO receipt_items (receipt_id, raw_description, item_key, unit_price_cents) VALUES (?, 'milk', 'upc1', ?)",
                [.int(rid), .int(Int64(cents))]
            )
            try d.run(
                "INSERT OR IGNORE INTO item_map (retailer, item_key, raw_description, product_id) VALUES ('kroger', 'upc1', 'milk', ?)",
                [.int(pid)]
            )
        }
        let points = try ItemDetail.pricePoints(d, productID: Int(pid))
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points.map { $0["date"] as? String }, ["2026-01-01", "2026-01-02"])
        XCTAssertEqual(points.compactMap { $0["price"] as? Double }, [1.99, 2.49])
    }
}
