import Foundation

/// Structured verdict from the shelf-life agent (port of `shelflife_agent.ShelfLifeGuess`).
public struct ShelfLifeGuess: Codable, Equatable {
    public var isPerishable: Bool
    public var storage: String?
    public var shelfLifeDays: Int?
    public var shelfLifeDaysOpened: Int?
    public var confidence: Double
    public var rationale: String?

    enum CodingKeys: String, CodingKey {
        case isPerishable = "is_perishable"
        case storage
        case shelfLifeDays = "shelf_life_days"
        case shelfLifeDaysOpened = "shelf_life_days_opened"
        case confidence, rationale
    }

    init(from dict: [String: Any]) {
        func intOrNil(_ v: Any?) -> Int? {
            if let i = v as? Int { return i }
            if let d = v as? Double { return Int(d) }
            return nil
        }
        isPerishable = (dict["is_perishable"] as? Bool) ?? true
        storage = dict["storage"] as? String
        shelfLifeDays = intOrNil(dict["shelf_life_days"])
        shelfLifeDaysOpened = intOrNil(dict["shelf_life_days_opened"])
        confidence = (dict["confidence"] as? Double) ?? 0.5
        rationale = dict["rationale"] as? String
    }
}

/// Port of `food/shelflife_agent.py`. A tool-calling agent answers from its own knowledge and
/// searches the web only when it needs to; we trust the result. The value is written back to the
/// product and to any inventory rows already built from it.
public enum ShelfLifeAgent {
    public static let system = """
    You determine how long a grocery item keeps after purchase, and where it should be stored.
    Answer from your own knowledge when you are confident. Use the web_search tool only when you need
    to — an unusual or ambiguous item, an abbreviated receipt line, or guidance you might be
    misremembering. If you do search, prefer authoritative sources (USDA/FoodKeeper, food-safety
    agencies, manufacturers) over blogs. Express shelf life in whole days. If the item does not spoil
    (dry goods, canned, spices), set is_perishable false and shelf_life_days null. Set confidence to
    reflect how sure you are of the final answer.

    Respond with ONLY JSON:
    {"is_perishable": bool, "storage": "fridge"|"freezer"|"pantry"|"counter"|null,
     "shelf_life_days": int|null, "shelf_life_days_opened": int|null,
     "confidence": number, "rationale": string|null}
    """

    public typealias Search = @Sendable (String) async -> String

    public static let webSearchTool: [String: Any] = [
        "type": "function",
        "function": [
            "name": "web_search",
            "description": "Search the web for grocery storage and shelf-life guidance.",
            "parameters": [
                "type": "object",
                "properties": ["query": ["type": "string", "description": "The search query."]],
                "required": ["query"],
            ],
        ],
    ]

    /// Ask the agent how long `name` keeps. Returns nil if it produced no verdict.
    public static func resolve(
        name: String,
        description: String? = nil,
        category: String? = nil,
        provider: LLMProvider,
        search: Search = { await WebSearch.duckDuckGo($0) },
        maxRounds: Int = 3
    ) async throws -> ShelfLifeGuess? {
        let prompt = """
        Item: \(name)
        Receipt text: \(description ?? "(none)")
        Category: \(category ?? "(unknown)")
        How long does this keep, and where should it be stored?
        """
        var messages: [[String: Any]] = [
            ["role": "system", "content": system],
            ["role": "user", "content": prompt],
        ]

        for _ in 0..<maxRounds {
            let reply = try await provider.chat(messages: messages, tools: [webSearchTool], temperature: 0)
            if reply.toolCalls.isEmpty {
                if let content = reply.content, let guess = parse(content) { return guess }
                break
            }
            messages.append(assistantMessage(reply))
            for call in reply.toolCalls {
                let query = (try? JSONSerialization.jsonObject(
                    with: Data(call.arguments.utf8)
                ) as? [String: Any])?["query"] as? String ?? ""
                let result = await search(query)
                messages.append(["role": "tool", "tool_call_id": call.id, "content": result])
            }
        }

        // Nudge once more for a clean verdict if the loop ended without one.
        messages.append(["role": "user", "content": "Return ONLY the JSON verdict."])
        let final = try await provider.chat(messages: messages, tools: nil, temperature: 0)
        return final.content.flatMap(parse)
    }

    static func assistantMessage(_ reply: ChatCompletion) -> [String: Any] {
        [
            "role": "assistant",
            "content": reply.content ?? "",
            "tool_calls": reply.toolCalls.map {
                ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": $0.arguments]]
            },
        ]
    }

    static func parse(_ text: String) -> ShelfLifeGuess? {
        guard let json = try? JSONExtract.extract(text) else { return nil }
        return ShelfLifeGuess(from: json)
    }

    // MARK: - Backfill (resolve_missing)

    public struct Stats: Equatable {
        public var resolved = 0
        public var unresolved = 0
        public var errors = 0
    }

    static func apply(_ db: Database, productID: Int64, guess: ShelfLifeGuess) throws {
        try db.run(
            """
            UPDATE products
            SET shelf_life_days = ?, shelf_life_days_opened = ?,
                storage = COALESCE(?, storage), is_perishable = ?,
                shelf_life_source = 'web', llm_confidence = ?
            WHERE id = ?
            """,
            [
                guess.shelfLifeDays.map { SQLValue.int(Int64($0)) } ?? .null,
                guess.shelfLifeDaysOpened.map { SQLValue.int(Int64($0)) } ?? .null,
                guess.storage.map { SQLValue.text($0) } ?? .null,
                .int(guess.isPerishable ? 1 : 0),
                .double(guess.confidence),
                .int(productID),
            ]
        )
        if guess.isPerishable, let days = guess.shelfLifeDays {
            try db.run(
                """
                UPDATE inventory SET expires_on = date(acquired_on, '+' || ? || ' days')
                WHERE product_id = ? AND status IN ('active', 'partial')
                """,
                [.int(Int64(days)), .int(productID)]
            )
        } else {
            try db.run(
                "UPDATE inventory SET expires_on = NULL WHERE product_id = ?", [.int(productID)]
            )
        }
    }

    /// Make sure every perishable has a shelf life. Anything still missing gets a best estimate
    /// from the agent, whose answer is trusted — nothing is parked for review.
    @discardableResult
    public static func resolveMissing(
        _ db: Database,
        provider: LLMProvider,
        limit: Int? = nil,
        search: Search = { await WebSearch.duckDuckGo($0) }
    ) async throws -> Stats {
        var sql = """
        SELECT id, canonical_name, category FROM products
        WHERE is_perishable = 1 AND shelf_life_days IS NULL ORDER BY id
        """
        if let limit = limit { sql += " LIMIT \(limit)" }
        let rows = try db.query(sql)

        var stats = Stats()
        for row in rows {
            let name = row["canonical_name"]?.stringValue ?? ""
            do {
                let guess = try await resolve(
                    name: name, category: row["category"]?.stringValue, provider: provider, search: search
                )
                if let guess = guess, guess.shelfLifeDays != nil || !guess.isPerishable {
                    try apply(db, productID: Int64(row["id"]?.intValue ?? 0), guess: guess)
                    stats.resolved += 1
                } else {
                    stats.unresolved += 1
                }
            } catch {
                stats.errors += 1
            }
        }
        return stats
    }
}
