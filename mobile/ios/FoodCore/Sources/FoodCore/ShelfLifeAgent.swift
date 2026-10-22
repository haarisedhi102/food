import Foundation

/// Batched shelf-life resolution — port of `food/resolve.py`.
///
/// Two phases per chunk of items:
/// 1. **Research** — a tool-calling agent receives each item with its FoodKeeper candidate
///    shortlist and uses `web_search` only where no row fits. It returns prose notes.
/// 2. **Synthesis** — the verdict schema is bound as the only tool with `tool_choice` forced,
///    turning those notes into one structured verdict per item. Prose is never accepted; the
///    caller re-asks when no tool call comes back.
///
/// Verdicts are keyed by product id, and any item a chunk omits is re-asked once.
public enum ShelfLifeAgent {
    public static let resolveChunk = 8
    static let attempts = 3
    static let maxResearchRounds = 3
    static let verdictToolName = "shelf_life_verdicts"

    public typealias Search = @Sendable (String) async -> String

    public static let researchSystem = """
    You research how long grocery items keep. You receive several items at
    once, and for each a shortlist of FoodKeeper reference rows with their shelf-life figures in
    days (pantry, refrigerate, freezer, after opening).

    For each item decide the shelf life to use and where it comes from:
    - a FoodKeeper row, when a candidate is genuinely the same food and its figures make sense.
      FoodKeeper rows can be sparse or odd (e.g. a milk row with only a freezer figure and no
      refrigerated days) — if a candidate only loosely fits, do not use it;
    - the web_search tool, when no row fits — search authoritative guidance (USDA/FoodKeeper,
      food-safety agencies, manufacturers);
    - your own knowledge, when you are already confident.

    Then write a short note per item, quoting its id: the shelf life in days, the source (the
    FoodKeeper row used, the web, or your own knowledge), and the storage it applies to. Do NOT
    return JSON — just notes.
    """

    public static let synthSystem = """
    You convert grocery shelf-life research notes into one structured verdict per
    item. Return one entry per item, echoing that item's `id` in `item_id`. For each:
    - source: "foodkeeper" if a FoodKeeper row was used, else "web" or "llm";
    - shelf_life_days: YOUR best shelf life in whole days. Treat FoodKeeper as a slightly preferred
      source, not the authority — its figures can be unrealistic (a row listing only a 3-month
      freezer figure does not mean 90 days of fridge life). Use judgement; null only when the item
      is non-perishable;
    - is_perishable: false for dry goods, canned, spices.

    Examples (item id, name, storage -> verdict):
      12 "Whole Milk", fridge          -> {"item_id": 12, "source": "foodkeeper", "shelf_life_days": 7, "is_perishable": true}
      30 "Jasmine Rice", pantry        -> {"item_id": 30, "source": "foodkeeper", "shelf_life_days": null, "is_perishable": false}
      41 "Unsweetened Oatmilk", fridge -> {"item_id": 41, "source": "web", "shelf_life_days": 7, "is_perishable": true}
      55 "Roma Tomato", counter        -> {"item_id": 55, "source": "llm", "shelf_life_days": 7, "is_perishable": true}
    """

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

    public static let verdictTool: [String: Any] = [
        "type": "function",
        "function": [
            "name": verdictToolName,
            "description": "Return one shelf-life verdict per item.",
            "parameters": [
                "type": "object",
                "properties": [
                    "items": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "item_id": [
                                    "type": "integer",
                                    "description": "the item's id, echoed exactly",
                                ],
                                "source": ["type": "string", "enum": ["foodkeeper", "web", "llm"]],
                                "shelf_life_days": [
                                    "type": ["integer", "null"],
                                    "description": "whole days; null when the item is non-perishable",
                                ],
                                "shelf_life_days_opened": ["type": ["integer", "null"]],
                                "storage": [
                                    "type": ["string", "null"],
                                    "description": "fridge | freezer | pantry | counter",
                                ],
                                "is_perishable": ["type": "boolean"],
                                "confidence": ["type": "number"],
                            ] as [String: Any],
                            "required": ["item_id", "source", "shelf_life_days", "is_perishable"],
                        ] as [String: Any],
                    ] as [String: Any],
                ] as [String: Any],
                "required": ["items"],
            ] as [String: Any],
        ] as [String: Any],
    ]

    public struct ItemVerdict: Codable, Equatable {
        public var itemID: Int
        public var source: String
        public var shelfLifeDays: Int?
        public var shelfLifeDaysOpened: Int?
        public var storage: String?
        public var isPerishable: Bool
        public var confidence: Double

        enum CodingKeys: String, CodingKey {
            case itemID = "item_id"
            case source
            case shelfLifeDays = "shelf_life_days"
            case shelfLifeDaysOpened = "shelf_life_days_opened"
            case storage
            case isPerishable = "is_perishable"
            case confidence
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            itemID = try c.decode(Int.self, forKey: .itemID)
            source = (try? c.decodeIfPresent(String.self, forKey: .source)) ?? "llm"
            shelfLifeDays = Self.flexInt(c, .shelfLifeDays)
            shelfLifeDaysOpened = Self.flexInt(c, .shelfLifeDaysOpened)
            storage = try? c.decodeIfPresent(String.self, forKey: .storage)
            isPerishable = (try? c.decodeIfPresent(Bool.self, forKey: .isPerishable)) ?? true
            confidence = (try? c.decodeIfPresent(Double.self, forKey: .confidence)) ?? 0.5
        }

        static func flexInt(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int? {
            if let i = try? c.decodeIfPresent(Int.self, forKey: key) { return i }
            if let d = try? c.decodeIfPresent(Double.self, forKey: key) { return Int(d) }
            if let s = try? c.decodeIfPresent(String.self, forKey: key) { return Int(s) }
            return nil
        }
    }

    public struct BatchVerdict: Codable, Equatable {
        public var items: [ItemVerdict]
    }

    public struct Stats: Equatable {
        public var resolved = 0
        public var unresolved = 0
        public var errors = 0
    }

    // MARK: - Backfill (resolve_missing)

    /// Resolve a supplied batch of items — every newly stored food item, as in
    /// `canonicalize._apply` (this can also correct a perishable/non-perishable mistake).
    @discardableResult
    public static func resolveBatch(
        _ db: Database,
        items: [[String: Any]],
        provider: LLMProvider,
        embedModel: String? = nil,
        topn: Int = 5,
        search: Search = { await WebSearch.duckDuckGo($0) },
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> Stats {
        let items = items.filter { $0["id"] is Int && $0["name"] is String }
        if items.isEmpty { return Stats() }

        let lists = try await candidateLists(
            db, items: items, provider: provider, model: embedModel, topn: topn
        )

        let chunks = (items.count + resolveChunk - 1) / resolveChunk
        var stats = Stats()
        var start = 0
        var index = 0
        while start < items.count {
            let chunk = Array(items[start ..< min(start + resolveChunk, items.count)])
            index += 1
            progress?("Resolving shelf life, part \(index) of \(chunks)…")
            let verdicts = await resolveChunk(
                chunk, shortlists: lists, provider: provider, search: search
            )
            stats.resolved += try apply(db, items: chunk, verdicts: verdicts)
            stats.unresolved += chunk.count - verdicts.count
            if verdicts.isEmpty { stats.errors += 1 }
            start += resolveChunk
        }
        return stats
    }

    /// Fill shelf-life gaps on already-stored products — the `resolve` backfill command.
    /// Mirrors `resolve_command`'s default selection.
    @discardableResult
    public static func resolveMissing(
        _ db: Database,
        provider: LLMProvider,
        limit: Int? = nil,
        embedModel: String? = nil,
        topn: Int = 5,
        search: Search = { await WebSearch.duckDuckGo($0) },
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> Stats {
        var sql = """
        SELECT id, canonical_name AS name, category, storage FROM products
        WHERE is_food = 1 AND shelf_life_days IS NULL
          AND (is_perishable = 1 OR storage IN ('fridge', 'freezer'))
        ORDER BY id
        """
        if let limit = limit { sql += " LIMIT \(limit)" }
        let rows = try db.query(sql)
        let items: [[String: Any]] = rows.compactMap { row in
            guard let id = row["id"]?.intValue,
                  let name = row["name"]?.stringValue else { return nil }
            return [
                "id": id,
                "name": name,
                "category": box(row["category"]?.stringValue),
                "storage": box(row["storage"]?.stringValue),
            ]
        }
        return try await resolveBatch(
            db, items: items, provider: provider, embedModel: embedModel,
            topn: topn, search: search, progress: progress
        )
    }

    // MARK: - One chunk

    static func resolveChunk(
        _ chunk: [[String: Any]],
        shortlists: [Int: [[String: Any]]],
        provider: LLMProvider,
        search: Search
    ) async -> [Int: ItemVerdict] {
        let payload = payloadFor(chunk, shortlists: shortlists)

        guard let findings = await retry("research", count: chunk.count, {
            try await research(payload, provider: provider, search: search)
        }) else { return [:] }
        guard let verdict = await retry("synthesis", count: chunk.count, {
            try await synthesize(payload, findings: findings, provider: provider)
        }) else { return [:] }

        var out = collect(verdict, items: chunk)

        // Completeness: re-ask once for anything the model omitted.
        let missing = chunk.filter { it in
            guard let id = it["id"] as? Int else { return false }
            return out[id] == nil
        }
        if !missing.isEmpty {
            let retryVerdict = await retry("synthesis (missing)", count: missing.count, {
                try await synthesize(
                    payloadFor(missing, shortlists: shortlists),
                    findings: findings,
                    provider: provider
                )
            })
            if let retryVerdict = retryVerdict {
                for (id, verdict) in collect(retryVerdict, items: missing) { out[id] = verdict }
            }
        }
        return out
    }

    static func research(
        _ payload: [[String: Any]], provider: LLMProvider, search: Search
    ) async throws -> String {
        var messages: [[String: Any]] = [
            ["role": "system", "content": researchSystem],
            ["role": "user", "content": Reference.jsonString(["items": payload])],
        ]

        for _ in 0 ..< maxResearchRounds {
            let reply = try await provider.chat(
                messages: messages, tools: [webSearchTool], temperature: 0
            )
            if reply.toolCalls.isEmpty {
                return (reply.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            messages.append(assistantMessage(reply))
            for call in reply.toolCalls {
                let result = await search(toolQuery(call.arguments))
                messages.append(["role": "tool", "tool_call_id": call.id, "content": result])
            }
        }

        let final = try await provider.chat(messages: messages, tools: nil, temperature: 0)
        return (final.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func synthesize(
        _ payload: [[String: Any]], findings: String, provider: LLMProvider
    ) async throws -> BatchVerdict? {
        let user = Reference.jsonString(["items": payload, "research_notes": findings])
        let reply = try await provider.chat(
            messages: [
                ["role": "system", "content": synthSystem],
                ["role": "user", "content": user],
            ],
            tools: [verdictTool],
            temperature: 0,
            forceTool: verdictToolName
        )
        guard let call = reply.toolCalls.first(where: { $0.name == verdictToolName })
                ?? reply.toolCalls.first,
              let data = call.arguments.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(BatchVerdict.self, from: data)
    }

    /// Run `work`, retrying a few times on a transient error *or* when it yields nothing.
    static func retry<T>(
        _ phase: String, count: Int, _ work: () async throws -> T?
    ) async -> T? {
        var last = "no result"
        for attempt in 0 ..< attempts {
            do {
                if let value = try await work() { return value }
            } catch {
                last = String(describing: error)
            }
            try? await Task.sleep(nanoseconds: UInt64(1.5 * Double(attempt + 1) * 1_000_000_000))
        }
        print("    shelf-life \(phase) failed (\(count) items): \(last)")
        return nil
    }

    static func collect(_ verdict: BatchVerdict, items: [[String: Any]]) -> [Int: ItemVerdict] {
        let wanted = Set(items.compactMap { $0["id"] as? Int })
        var out: [Int: ItemVerdict] = [:]
        for v in verdict.items where wanted.contains(v.itemID) { out[v.itemID] = v }
        return out
    }

    // MARK: - Apply

    static func apply(
        _ db: Database, items: [[String: Any]], verdicts: [Int: ItemVerdict]
    ) throws -> Int {
        let wanted = Set(items.compactMap { $0["id"] as? Int })
        var applied = 0
        for (pid, v) in verdicts where wanted.contains(pid) {
            try db.run(
                """
                UPDATE products
                SET shelf_life_days = ?, shelf_life_days_opened = ?,
                    storage = COALESCE(?, storage), is_perishable = ?,
                    shelf_life_source = ?, llm_confidence = ?
                WHERE id = ?
                """,
                [
                    v.shelfLifeDays.map { SQLValue.int(Int64($0)) } ?? .null,
                    v.shelfLifeDaysOpened.map { SQLValue.int(Int64($0)) } ?? .null,
                    v.storage.map { SQLValue.text($0) } ?? .null,
                    .int(v.isPerishable ? 1 : 0),
                    .text(v.source),
                    .double(v.confidence),
                    .int(Int64(pid)),
                ]
            )
            if let days = v.shelfLifeDays {
                try db.run(
                    """
                    UPDATE inventory SET expires_on = date(acquired_on, '+' || ? || ' days')
                    WHERE product_id = ? AND status IN ('active', 'partial')
                    """,
                    [.int(Int64(days)), .int(Int64(pid))]
                )
            } else if !v.isPerishable {
                // only a known non-perishable clears expiry; an unknown keeps what it had
                try db.run(
                    "UPDATE inventory SET expires_on = NULL WHERE product_id = ?",
                    [.int(Int64(pid))]
                )
            }
            applied += 1
        }
        return applied
    }

    // MARK: - Payload / candidates

    /// FoodKeeper candidates per product id, each enriched with its shelf-life figures.
    static func candidateLists(
        _ db: Database,
        items: [[String: Any]],
        provider: LLMProvider,
        model: String?,
        topn: Int
    ) async throws -> [Int: [[String: Any]]] {
        let names = items.compactMap { $0["name"] as? String }
        let byName = try await Reference.shortlists(
            db, names: names, limit: topn, provider: provider, model: model
        )
        var out: [Int: [[String: Any]]] = [:]
        for item in items {
            guard let id = item["id"] as? Int, let name = item["name"] as? String else { continue }
            out[id] = (byName[name] ?? []).map(candidate)
        }
        return out
    }

    static func candidate(_ row: [String: SQLValue]) -> [String: Any] {
        [
            "name": box(row["name"]?.stringValue),
            "subtitle": box(row["subtitle"]?.stringValue),
            "pantry_days": box(row["pantry_days"]?.intValue),
            "refrigerate_days": box(row["dop_refrigerate_days"]?.intValue),
            "freezer_days": box(row["dop_freeze_days"]?.intValue),
            "after_opening_days": box(row["refrigerate_after_opening_days"]?.intValue),
        ]
    }

    static func payloadFor(
        _ items: [[String: Any]], shortlists: [Int: [[String: Any]]]
    ) -> [[String: Any]] {
        items.map { item in
            [
                "id": item["id"] ?? 0,
                "item": item["name"] ?? "",
                "category": item["category"] ?? NSNull(),
                "storage": item["storage"] ?? NSNull(),
                "candidates": shortlists[item["id"] as? Int ?? -1] ?? [],
            ]
        }
    }

    // MARK: - Helpers

    static func assistantMessage(_ reply: ChatCompletion) -> [String: Any] {
        [
            "role": "assistant",
            "content": reply.content ?? "",
            "tool_calls": reply.toolCalls.map {
                [
                    "id": $0.id,
                    "type": "function",
                    "function": ["name": $0.name, "arguments": $0.arguments],
                ]
            },
        ]
    }

    static func toolQuery(_ arguments: String) -> String {
        guard let object = try? JSONSerialization.jsonObject(
            with: Data(arguments.utf8)
        ) as? [String: Any] else { return "" }
        return object["query"] as? String ?? ""
    }

    static func box(_ value: String?) -> Any { value.map { $0 as Any } ?? NSNull() }
    static func box(_ value: Int?) -> Any { value.map { $0 as Any } ?? NSNull() }
}
