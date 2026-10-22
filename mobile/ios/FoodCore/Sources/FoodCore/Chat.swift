import Foundation

/// Port of the chat/digest prompts in `food/web/app.py` and `food/cli.py`.
public enum Chat {
    public static let system = SharedContract.prompts["chat"] ?? ""
    public static let digestSystem = SharedContract.prompts["digest"] ?? ""

    /// "days left" from `expires_on` vs today (UTC, matching how dates are parsed).
    public static func daysLeft(_ expiresOn: String?) -> Int? {
        guard let expiresOn = expiresOn, let date = Dates.parse(expiresOn) else { return nil }
        return Dates.calendar().dateComponents([.day], from: Dates.startOfToday(), to: date).day
    }

    /// Human phrasing for a days-left value: "today", "tomorrow", "in 3 days", "2 days ago",
    /// "expired". Mirrors the `when` phrasing in the Python snapshot so both stay in step.
    public static func relative(_ days: Int?) -> String {
        guard let days = days else { return "no expiry" }
        switch days {
        case ..<(-1): return "\(-days) days past"
        case -1: return "yesterday"
        case 0: return "today"
        case 1: return "tomorrow"
        default: return "in \(days) days"
        }
    }

    /// One line per in-stock item, used as the model's context.
    public static func snapshot(_ db: Database) throws -> String {
        var lines: [String] = []
        for row in try Inventory.active(db) {
            if row["status"]?.stringValue == "expired" { continue }
            let name = row["canonical_name"]?.stringValue ?? ""
            let qty = row["remaining_qty"]?.doubleValue ?? 0
            let location = row["location"]?.stringValue ?? "pantry"
            let when: String
            switch daysLeft(row["expires_on"]?.stringValue) {
            case .some(let d) where d >= 0: when = "\(d)d left"
            case .some(let d): when = "\(-d)d past"
            case .none: when = "no expiry"
            }
            lines.append("- \(name) x\(fmt(qty)) [\(location)] (\(when))")
        }
        return lines.isEmpty ? "(nothing in stock)" : lines.joined(separator: "\n")
    }

    public static func ask(_ db: Database, question: String, provider: LLMProvider) async throws -> String {
        let user = "Current stock:\n\(try snapshot(db))\n\nQuestion: \(question)"
        return try await provider.chatText(system: system, user: user, temperature: 0.2)
    }

    /// "Use it or lose it" plan from what's expiring soonest.
    public static func digest(
        _ db: Database, days: Int = 3, provider: LLMProvider, today: String? = nil
    ) async throws -> String? {
        let soon = try Inventory.expiringSoon(db, days: days, today: today)
        if soon.isEmpty { return nil }
        let listed = soon.map { row -> String in
            let name = row["canonical_name"]?.stringValue ?? ""
            let qty = fmt(row["remaining_qty"]?.doubleValue ?? 0)
            let location = row["location"]?.stringValue ?? ""
            return "- \(name) x\(qty) [\(location)] (by \(row["expires_on"]?.stringValue ?? "?"))"
        }.joined(separator: "\n")
        return try await provider.chatText(
            system: digestSystem,
            user: "Use these up soon:\n\(listed)\n\nSuggest a short plan.",
            temperature: 0.2
        )
    }

    static func fmt(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}

/// Small date helpers shared by Chat and the app.
public enum Dates {
    static func formatter(_ format: String) -> DateFormatter {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "UTC")
        df.dateFormat = format
        return df
    }

    public static func parse(_ iso: String) -> Date? { formatter("yyyy-MM-dd").date(from: iso) }

    /// UTC calendar, matching the formatter — keeps day arithmetic free of device-timezone drift.
    public static func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    public static func startOfToday() -> Date {
        calendar().startOfDay(for: Date())
    }

    public static func today() -> String { formatter("yyyy-MM-dd").string(from: Date()) }
}
