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

    public static let researchSystem = SharedContract.prompts["research"] ?? ""

    public static let synthSystem = SharedContract.prompts["synthesis"] ?? ""

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

    static let jevDays: [String: Int] = [
        "d0": 0,
        "d1_2": 2,
        "d3_4": 4,
        "d5_7": 7,
        "d8_14": 14,
        "d15_30": 30,
        "d31_90": 90,
        "d91_180": 180,
        "d181_365": 365,
    ]
    static let jevRanges: [String: (Int, Int)] = [
        "d0": (0, 0),
        "d1_2": (1, 2),
        "d3_4": (3, 4),
        "d5_7": (5, 7),
        "d8_14": (8, 14),
        "d15_30": (15, 30),
        "d31_90": (31, 90),
        "d91_180": (91, 180),
        "d181_365": (181, 365),
    ]
    static let jevDayCriteria = SharedContract.jev.dayCriteria
    static let jevStorageCriteria = SharedContract.jev.storageCriteria

    public struct ItemVerdict: Codable, Equatable {
        public var itemID: Int
        public var source: String
        public var shelfLifeDays: Int?
        public var shelfLifeDaysOpened: Int?
        public var storage: String?
        public var isPerishable: Bool
        public var confidence: Double

        public init(
            itemID: Int, source: String, shelfLifeDays: Int?, shelfLifeDaysOpened: Int?,
            storage: String?, isPerishable: Bool, confidence: Double
        ) {
            self.itemID = itemID
            self.source = source
            self.shelfLifeDays = shelfLifeDays
            self.shelfLifeDaysOpened = shelfLifeDaysOpened
            self.storage = storage
            self.isPerishable = isPerishable
            self.confidence = confidence
        }

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
        jev: JevProvider? = nil,
        topn: Int = 5,
        search: @escaping Search = { await WebSearch.duckDuckGo($0) },
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> Stats {
        let items = items.filter { $0["id"] is Int && $0["name"] is String }
        if items.isEmpty { return Stats() }

        let lists = try await candidateLists(
            db, items: items, provider: provider, model: embedModel, topn: topn
        )

        let chunkList = stride(from: 0, to: items.count, by: resolveChunk).map {
            Array(items[$0 ..< min($0 + resolveChunk, items.count)])
        }
        for (index, _) in chunkList.enumerated() {
            progress?("Resolving shelf life, part \(index + 1) of \(chunkList.count)…")
        }
        let workers = max(1, provider.config.resolveWorkers)

        func resolveOne(_ index: Int) async -> (Int, [Int: ItemVerdict]) {
            let verdicts = await resolveChunk(
                chunkList[index], shortlists: lists, provider: provider, jev: jev,
                search: search
            )
            return (index, verdicts)
        }

        var results: [(index: Int, verdicts: [Int: ItemVerdict])] = []
        if workers == 1 || chunkList.count == 1 {
            for index in chunkList.indices {
                results.append(await resolveOne(index))
            }
        } else {
            await withTaskGroup(of: (Int, [Int: ItemVerdict]).self) { group in
                var next = 0
                let initial = min(workers, chunkList.count)
                for index in 0 ..< initial {
                    group.addTask { await resolveOne(index) }
                }
                next = initial
                while let result = await group.next() {
                    results.append(result)
                    if next < chunkList.count {
                        let index = next
                        next += 1
                        group.addTask { await resolveOne(index) }
                    }
                }
            }
        }

        var stats = Stats()
        for (index, verdicts) in results.sorted(by: { $0.index < $1.index }) {
            let chunk = chunkList[index]
            stats.resolved += try apply(db, items: chunk, verdicts: verdicts)
            stats.unresolved += chunk.count - verdicts.count
            if verdicts.isEmpty { stats.errors += 1 }
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
        jev: JevProvider? = nil,
        topn: Int = 5,
        search: @escaping Search = { await WebSearch.duckDuckGo($0) },
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
            jev: jev, topn: topn, search: search, progress: progress
        )
    }

    // MARK: - One chunk

    static func resolveChunk(
        _ chunk: [[String: Any]],
        shortlists: [Int: [[String: Any]]],
        provider: LLMProvider,
        jev: JevProvider?,
        search: Search
    ) async -> [Int: ItemVerdict] {
        let payload = payloadFor(chunk, shortlists: shortlists)

        guard let findings = await retry("research", count: chunk.count, {
            try await research(payload, provider: provider, search: search)
        }) else { return [:] }

        if let jev {
            // Jev is terminal. Do not synthesize with the LLM after it.
            return await jevVerdicts(
                chunk, shortlists: shortlists, findings: findings, jev: jev
            )
        }

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
        var messages: [[String: Any]] = [
            ["role": "system", "content": synthSystem],
            ["role": "user", "content": user],
        ]
        var reply = try await provider.chat(
            messages: messages, tools: [verdictTool], temperature: 0,
            forceTool: verdictToolName
        )
        if reply.toolCalls.isEmpty {
            messages.append(assistantMessage(reply))
            messages.append([
                "role": "user",
                "content": "You must call the shelf_life_verdicts tool now. "
                    + "Return one verdict per item and do not answer in prose.",
            ])
            reply = try await provider.chat(
                messages: messages, tools: [verdictTool], temperature: 0,
                forceTool: verdictToolName
            )
        }
        guard let call = reply.toolCalls.first(where: { $0.name == verdictToolName })
                ?? reply.toolCalls.first,
              let data = call.arguments.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(BatchVerdict.self, from: data)
    }

    // MARK: - Jev terminal synthesis

    static func jevQuestions(
        _ chunk: [[String: Any]], shortlists: [Int: [[String: Any]]]
    ) -> [String: Any] {
        var questions: [String: Any] = [:]
        for item in chunk {
            guard let id = item["id"] as? Int, let name = item["name"] as? String else { continue }
            let category = item["category"] as? String ?? "unknown"
            let storage = item["storage"] as? String ?? "unknown"
            questions["item_\(id)_perishable"] = [
                "type": "noul",
                "instructions": "Is item \(id) (\(name), category \(category), stored "
                    + "\(storage)) perishable and likely to expire? Use the research notes in state.",
            ]
            questions["item_\(id)_storage"] = [
                "type": "choice",
                "instructions": "What is the correct storage location for item \(id) (\(name))?",
                "criteria": jevStorageCriteria,
            ]
            questions["item_\(id)_days"] = [
                "type": "choice",
                "instructions": "How long does item \(id) (\(name), category \(category), "
                    + "stored \(storage)) keep before it should be used? Use the research notes "
                    + "and FoodKeeper candidates in state. Calibration examples: fluid milk in "
                    + "the fridge -> 5-7 days; fresh bread -> 3-4 days; eggs in the fridge -> "
                    + "15-30 days; bananas on the counter -> 5-7 days. Do not put fluid milk in "
                    + "31-90 days.",
                "criteria": jevDayCriteria,
            ]
            var criteria: [String: String] = [:]
            for (index, candidate) in (shortlists[id] ?? []).enumerated() {
                let cname = candidate["name"] as? String ?? ""
                if let subtitle = candidate["subtitle"] as? String, !subtitle.isEmpty {
                    criteria["c\(index)"] = "\(cname) — \(subtitle)"
                } else {
                    criteria["c\(index)"] = cname
                }
            }
            criteria["none"] = "No listed FoodKeeper row is the same food."
            questions["item_\(id)_candidate"] = [
                "type": "choice",
                "instructions": "Which FoodKeeper row is genuinely the same food as item "
                    + "\(id) (\(name))? Pick none when no row fits.",
                "criteria": criteria,
            ]
        }
        return questions
    }

    static func candidateDays(_ candidate: [String: Any], storage: String) -> Int? {
        let key: String
        switch storage {
        case "fridge": key = "refrigerate_days"
        case "freezer": key = "freezer_days"
        case "pantry", "counter": key = "pantry_days"
        default: key = "pantry_days"
        }
        return candidate[key] as? Int
    }

    static func jevVerdicts(
        _ chunk: [[String: Any]],
        shortlists: [Int: [[String: Any]]],
        findings: String,
        jev: JevProvider
    ) async -> [Int: ItemVerdict] {
        let payload = payloadFor(chunk, shortlists: shortlists)
        let state: [String: Any] = ["items": payload, "research_notes": findings]
        let response: JevResponse
        do {
            response = try await jev.decide(
                state: state, questions: jevQuestions(chunk, shortlists: shortlists)
            )
        } catch {
            print("    Jev unavailable; leaving items for the next sync: \(error)")
            return [:]
        }

        var out: [Int: ItemVerdict] = [:]
        for item in chunk {
            guard let id = item["id"] as? Int,
                  let perish = response.answers["item_\(id)_perishable"],
                  let storageAnswer = response.answers["item_\(id)_storage"],
                  let daysAnswer = response.answers["item_\(id)_days"]
            else { continue }

            let probability = perish.noul ?? 0
            let isPerishable = probability >= 0.5
            let perishConfidence = max(probability, 1 - probability)
            let storage = storageAnswer.choice ?? (item["storage"] as? String) ?? "pantry"
            let storageConfidence = storageAnswer.confidence ?? 0

            if !isPerishable {
                out[id] = ItemVerdict(
                    itemID: id, source: "jev", shelfLifeDays: nil,
                    shelfLifeDaysOpened: nil, storage: storage,
                    isPerishable: false,
                    confidence: min(perishConfidence, storageConfidence)
                )
                continue
            }

            let daysChoice = daysAnswer.choice
            let daysConfidence = daysAnswer.confidence ?? 0
            let candidates = shortlists[id] ?? []
            let candidateAnswer = response.answers["item_\(id)_candidate"]
            let candidateConfidence = candidateAnswer?.confidence ?? 0
            var chosenCandidate: [String: Any]?
            if let chosen = candidateAnswer?.choice, chosen != "none", chosen.hasPrefix("c"),
               let index = Int(chosen.dropFirst()), index < candidates.count {
                chosenCandidate = candidates[index]
            }
            let exactDays = chosenCandidate.flatMap {
                candidateDays($0, storage: storage)
            }
            let bucket = daysChoice.flatMap { jevRanges[$0] }
            let agrees: Bool
            if let bucket, let exactDays {
                agrees = bucket.0 <= exactDays && exactDays <= bucket.1
            } else {
                agrees = false
            }

            if let exactDays, candidateConfidence >= 0.5 || agrees {
                let opened = chosenCandidate?["after_opening_days"] as? Int
                let confidence = min(
                    min(perishConfidence, storageConfidence),
                    candidateConfidence == 0 ? 0.5 : candidateConfidence
                )
                out[id] = ItemVerdict(
                    itemID: id, source: "foodkeeper", shelfLifeDays: exactDays,
                    shelfLifeDaysOpened: opened, storage: storage,
                    isPerishable: true, confidence: confidence
                )
                continue
            }

            var days: Int?
            if let daysChoice, let range = jevRanges[daysChoice] {
                let wide = range.1 - range.0 > 7
                if !(daysConfidence < 0.5 || (wide && daysConfidence < 0.8)) {
                    days = daysChoice == "d365p" ? 365 : jevDays[daysChoice]
                }
            }
            out[id] = ItemVerdict(
                itemID: id, source: "jev", shelfLifeDays: days,
                shelfLifeDaysOpened: nil, storage: storage,
                isPerishable: true,
                confidence: min(min(perishConfidence, storageConfidence), daysConfidence)
            )
        }
        return out
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
                if isRateLimit(error) {
                    print("    shelf-life \(phase) rate limited; not retrying")
                    return nil
                }
                last = String(describing: error)
            }
            try? await Task.sleep(nanoseconds: UInt64(1.5 * Double(attempt + 1) * 1_000_000_000))
        }
        print("    shelf-life \(phase) failed (\(count) items): \(last)")
        return nil
    }

    static func isRateLimit(_ error: Error) -> Bool {
        let text = String(describing: error).lowercased()
        return text.contains("429") || text.contains("rate limit")
            || text.contains("too many requests")
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
