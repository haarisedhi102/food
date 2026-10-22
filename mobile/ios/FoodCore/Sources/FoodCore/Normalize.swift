import CryptoKit
import Foundation

/// Port of `food/normalize.py` — deterministic, per-retailer structural adapters. No LLM.
/// Turns each retailer's raw receipt JSON into provisional records keyed on the retailer's
/// *stable* identifier (Costco `itemNumber`, Kroger `upc`).

public enum Normalizer {
    public static let krogerGroceryTypes: Set<String> = [
        "IN_STORE", "SELF_SERVICE_PICKUP", "DELIVERY", "INSTACART_DELIVERY", "SHIP",
    ]

    // MARK: - Costco

    public static func normalizeCostco(_ raw: Any) -> [NormalizedReceipt] {
        var receipts: [NormalizedReceipt] = []
        for r in extractCostcoReceipts(raw) {
            var items: [NormalizedItem] = []
            for case let it as [String: Any] in (r["itemArray"] as? [Any]) ?? [] {
                let desc = [it["itemDescription01"], it["itemDescription02"]]
                    .compactMap { str($0)?.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespaces)

                let unit = it["unit"]
                // skip returns (negative unit) and "/<item>" discount lines
                if let u = unit as? Double, u < 0 { continue }
                if desc.hasPrefix("/") { continue }

                let number = (str(it["itemNumber"]) ?? "").trimmingCharacters(in: .whitespaces)
                items.append(
                    NormalizedItem(
                        rawDescription: desc,
                        itemKey: number.isEmpty ? fallbackKey([desc]) : number,
                        rawPkgSize: nil,
                        quantity: (unit as? Double) ?? 1.0,
                        unitPriceCents: cents(it["itemUnitPriceAmount"]),
                        lineTotalCents: cents(it["amount"])
                    )
                )
            }
            let ext = str(r["transactionBarcode"])
                ?? "\(str(r["warehouseNumber"]) ?? "")-\(str(r["transactionNumber"]) ?? "")-\(str(r["transactionDate"]) ?? "")"
            receipts.append(
                NormalizedReceipt(
                    externalID: ext,
                    purchasedOn: localDate(r["transactionDateTime"] ?? r["transactionDate"]),
                    store: str(r["warehouseName"]),
                    totalCents: cents(r["total"]),
                    items: items,
                    rawJSON: jsonString(r)
                )
            )
        }
        return receipts
    }

    public static func extractCostcoReceipts(_ payload: Any) -> [[String: Any]] {
        guard let payload = payload as? [String: Any],
              let data = payload["data"] as? [String: Any],
              let node = data["receiptsWithCounts"] else { return [] }
        let raw: [Any]
        if let list = node as? [Any] {
            raw = list
        } else if let dict = node as? [String: Any] {
            raw = (dict["receipts"] as? [Any]) ?? []
        } else {
            raw = []
        }
        return raw.compactMap { $0 as? [String: Any] }
    }

    // MARK: - Kroger

    public static func normalizeKroger(_ raw: Any) -> [NormalizedReceipt] {
        guard let raw = raw as? [String: Any] else { return [] }
        let search = (raw["search"] as? [Any]) ?? []
        let details = (raw["details"] as? [String: Any]) ?? [:]

        var meta: [String: [String: Any]] = [:]
        for case let r as [String: Any] in search {
            if let key = str(r["receiptKey"]) { meta[key] = r }
        }

        var receipts: [NormalizedReceipt] = []
        // JSON dictionaries are unordered in Swift; sort keys so runs are reproducible.
        for key in details.keys.sorted() {
            guard let rec = meta[key] else { continue }
            if let pt = str(rec["purchaseType"]), !krogerGroceryTypes.contains(pt) { continue }

            var payload: Any = details[key]!
            // archives may hold the raw payload or the whole fetch-result dict
            if let p = payload as? [String: Any], let inner = p["json"] { payload = inner }

            // A batch returns one receipt per key, each self-identifying by
            // purchaseId.receiptId. Keep only *this* key's receipt.
            var match: [String: Any]?
            for detail in extractKrogerDetails(payload) {
                let rid = (detail["purchaseId"] as? [String: Any]).flatMap { str($0["receiptId"]) }
                if rid == nil || rid == key { match = detail; break }
            }
            guard let m = match else { continue }

            var items: [NormalizedItem] = []
            for case let item as [String: Any] in (m["items"] as? [Any]) ?? [] {
                let pd = (item["purchasedData"] as? [String: Any]) ?? [:]
                let di = (pd["displayInfo"] as? [String: Any]) ?? [:]
                let desc = str(di["description"]) ?? ""
                let upc = (str(pd["upc"]) ?? "").trimmingCharacters(in: .whitespaces)
                let qty = (pd["quantityInfo"] as? [String: Any])?["received"]
                let pricing = (pd["pricingInfo"] as? [String: Any]) ?? [:]
                items.append(
                    NormalizedItem(
                        rawDescription: desc,
                        itemKey: upc.isEmpty ? fallbackKey([desc]) : upc,
                        rawPkgSize: str(di["customerFacingSize"]),
                        quantity: (qty as? Double) ?? 1.0,
                        unitPriceCents: cents(pricing["unitPricePaid"]),
                        lineTotalCents: cents(pricing["totalPricePaid"])
                    )
                )
            }

            let total = (m["costSummary"] as? [String: Any])?["total"] ?? rec["total"]
            receipts.append(
                NormalizedReceipt(
                    externalID: key,
                    purchasedOn: localDate((rec["createdDateTime"] as? [String: Any])?["value"]),
                    store: str(rec["handoffStoreId"]),
                    totalCents: cents(total),
                    items: items,
                    rawJSON: jsonString(rec)
                )
            )
        }
        return receipts
    }

    public static func extractKrogerDetails(_ payload: Any) -> [[String: Any]] {
        guard let payload = payload as? [String: Any],
              let data = payload["data"] as? [String: Any] else { return [] }
        guard let node = data["purchaseHistoryDetails"] else { return [] }
        if let list = node as? [Any] { return list.compactMap { $0 as? [String: Any] } }
        if let one = node as? [String: Any] { return [one] }
        return []
    }

    // MARK: - Shared helpers (ported from normalize.py)

    /// `_cents`: numeric -> dollars*100; string -> first number parsed, *100.
    static func cents(_ v: Any?) -> Int? {
        guard let v = v, !(v is NSNull) else { return nil }
        if let d = v as? Double { return Int((d * 100).rounded()) }
        if let i = v as? Int { return i * 100 }
        let s = String(describing: v).replacingOccurrences(of: ",", with: "")
        guard let r = s.range(of: #"-?\d+(?:\.\d+)?"#, options: .regularExpression),
              let d = Double(s[r]) else { return nil }
        return Int((d * 100).rounded())
    }

    /// `_local_date`: ISO prefix (matches Python's `fromisoformat(...).date()`), else the
    /// same handful of formats, else nil.
    static func localDate(_ v: Any?) -> String? {
        guard let v = v, !(v is NSNull) else { return nil }
        let s = String(describing: v).trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "Z", with: "")
        guard !s.isEmpty else { return nil }
        if let r = s.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) {
            return String(s[r])
        }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "UTC")
        let head = String(s.prefix(10))
        for fmt in ["MM/dd/yyyy", "MM/dd/yy", "yyyy/MM/dd"] {
            df.dateFormat = fmt
            if let d = df.date(from: head) {
                df.dateFormat = "yyyy-MM-dd"
                return df.string(from: d)
            }
        }
        return nil
    }

    /// `_fallback_key`: `"desc:" + sha1(joined.lowercased())[:16]`.
    static func fallbackKey(_ parts: [String?]) -> String {
        let joined = parts
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { $0.lowercased() }
            .joined(separator: " ")
        let digest = Insecure.SHA1.hash(data: Data(joined.utf8))
        let hex = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return "desc:" + hex
    }

    static func str(_ v: Any?) -> String? {
        guard let v = v, !(v is NSNull) else { return nil }
        if let s = v as? String { return s }
        return String(describing: v)
    }

    static func jsonString(_ object: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }
}
