import Foundation

/// Port of `food/canonicalize.py`. Both retailers flow through a single prompt and schema, so
/// their structural differences disappear at the boundary. Results are cached per
/// (retailer, item_key) in `item_map`, so each product is canonicalized exactly once.
///
/// The SYSTEM prompt is copied **verbatim** — it encodes the whole task.
public enum Canonicalize {
    public static let batchSize = 30

    public static let system = """
    You normalize grocery receipt line items into canonical product records.
    You will receive items from Costco (heavily abbreviated, e.g. "KS ORG A2 PR") and Kroger
    (readable, e.g. "Horizon Organic Whole Milk"). Return ONE object per item, keyed by item_key.

    For each item return exactly these fields:
      item_key (string, echo the input), canonical_name (string),
      brand (string or null), category (string or null),
      pkg_size (string or null, e.g. "1/2 gal", "16 oz"),
      unit ("count" | "weight" | "volume" or null),
      is_food (bool), is_perishable (bool),
      storage ("fridge" | "freezer" | "pantry" | "counter"),
      shelf_life_days (int or null), shelf_life_days_opened (int or null),
      confidence (0.0-1.0).

    Rules:
    - Write canonical_name as the plain, readable product name (expand abbreviations).
    - If is_perishable is true, shelf_life_days is REQUIRED (whole days, never null) — give
      your best estimate.
    - Non-perishable items (coffee, rice, canned goods, spices, oil) may set shelf_life_days
      null; they do not expire.
    - Non-food items (apparel, housewares, electronics, flowers, tobacco) get is_food=false,
      is_perishable=false, and shelf_life_days null.
    - If you are unsure, lower confidence rather than guessing wildly.

    Examples:
      "KS ORG A2 PR"      -> {"canonical_name":"Organic A2 Milk","brand":"Kirkland Signature","category":"Dairy Products & Eggs","pkg_size":"1/2 gal","unit":"volume","is_food":true,"is_perishable":true,"storage":"fridge","shelf_life_days":7,"confidence":0.8}
      "KS COLMBIAN"       -> {"canonical_name":"Colombian Coffee","brand":"Kirkland Signature","category":"Beverages","pkg_size":null,"unit":"count","is_food":true,"is_perishable":false,"storage":"pantry","shelf_life_days":null,"confidence":0.75}
      "PASTURE EGGS"      -> {"canonical_name":"Pasture-Raised Eggs","brand":null,"category":"Dairy Products & Eggs","pkg_size":null,"unit":"count","is_food":true,"is_perishable":true,"storage":"fridge","shelf_life_days":21,"confidence":0.8}
      "MWCHINOPANT"       -> {"canonical_name":"Apparel","brand":null,"category":null,"pkg_size":null,"unit":"count","is_food":false,"is_perishable":false,"storage":"pantry","shelf_life_days":null,"confidence":0.6}
      "SHRIMP 31/40"      -> {"canonical_name":"Shrimp","brand":null,"category":"Seafood","pkg_size":null,"unit":"weight","is_food":true,"is_perishable":true,"storage":"freezer","shelf_life_days":180,"confidence":0.7}

    Respond with ONLY JSON: {"items": [ ... ]}
    """

    public struct Stats: Equatable {
        public var batches = 0
        public var ok = 0
        public var fallback = 0
    }

    /// Distinct items seen on receipts that have no product mapping yet.
    public static func pending(_ db: Database, limit: Int? = nil) throws -> [[String: SQLValue]] {
        var sql = """
        SELECT ri.item_key AS item_key, r.retailer AS retailer,
               MAX(ri.raw_description) AS raw_description,
               MAX(ri.raw_pkg_size) AS raw_pkg_size
        FROM receipt_items ri
        JOIN receipts r ON r.id = ri.receipt_id
        LEFT JOIN item_map m ON m.retailer = r.retailer AND m.item_key = ri.item_key
        WHERE m.id IS NULL
        GROUP BY r.retailer, ri.item_key
        ORDER BY COUNT(*) DESC
        """
        if let limit = limit { sql += " LIMIT \(limit)" }
        return try db.query(sql)
    }

    public static func pendingCount(_ db: Database) throws -> Int {
        let rows = try db.query(
            """
            SELECT COUNT(*) n FROM (
                SELECT r.retailer, ri.item_key
                FROM receipt_items ri
                JOIN receipts r ON r.id = ri.receipt_id
                LEFT JOIN item_map m ON m.retailer = r.retailer AND m.item_key = ri.item_key
                WHERE m.id IS NULL
                GROUP BY r.retailer, ri.item_key
            )
            """
        )
        return rows.first?["n"]?.intValue ?? 0
    }

    static func buildUser(_ items: [[String: SQLValue]]) -> String {
        let payload = items.map { it -> [String: Any] in
            [
                "item_key": it["item_key"]?.stringValue ?? "",
                "retailer": it["retailer"]?.stringValue ?? "",
                "raw_description": it["raw_description"]?.stringValue ?? "",
                "pkg_size_hint": it["raw_pkg_size"]?.stringValue as Any,
            ]
        }
        return Reference.jsonString(["items": payload])
    }

    /// Build a `CanonicalItem` from a raw dict (lenient, like pydantic defaults).
    static func makeItem(_ raw: [String: Any]) -> CanonicalItem? {
        guard let key = raw["item_key"] as? String, let name = raw["canonical_name"] as? String else {
            return nil
        }
        func intOrNil(_ v: Any?) -> Int? {
            if let i = v as? Int { return i }
            if let d = v as? Double { return Int(d) }
            return nil
        }
        return CanonicalItem(
            itemKey: key,
            canonicalName: name,
            brand: raw["brand"] as? String,
            category: raw["category"] as? String,
            pkgSize: raw["pkg_size"] as? String,
            unit: raw["unit"] as? String,
            isFood: (raw["is_food"] as? Bool) ?? true,
            isPerishable: (raw["is_perishable"] as? Bool) ?? false,
            storage: raw["storage"] as? String,
            shelfLifeDays: intOrNil(raw["shelf_life_days"]),
            shelfLifeDaysOpened: intOrNil(raw["shelf_life_days_opened"]),
            confidence: (raw["confidence"] as? Double) ?? 0.5
        )
    }

    @discardableResult
    static func storeProduct(
        _ db: Database, retailer: String, item: [String: SQLValue], ci: CanonicalItem, model: String
    ) throws -> Int64 {
        let days = ci.shelfLifeDays
        let source: SQLValue = days != nil ? .text("llm") : .null
        try db.run(
            """
            INSERT INTO products
            (canonical_name, brand, category, pkg_size, unit, is_food, is_perishable, storage,
             shelf_life_days, shelf_life_days_opened, shelf_life_source, foodkeeper_id,
             llm_model, llm_confidence, classified_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,datetime('now'))
            """,
            [
                .text(ci.canonicalName),
                ci.brand.map { SQLValue.text($0) } ?? .null,
                ci.category.map { SQLValue.text($0) } ?? .null,
                ci.pkgSize.map { SQLValue.text($0) } ?? .null,
                ci.unit.map { SQLValue.text($0) } ?? .null,
                .int(ci.isFood ? 1 : 0),
                .int(ci.isPerishable ? 1 : 0),
                ci.storage.map { SQLValue.text($0) } ?? .null,
                days.map { SQLValue.int(Int64($0)) } ?? .null,
                ci.shelfLifeDaysOpened.map { SQLValue.int(Int64($0)) } ?? .null,
                source,
                .null,
                .text(model),
                .double(ci.confidence),
            ]
        )
        let pid = db.lastInsertRowID
        try db.run(
            """
            INSERT OR IGNORE INTO item_map (retailer, item_key, raw_description, product_id)
            VALUES (?, ?, ?, ?)
            """,
            [
                .text(retailer),
                .text(item["item_key"]?.stringValue ?? ""),
                item["raw_description"] ?? .null,
                .int(pid),
            ]
        )
        return pid
    }

    /// Ground stored products in FoodKeeper: hybrid shortlist per name, one batched rerank.
    static func ground(
        _ db: Database,
        stored: [(pid: Int64, name: String, storage: String)],
        provider: LLMProvider,
        model: String?
    ) async throws {
        guard !stored.isEmpty else { return }
        let picks = try await Reference.matchBatch(db, names: stored.map { $0.name }, provider: provider, model: model)
        for (pid, name, storage) in stored {
            guard let fid = picks[name] ?? nil else { continue }
            guard let days = FoodKeeper.daysFor(db, foodkeeperID: fid, storage: storage) else { continue }
            try db.run(
                """
                UPDATE products SET foodkeeper_id = ?, shelf_life_days = ?, shelf_life_source = 'foodkeeper'
                WHERE id = ?
                """,
                [.int(Int64(fid)), .int(Int64(days)), .int(pid)]
            )
        }
    }

    /// A model output we couldn't parse: keep the pipeline moving with a placeholder row.
    static func fallback(_ db: Database, retailer: String, item: [String: SQLValue]) throws {
        try db.run(
            "INSERT INTO products (canonical_name, is_food, is_perishable, llm_confidence) VALUES (?, 1, 0, 0.0)",
            [item["raw_description"] ?? .text(item["item_key"]?.stringValue ?? "")]
        )
        let pid = db.lastInsertRowID
        try db.run(
            """
            INSERT OR IGNORE INTO item_map (retailer, item_key, raw_description, product_id)
            VALUES (?, ?, ?, ?)
            """,
            [.text(retailer), item["item_key"] ?? .text(""), item["raw_description"] ?? .null, .int(pid)]
        )
    }

    static func apply(
        _ db: Database,
        batch: [[String: SQLValue]],
        data: [String: Any],
        model: String,
        stats: inout Stats
    ) throws -> (failed: [[String: SQLValue]], stored: [(Int64, String, String)]) {
        var byKey: [String: [String: Any]] = [:]
        for raw in (data["items"] as? [[String: Any]]) ?? [] {
            if let key = raw["item_key"] as? String { byKey[key] = raw }
        }
        var failed: [[String: SQLValue]] = []
        var stored: [(Int64, String, String)] = []
        for item in batch {
            guard let raw = byKey[item["item_key"]?.stringValue ?? ""], let ci = makeItem(raw) else {
                failed.append(item)
                continue
            }
            let pid = try storeProduct(db, retailer: item["retailer"]?.stringValue ?? "", item: item, ci: ci, model: model)
            stored.append((pid, ci.canonicalName, ci.storage ?? "fridge"))
            stats.ok += 1
        }
        return (failed, stored)
    }

    /// Canonicalize pending items. Each product is cached in `item_map`, so re-running only
    /// touches items that failed. Batches run sequentially (temperature 0, so output is stable).
    ///
    /// `embedModel` enables the vector half of hybrid retrieval during grounding; pass nil
    /// (or leave embeddings unconfigured) to ground with the lexical retriever alone.
    public static func canonicalize(
        _ db: Database, provider: LLMProvider, embedModel: String? = nil, limit: Int? = nil
    ) async throws -> Stats {
        var stats = Stats()
        let items = try pending(db, limit: limit)
        if items.isEmpty { return stats }

        let batches = stride(from: 0, to: items.count, by: batchSize).map {
            Array(items[$0 ..< min($0 + batchSize, items.count)])
        }
        var failed: [[String: SQLValue]] = []
        for batch in batches {
            stats.batches += 1
            var stored: [(Int64, String, String)] = []
            do {
                let response = try await provider.chatJSON(system: system, user: buildUser(batch), temperature: 0)
                record(db, purpose: "canonicalize", model: response.model)
                (failed, stored) = try apply(db, batch: batch, data: response.json, model: response.model, stats: &stats)
            } catch {
                failed += batch
            }
            try await ground(db, stored: stored, provider: provider, model: embedModel)
        }

        if !failed.isEmpty {
            for batch in stride(from: 0, to: failed.count, by: batchSize).map({
                Array(failed[$0 ..< min($0 + batchSize, failed.count)])
            }) {
                var stored: [(Int64, String, String)] = []
                if let response = try? await provider.chatJSON(system: system, user: buildUser(batch), temperature: 0) {
                    record(db, purpose: "canonicalize", model: response.model)
                    let (still, s) = try apply(db, batch: batch, data: response.json, model: response.model, stats: &stats)
                    stored = s
                    for item in still {
                        try fallback(db, retailer: item["retailer"]?.stringValue ?? "", item: item)
                        stats.fallback += 1
                    }
                } else {
                    for item in batch {
                        try fallback(db, retailer: item["retailer"]?.stringValue ?? "", item: item)
                        stats.fallback += 1
                    }
                }
                try await ground(db, stored: stored, provider: provider, model: embedModel)
            }
        }
        return stats
    }

    static func record(_ db: Database, purpose: String, model: String) {
        _ = try? db.run(
            "INSERT INTO llm_calls (purpose, model, prompt_tokens, completion_tokens) VALUES (?, ?, NULL, NULL)",
            [.text(purpose), .text(model)]
        )
    }
}
