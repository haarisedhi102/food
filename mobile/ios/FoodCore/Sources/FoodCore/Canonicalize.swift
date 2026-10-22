import Foundation

/// Port of `food/canonicalize.py`. Both retailers flow through a single prompt and schema, so
/// their structural differences disappear at the boundary. Results are cached per
/// (retailer, item_key) in `item_map`, so each product is canonicalized exactly once.
///
/// The SYSTEM prompt is copied **verbatim** — it encodes the whole task.
public enum Canonicalize {
    public static let batchSize = 30

    public static let system = SharedContract.prompts["canonicalize"] ?? ""

    public struct Stats: Equatable {
        public var batches = 0
        public var ok = 0
        public var fallback = 0
        public var resolved = 0
        /// Receipt lines still without a product mapping (usually a failed LLM call).
        /// They stay pending and the next `canonicalize` retries them.
        public var pending = 0
    }

    private struct ProviderBox: @unchecked Sendable {
        let provider: LLMProvider
    }

    private struct BatchOutcome: @unchecked Sendable {
        let index: Int
        let response: ChatResponse?
        let error: String?
    }

    private static func sizedBatches(
        _ items: [[String: SQLValue]], workers: Int
    ) -> [[[String: SQLValue]]] {
        guard !items.isEmpty else { return [] }
        let target = Int(ceil(Double(items.count) / Double(max(1, workers))))
        let size = min(batchSize, max(10, target))
        return stride(from: 0, to: items.count, by: size).map {
            Array(items[$0 ..< min($0 + size, items.count)])
        }
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

    /// Products created by the raw-text fallback (the model output never parsed). They keep
    /// the receipt description as the name and are marked by having no model/classification.
    static let fallbackPredicate = "p.llm_model IS NULL AND p.classified_at IS NULL"

    /// Unmapped receipt lines plus raw-name fallback products — everything a retry can fix.
    public static func repairableCount(_ db: Database) throws -> Int {
        let pending = try pendingCount(db)
        let rows = try db.query(
            """
            SELECT COUNT(*) n FROM item_map m
            JOIN products p ON p.id = m.product_id
            WHERE \(fallbackPredicate)
            """
        )
        return pending + (rows.first?["n"]?.intValue ?? 0)
    }

    /// Drop raw-name fallback products and their mappings (and their inventory rows) so the
    /// next `canonicalize` sees those receipt lines as pending and can classify them again.
    @discardableResult
    public static func repairFallbacks(_ db: Database) throws -> Int {
        let rows = try db.query(
            """
            SELECT m.id AS map_id, p.id AS product_id FROM item_map m
            JOIN products p ON p.id = m.product_id
            WHERE \(fallbackPredicate)
            """
        )
        var repaired = 0
        for row in rows {
            guard let mapID = row["map_id"]?.intValue,
                  let productID = row["product_id"]?.intValue else { continue }
            try db.run("DELETE FROM inventory WHERE product_id = ?", [.int(Int64(productID))])
            try db.run("DELETE FROM item_map WHERE id = ?", [.int(Int64(mapID))])
            try db.run("DELETE FROM products WHERE id = ?", [.int(Int64(productID))])
            repaired += 1
        }
        return repaired
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
        // Shelf life is not estimated here — `ShelfLifeAgent` fills it for the whole batch after.
        try db.run(
            """
            INSERT INTO products
            (canonical_name, brand, category, pkg_size, unit, is_food, is_perishable, storage,
             shelf_life_days, shelf_life_days_opened, shelf_life_source,
             llm_model, llm_confidence, classified_at)
            VALUES (?,?,?,?,?,?,?,?,NULL,NULL,NULL,?,?,datetime('now'))
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
    ) throws -> (failed: [[String: SQLValue]], stored: [[String: Any]]) {
        var byKey: [String: [String: Any]] = [:]
        for raw in (data["items"] as? [[String: Any]]) ?? [] {
            if let key = raw["item_key"] as? String { byKey[key] = raw }
        }
        var failed: [[String: SQLValue]] = []
        var stored: [[String: Any]] = []
        for item in batch {
            guard let raw = byKey[item["item_key"]?.stringValue ?? ""], let ci = makeItem(raw) else {
                failed.append(item)
                continue
            }
            let pid = try storeProduct(
                db, retailer: item["retailer"]?.stringValue ?? "", item: item, ci: ci, model: model
            )
            if ci.isFood {
                stored.append([
                    "id": Int(pid),
                    "name": ci.canonicalName,
                    "category": ci.category.map { $0 as Any } ?? NSNull(),
                    "storage": ci.storage.map { $0 as Any } ?? NSNull(),
                    "is_perishable": ci.isPerishable,
                ])
            }
            stats.ok += 1
        }
        return (failed, stored)
    }

    /// Canonicalize pending items. Each product is cached in `item_map`, so re-running only
    /// touches items that failed. Batches run sequentially (temperature 0, so output is stable).
    ///
    /// Shelf life is resolved for the newly stored food items by `ShelfLifeAgent`, as in
    /// `food/canonicalize.py`.
    public static func canonicalize(
        _ db: Database, provider: LLMProvider, embedModel: String? = nil,
        jev: JevProvider? = nil, limit: Int? = nil,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> Stats {
        var stats = Stats()
        let items = try pending(db, limit: limit)
        if items.isEmpty { return stats }

        let workers = max(1, provider.config.classifyWorkers)
        let batches = sizedBatches(items, workers: workers)
        var failed: [[String: SQLValue]] = []
        let box = ProviderBox(provider: provider)
        let outcomes: [BatchOutcome] = await withTaskGroup(of: BatchOutcome.self) { group in
            var collected: [BatchOutcome] = []
            func submit(_ index: Int) {
                let batch = batches[index]
                group.addTask {
                    do {
                        let response = try await box.provider.chatJSON(
                            system: system, user: buildUser(batch), temperature: 0
                        )
                        return BatchOutcome(index: index, response: response, error: nil)
                    } catch {
                        return BatchOutcome(
                            index: index, response: nil,
                            error: String(describing: error)
                        )
                    }
                }
            }
            let initial = min(workers, batches.count)
            for index in 0 ..< initial { submit(index) }
            var next = initial
            while let outcome = await group.next() {
                collected.append(outcome)
                if next < batches.count {
                    submit(next)
                    next += 1
                }
            }
            return collected
        }

        for outcome in outcomes.sorted(by: { $0.index < $1.index }) {
            let index = outcome.index
            let batch = batches[index]
            stats.batches += 1
            var stored: [[String: Any]] = []
            if let response = outcome.response {
                record(db, purpose: "canonicalize", model: response.model)
                let (batchFailed, batchStored) = try apply(
                    db, batch: batch, data: response.json, model: response.model, stats: &stats
                )
                failed += batchFailed
                stored = batchStored
            } else {
                print("[canon] batch \(index + 1)/\(batches.count) failed: \(outcome.error ?? "?")")
                failed += batch
            }
            progress?("Resolving shelf life, batch \(index + 1) of \(batches.count)…")
            let perishable = stored.filter { ($0["is_perishable"] as? Bool) == true }
            let shelf = try await ShelfLifeAgent.resolveBatch(
                db, items: perishable, provider: provider, embedModel: embedModel,
                jev: jev, progress: progress
            )
            stats.resolved += shelf.resolved
        }

        if !failed.isEmpty {
            progress?("Retrying \(failed.count) products…")
            for batch in sizedBatches(failed, workers: workers) {
                var stored: [[String: Any]] = []
                if let response = try? await provider.chatJSON(system: system, user: buildUser(batch), temperature: 0) {
                    record(db, purpose: "canonicalize", model: response.model)
                    let (still, batchStored) = try apply(
                        db, batch: batch, data: response.json, model: response.model, stats: &stats
                    )
                    stored = batchStored
                    for item in still {
                        try fallback(db, retailer: item["retailer"]?.stringValue ?? "", item: item)
                        stats.fallback += 1
                    }
                } else {
                    // A transport/API failure (timeout, 5xx) isn't a bad model answer.
                    // Leave these items unmapped so the next sync retries them instead of
                    // permanently caching raw receipt text as the product name.
                    print("[canon] retry call failed; leaving \(batch.count) products pending")
                }
                let perishable = stored.filter { ($0["is_perishable"] as? Bool) == true }
                let shelf = try await ShelfLifeAgent.resolveBatch(
                    db, items: perishable, provider: provider, embedModel: embedModel,
                    jev: jev, progress: progress
                )
                stats.resolved += shelf.resolved
            }
        }
        stats.pending = (try? pendingCount(db)) ?? 0
        return stats
    }

    static func record(_ db: Database, purpose: String, model: String) {
        _ = try? db.run(
            "INSERT INTO llm_calls (purpose, model, prompt_tokens, completion_tokens) VALUES (?, ?, NULL, NULL)",
            [.text(purpose), .text(model)]
        )
    }
}
