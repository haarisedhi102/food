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
      confidence (0.0-1.0).

    Shelf life is resolved in a later stage — do not estimate it here.

    Rules:
    - Write canonical_name as the plain, readable product name (expand abbreviations).
    - Fresh bakery, deli, refrigerated, meat, seafood, produce, dairy and prepared foods are
      is_perishable=true, even when a shelf-stable version of the product exists (dry pasta and
      packaged cookies are shelf-stable; fresh bread, naan and refrigerated crusts are not).
    - Non-perishable items (coffee, rice, canned goods, spices, oil) are is_perishable=false;
      they do not expire.
    - Non-food items (apparel, housewares, electronics, flowers, tobacco) get is_food=false,
      is_perishable=false.
    - If you are unsure, lower confidence rather than guessing wildly.

    Examples:
      "KS ORG A2 PR"      -> {"canonical_name":"Organic A2 Milk","brand":"Kirkland Signature","category":"Dairy Products & Eggs","pkg_size":"1/2 gal","unit":"volume","is_food":true,"is_perishable":true,"storage":"fridge","confidence":0.8}
      "KS COLMBIAN"       -> {"canonical_name":"Colombian Coffee","brand":"Kirkland Signature","category":"Beverages","pkg_size":null,"unit":"count","is_food":true,"is_perishable":false,"storage":"pantry","confidence":0.75}
      "PASTURE EGGS"      -> {"canonical_name":"Pasture-Raised Eggs","brand":null,"category":"Dairy Products & Eggs","pkg_size":null,"unit":"count","is_food":true,"is_perishable":true,"storage":"fridge","confidence":0.8}
      "MWCHINOPANT"       -> {"canonical_name":"Apparel","brand":null,"category":null,"pkg_size":null,"unit":"count","is_food":false,"is_perishable":false,"storage":"pantry","confidence":0.6}
      "SHRIMP 31/40"      -> {"canonical_name":"Shrimp","brand":null,"category":"Seafood","pkg_size":null,"unit":"weight","is_food":true,"is_perishable":true,"storage":"freezer","confidence":0.7}
      "WW SANDWICH BREAD" -> {"canonical_name":"Whole Wheat Sandwich Bread","brand":null,"category":"Bakery","pkg_size":null,"unit":"count","is_food":true,"is_perishable":true,"storage":"counter","confidence":0.8}
      "CAULIFLOWER CRUST" -> {"canonical_name":"Cauliflower Pizza Crusts","brand":null,"category":"Bakery","pkg_size":null,"unit":"count","is_food":true,"is_perishable":true,"storage":"fridge","confidence":0.7}
      "NAAN DIPPERS"      -> {"canonical_name":"Naan Dippers","brand":null,"category":"Bakery","pkg_size":null,"unit":"count","is_food":true,"is_perishable":true,"storage":"pantry","confidence":0.75}
      "ORG ORANGE JUICE"  -> {"canonical_name":"Orange Juice","brand":null,"category":"Beverages","pkg_size":"1/2 gal","unit":"volume","is_food":true,"is_perishable":true,"storage":"fridge","confidence":0.8}
      "PACKAGED COOKIES"  -> {"canonical_name":"Packaged Cookies","brand":null,"category":"Snacks","pkg_size":null,"unit":"count","is_food":true,"is_perishable":false,"storage":"pantry","confidence":0.75}
      "JASMINE RICE"      -> {"canonical_name":"Jasmine Rice","brand":null,"category":"Pantry Staples","pkg_size":null,"unit":"weight","is_food":true,"is_perishable":false,"storage":"pantry","confidence":0.85}
      "CLOVER HONEY"      -> {"canonical_name":"Honey","brand":null,"category":"Condiments & Sauces","pkg_size":null,"unit":"count","is_food":true,"is_perishable":false,"storage":"pantry","confidence":0.85}

    Respond with ONLY JSON: {"items": [ ... ]}
    """

    public struct Stats: Equatable {
        public var batches = 0
        public var ok = 0
        public var fallback = 0
        public var resolved = 0
        /// Receipt lines still without a product mapping (usually a failed LLM call).
        /// They stay pending and the next `canonicalize` retries them.
        public var pending = 0
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
        _ db: Database, provider: LLMProvider, embedModel: String? = nil, limit: Int? = nil,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> Stats {
        var stats = Stats()
        let items = try pending(db, limit: limit)
        if items.isEmpty { return stats }

        let batches = stride(from: 0, to: items.count, by: batchSize).map {
            Array(items[$0 ..< min($0 + batchSize, items.count)])
        }
        var failed: [[String: SQLValue]] = []
        for (index, batch) in batches.enumerated() {
            stats.batches += 1
            progress?("Classifying products, batch \(index + 1) of \(batches.count)…")
            var stored: [[String: Any]] = []
            do {
                let response = try await provider.chatJSON(system: system, user: buildUser(batch), temperature: 0)
                record(db, purpose: "canonicalize", model: response.model)
                let (batchFailed, batchStored) = try apply(
                    db, batch: batch, data: response.json, model: response.model, stats: &stats
                )
                failed += batchFailed
                stored = batchStored
            } catch {
                print("[canon] batch \(index + 1)/\(batches.count) failed: \(error)")
                failed += batch
            }
            progress?("Resolving shelf life, batch \(index + 1) of \(batches.count)…")
            let shelf = try await ShelfLifeAgent.resolveBatch(
                db, items: stored, provider: provider, embedModel: embedModel, progress: progress
            )
            stats.resolved += shelf.resolved
        }

        if !failed.isEmpty {
            progress?("Retrying \(failed.count) products…")
            for batch in stride(from: 0, to: failed.count, by: batchSize).map({
                Array(failed[$0 ..< min($0 + batchSize, failed.count)])
            }) {
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
                let shelf = try await ShelfLifeAgent.resolveBatch(
                    db, items: stored, provider: provider, embedModel: embedModel,
                    progress: progress
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
