import Foundation

/// Port of `food/shelflife.py`'s parsing + lookup. FoodKeeper is the USDA reference table
/// (public domain). Its Min/Max numbers are meaningless without the companion `*_Metric`
/// column, so everything is converted to days and qualitative metrics become unknown.
public enum FoodKeeper {
    static let metricDays: [String: Int] = ["Days": 1, "Weeks": 7, "Months": 30, "Years": 365]
    static let qualitative: Set<String> = [
        "When Ripe", "Indefinitely", "Not Recommended", "Package use-by date",
    ]
    static let storageColumn: [String: String] = [
        "freezer": "dop_freeze_days",
        "pantry": "pantry_days",
        "fridge": "dop_refrigerate_days",
        "counter": "dop_refrigerate_days",
    ]

    /// `to_days`: convert a Min/Max/Metric triple to whole days. Qualitative metrics -> nil.
    public static func toDays(_ minv: Any?, _ maxv: Any?, _ metric: Any?, prefer: String = "min") -> Int? {
        guard let m = Normalizer.str(metric), !m.isEmpty, !qualitative.contains(m) else { return nil }
        guard let mult = metricDays[m] else { return nil }
        let vals = [minv, maxv].compactMap(asDouble)
        guard !vals.isEmpty else { return nil }
        let base = (prefer == "min" ? vals.min()! : vals.max()!)
        return max(1, Int((base * Double(mult)).rounded()))
    }

    /// Numeric coercion that accepts both Int and Double (Python's `isinstance(v,(int,float))`).
    static func asDouble(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        return nil
    }

    /// FoodKeeper rows are a list of single-key dicts: `[{"ID":1},{"Name":"Butter"},…]`.
    static func mergeRow(_ row: [Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for cell in row {
            if let d = cell as? [String: Any] { out.merge(d) { _, new in new } }
        }
        return out
    }

    public static func parse(_ payload: Any) -> (products: [[String: Any]], categories: [Int: String]) {
        guard let payload = payload as? [String: Any], let sheets = payload["sheets"] as? [Any] else {
            return ([], [:])
        }
        var sheet: [String: [Any]] = [:]
        for case let s as [String: Any] in sheets {
            if let name = s["name"] as? String { sheet[name] = (s["data"] as? [Any]) ?? [] }
        }
        let products = (sheet["Product"] ?? []).compactMap { ($0 as? [Any]).map(mergeRow) }
        var categories: [Int: String] = [:]
        for case let row as [Any] in sheet["Category"] ?? [] {
            let m = mergeRow(row)
            guard let cid = (m["ID"] as? Double).map({ Int($0) }) else { continue }
            var label = (m["Category_Name"] as? String) ?? ""
            if let sub = m["Subcategory_Name"] as? String, !sub.isEmpty {
                label = "\(label) / \(sub)"
            }
            categories[cid] = label.trimmingCharacters(in: .whitespaces)
        }
        return (products, categories)
    }

    /// `load`: replace `shelf_life_ref` with the parsed dataset. Returns the row count.
    @discardableResult
    public static func load(_ db: Database, payload: Any) throws -> Int {
        let (products, categories) = parse(payload)
        try db.exec("DELETE FROM shelf_life_ref")
        var n = 0
        for p in products {
            guard let fid = (p["ID"] as? Double).map({ Int($0) }) else { continue }
            let cat = (p["Category_ID"] as? Double).flatMap { categories[Int($0)] }
            let raw = (try? JSONSerialization.data(withJSONObject: p))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            try db.run(
                """
                INSERT INTO shelf_life_ref
                (foodkeeper_id, name, subtitle, category, keywords, pantry_days,
                 dop_refrigerate_days, refrigerate_after_opening_days, dop_freeze_days, raw_json)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .int(Int64(fid)),
                    text(p["Name"]), text(p["Name_subtitle"]), text(cat), text(p["Keywords"]),
                    intOrNull(toDays(p["Pantry_Min"], p["Pantry_Max"], p["Pantry_Metric"])),
                    intOrNull(toDays(
                        p["DOP_Refrigerate_Min"], p["DOP_Refrigerate_Max"], p["DOP_Refrigerate_Metric"]
                    )),
                    intOrNull(toDays(
                        p["Refrigerate_After_Opening_Min"], p["Refrigerate_After_Opening_Max"],
                        p["Refrigerate_After_Opening_Metric"]
                    )),
                    intOrNull(toDays(p["DOP_Freeze_Min"], p["DOP_Freeze_Max"], p["DOP_Freeze_Metric"])),
                    .text(raw),
                ]
            )
            n += 1
        }
        return n
    }

    /// `days_for`: the shelf life for a FoodKeeper row given where it is stored.
    public static func daysFor(
        _ db: Database, foodkeeperID: Int, storage: String = "fridge", opened: Bool = false
    ) -> Int? {
        guard let row = (try? db.query(
            "SELECT * FROM shelf_life_ref WHERE foodkeeper_id = ?", [.int(Int64(foodkeeperID))]
        ))?.first else { return nil }
        if opened, let v = row["refrigerate_after_opening_days"]?.intValue, v != 0 { return v }
        let col = storageColumn[storage] ?? "dop_refrigerate_days"
        return row[col]?.intValue
    }

    private static func text(_ v: Any?) -> SQLValue {
        (v as? String).map { SQLValue.text($0) } ?? .null
    }

    private static func intOrNull(_ v: Int?) -> SQLValue {
        v.map { SQLValue.int(Int64($0)) } ?? .null
    }
}
