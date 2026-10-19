import Foundation
import FoodCore

/// Owns the on-device database and the data the UI renders. The DB path can be overridden with
/// `FOOD_DB_PATH` (used for seeded visual checks in the simulator); otherwise it lives in
/// Application Support.
    @MainActor
final class AppModel: ObservableObject {
    static let locations = ["fridge", "freezer", "pantry", "counter"]

    /// The "use soon" horizon: everything expiring within this many days leads the Kitchen tab,
    /// across every shelf. 7 days is the useful weekly-planning window.
    static let useSoonDays = 7

    let db: Database
    @Published var shelves: [(String, [ItemRow])] = []
    @Published var expiring: [ItemRow] = []
    @Published var archivedRows: [ItemRow] = []
    @Published var showArchived = false
    @Published var isBusy = false
    @Published var message = ""
    /// Empty means "no active search" — all shelves are shown ungrouped by shelf.
    @Published var query = ""
    /// Shelves whose full list is expanded in the browser. Long shelves (pantry) start collapsed
    /// so the tab leads with what needs action rather than every box of rice you own.
    @Published var expandedShelves: Set<String> = []

    /// A shelf starts collapsed past this many rows. Only the pantry ever reaches this in
    /// practice (it holds hundreds of mostly shelf-stable goods), so the fridge, freezer and
    /// counter stay open while the pantry folds away behind one tap.
    static let collapseThreshold = 50

    /// True while a search narrows the list, so the view can render a single result section.
    var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Every active row (any shelf), used as the source for search. Sorted by urgency so
    /// results and shelves alike read soonest-first.
    var allActive: [ItemRow] { shelves.flatMap { $0.1 } }

    /// Rows matching the current query by name, brand or category (case-insensitive).
    func searchResults(_ text: String) -> [ItemRow] {
        let needle = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }
        return allActive.filter { item in
            [item.name, item.brand ?? "", item.category ?? ""]
                .contains { $0.lowercased().contains(needle) }
        }
    }

    init() {
        let path = ProcessInfo.processInfo.environment["FOOD_DB_PATH"] ?? AppModel.defaultDBPath()
        do {
            db = try Database(path: path)
            try Schema.initDB(db)
        } catch {
            fatalError("could not open \(path): \(error)")
        }
        refresh()
    }

    static func defaultDBPath() -> String {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("food.db").path
    }

    func refresh() {
        // Mirrors `_shelves` in food/web/app.py: expired rows are not shown on a shelf.
        let active = ((try? Inventory.active(db)) ?? [])
            .filter { $0["status"]?.stringValue != "expired" }
        var grouped: [String: [ItemRow]] = [:]
        for row in active {
            let item = ItemRow(row)
            grouped[item.location, default: []].append(item)
        }

        // "Use soon" leads the tab: everything within the horizon, across all shelves. The shelf
        // sections then show only what's *left* (beyond the horizon), so nothing appears twice
        // and the tab reads as "act on these, browse the rest".
        expiring = ((try? Inventory.expiringSoon(db, days: AppModel.useSoonDays)) ?? [])
            .map(ItemRow.init)
        let soonIDs = Set(expiring.map(\.id))
        shelves = AppModel.locations.map { location in
            (location, (grouped[location] ?? []).filter { !soonIDs.contains($0.id) })
        }

        if showArchived {
            let all = (try? Inventory.active(db, includeArchived: true)) ?? []
            archivedRows = all
                .filter { $0["status"]?.stringValue == "archived" }
                .prefix(100)
                .map(ItemRow.init)
        } else {
            archivedRows = []
        }
    }

    func toggleArchived() {
        showArchived.toggle()
        refresh()
    }

    /// Total rows on a shelf (expiring + the rest), for the section header count.
    func shelfCount(_ location: String) -> Int {
        let soon = expiring.filter { $0.location == location }.count
        let rest = (shelves.first { $0.0 == location }?.1.count) ?? 0
        return soon + rest
    }

    /// Long shelves start collapsed; shorter ones are always shown.
    func isShelfExpanded(_ location: String) -> Bool {
        let rest = (shelves.first { $0.0 == location }?.1.count) ?? 0
        return rest < AppModel.collapseThreshold || expandedShelves.contains(location)
    }

    /// How many rows a collapsed shelf is hiding.
    func collapsedCount(_ location: String) -> Int {
        (shelves.first { $0.0 == location }?.1.count) ?? 0
    }

    func toggleShelf(_ location: String) {
        if expandedShelves.contains(location) {
            expandedShelves.remove(location)
        } else {
            expandedShelves.insert(location)
        }
    }

    func stock(_ id: Int) -> [[String: SQLValue]] {
        (try? ItemDetail.stock(db, productID: id)) ?? []
    }

    var provider: LLMProvider {
        MacPawProvider(config: Settings.providerConfig())
    }

    /// Normalize → store → canonicalize → resolve → inventory, for a payload the web view fetched.
    func sync(retailer: String, payloadJSON: String) async {
        isBusy = true
        defer { isBusy = false }
        do {
            let payload = try JSONSerialization.jsonObject(with: Data(payloadJSON.utf8))
            let config = Settings.providerConfig()

            // Port of `bootstrap`'s reference step: load FoodKeeper before grounding, so shelf
            // lives are grounded rather than LLM-only.
            let loaded = (try? await ReferenceData.loadIfNeeded(db)) ?? 0
            if config.embeddingsConfigured {
                _ = try? await ReferenceData.embedIfNeeded(db, provider: provider, model: config.embedModel)
            }

            let summary = try await Sync.run(
                db, retailer: retailer, payload: payload, provider: provider,
                embedModel: config.embeddingsConfigured ? config.embedModel : nil
            )

            var text = "synced \(summary.newItems) items → \(summary.canonicalized.ok) products"
            if summary.canonicalized.fallback > 0 {
                text += " (\(summary.canonicalized.fallback) fallback)"
            }
            text += ", \(summary.shelfLife.resolved) shelf lives, \(summary.inventory) stock rows"
            if loaded > 0 { text += ", FoodKeeper \(loaded) rows" }
            message = text
            refresh()
        } catch {
            message = "sync failed: \(error)"
        }
    }

    func setStatus(_ id: Int, _ status: String) {
        try? Inventory.setStatus(db, inventoryID: id, status: status)
        refresh()
    }

    func product(_ id: Int) -> [String: SQLValue]? {
        try? ItemDetail.product(db, id: id)
    }

    func pricePoints(_ id: Int) -> [[String: Any]] {
        (try? ItemDetail.pricePoints(db, productID: id)) ?? []
    }
}

/// A row from `inventory` joined with its product, with typed accessors for the views.
struct ItemRow: Identifiable {
    let values: [String: SQLValue]
    let id: Int

    init(_ values: [String: SQLValue]) {
        self.values = values
        self.id = values["id"]?.intValue ?? 0
    }

    var name: String { values["canonical_name"]?.stringValue ?? "Unknown" }
    var brand: String? { values["brand"]?.stringValue }
    var category: String? { values["category"]?.stringValue }
    var location: String { values["location"]?.stringValue ?? "pantry" }
    var quantity: Double { values["remaining_qty"]?.doubleValue ?? 0 }
    var expiresOn: String? { values["expires_on"]?.stringValue }
    var status: String { values["status"]?.stringValue ?? "active" }
    var shelfLifeSource: String? { values["shelf_life_source"]?.stringValue }
    var productID: Int? { values["product_id"]?.intValue }
    var daysLeft: Int? { Chat.daysLeft(expiresOn) }

    /// "×2 · in 3 days" — a friendly version of the Python card's `×qty · date` line.
    var metaLine: String {
        "×\(quantity.formatted()) · \(Chat.relative(daysLeft))"
    }

    /// Short relative label for the trailing badge: "2d", "today", "3d past".
    var badgeLabel: String {
        guard let days = daysLeft else { return "—" }
        switch days {
        case ..<(-1): return "\(-days)d past"
        case -1: return "1d past"
        case 0: return "today"
        case 1: return "1d"
        default: return "\(days)d"
        }
    }

    var brandLine: String? {
        let parts = [brand, category].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Brand for the row's second line, or nil when there's nothing useful to add — no brand,
    /// or a brand the name already contains (e.g. "Kirkland …" in "Kirkland Signature Milk").
    var brandText: String? {
        guard let brand = brand, !brand.isEmpty else { return nil }
        if name.lowercased().contains(brand.lowercased()) { return nil }
        return brand
    }

    /// Fully spelled-out expiry for VoiceOver ("in 3 days").
    var accessibilityExpiry: String { Chat.relative(daysLeft) }
}
