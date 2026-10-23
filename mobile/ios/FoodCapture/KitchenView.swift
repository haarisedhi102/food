import Charts
import FoodCore
import SwiftUI

/// The app's primary screen. It leads with what needs action — a **Use soon** list of everything
/// expiring within a week, across every shelf — then one section per shelf for browsing, with
/// long shelves (the pantry) collapsed so the tab is a screenful, not a 400-row wall. Used /
/// tossed live in native swipe actions rather than inline buttons, and every row carries a
/// days-left badge with an accessible expiry phrase. Search filters everything in one list.
struct KitchenView: View {
    @EnvironmentObject var app: AppModel
    @State private var path: [ItemRow] = []
    @State private var didAutoOpen = false
    @State private var showingSync = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if app.isSearching {
                    searchSection
                } else {
                    reviewSection
                    expiringSection
                    ForEach(app.shelves, id: \.0) { location, items in
                        shelfSection(location, items)
                    }
                    expiredSection
                    archivedSection
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #else
            .listStyle(.inset)
            #endif
            .safeAreaInset(edge: .top, spacing: 0) {
                SyncStatusBanner(
                    stage: app.isBusy ? app.syncStatus : "",
                    toast: app.syncToast,
                    toastFailed: app.syncToastFailed
                )
                .animation(.snappy, value: app.isBusy)
                .animation(.snappy, value: app.syncToast)
            }
            .navigationTitle("Kitchen")
            #if os(iOS)
            .searchable(
                text: $app.query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search your kitchen"
            )
            #else
            .searchable(text: $app.query, prompt: "Search your kitchen")
            #endif
            .navigationDestination(for: ItemRow.self) { ItemDetailView(item: $0) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        showingSync = true
                    } label: {
                        Label("Sync receipts", systemImage: "tray.and.arrow.down")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        app.refresh()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }

            }
            .sheet(isPresented: $showingSync) {
                SyncSheet()
            }
            .onAppear { autoOpen() }
        }
    }

    // MARK: - Sections

    /// One action for everything the user marked wrong. Kept off Settings: this is a queue
    /// of items that need work, so it belongs on the screen where the items live.
    @ViewBuilder
    private var reviewSection: some View {
        if app.flaggedCount > 0 {
            Section {
                Button {
                    Task { await app.resolveFlagged() }
                } label: {
                    Label(
                        "Re-resolve \(app.flaggedCount) flagged "
                            + (app.flaggedCount == 1 ? "item" : "items"),
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                }
                .disabled(app.isBusy)
            } header: {
                Label("Needs review", systemImage: "exclamationmark.bubble")
            } footer: {
                Text("Shelf lives you marked wrong. Re-resolving asks the model again and "
                    + "updates the expiry.")
            }
        }
    }

    @ViewBuilder
    private var expiringSection: some View {
        Section {
            if app.expiring.isEmpty {
                Text("Nothing expiring in the next \(AppModel.useSoonDays) days.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(app.expiring) { item in
                    itemRow(item)
                }
            }
        } header: {
            Label("Use soon", systemImage: "exclamationmark.triangle")
        } footer: {
            if !app.expiring.isEmpty {
                Text("Across every shelf, expiring within \(AppModel.useSoonDays) days.")
            }
        }
    }

    @ViewBuilder
    private func shelfSection(_ location: String, _ items: [ItemRow]) -> some View {
        let total = app.shelfCount(location)
        let expanded = app.isShelfExpanded(location)
        Section {
            if total == 0 {
                Text("Empty")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if expanded {
                ForEach(items) { item in
                    itemRow(item)
                }
                if items.isEmpty {
                    Text("Everything here is already listed under Use soon.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if app.expandedShelves.contains(location), items.count >= AppModel.collapseThreshold {
                    Button("Show fewer") { app.toggleShelf(location) }
                        .font(.subheadline)
                }
            } else {
                Button {
                    app.toggleShelf(location)
                } label: {
                    Label("Show \(items.count) more", systemImage: "chevron.down")
                        .font(.subheadline)
                }
            }
        } header: {
            HStack {
                Label(location.capitalized, systemImage: shelfSymbol(location))
                Spacer()
                Text("\(total)")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var searchSection: some View {
        let results = app.searchResults(app.query)
        Section {
            if results.isEmpty {
                ContentUnavailableView.search(text: app.query)
            } else {
                ForEach(results) { item in
                    itemRow(item)
                }
            }
        } header: {
            Text("\(results.count) \(results.count == 1 ? "match" : "matches")")
        }
    }

    @ViewBuilder
    private var expiredSection: some View {
        if !app.expiredRows.isEmpty {
            Section {
                ForEach(app.expiredRows) { item in
                    itemRow(item)
                }
            } header: {
                Label("Expired", systemImage: "clock.badge.exclamationmark")
            } footer: {
                Text("Past their shelf life. Swipe to toss or mark used; they archive "
                    + "automatically after 14 days.")
            }
        }
    }

    @ViewBuilder
    private var archivedSection: some View {
        Section {
            Button(app.showArchived ? "Hide archived" : "Show archived") {
                app.toggleArchived()
            }
            if app.showArchived {
                if app.archivedRows.isEmpty {
                    Text("No archived items")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(app.archivedRows) { item in
                        HStack {
                            Text(item.name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                            Text(item.status)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Row

    private func itemRow(_ item: ItemRow) -> some View {
        NavigationLink(value: item) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.body)
                        .lineLimit(2)
                    HStack(spacing: 4) {
                        if let brand = item.brandText {
                            Text(brand)
                                .lineLimit(1)
                            Text("·")
                        }
                        Text(item.metaLine)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                ExpiryBadge(days: item.daysLeft)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(for: item))
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                app.setStatus(item.id, "tossed")
            } label: {
                Label("Tossed", systemImage: "trash")
            }
            Button {
                app.setStatus(item.id, "consumed")
            } label: {
                Label("Used", systemImage: "checkmark")
            }
            .tint(.green)
        }
    }

    private func shelfSymbol(_ location: String) -> String {
        switch location {
        case "fridge": return "refrigerator"
        case "freezer": return "snowflake"
        case "counter": return "oven"
        default: return "cabinet"
        }
    }

    /// VoiceOver phrasing: "Mozzarella Shredded Cheese, Kirkland Signature, in 3 days".
    private func accessibilityLabel(for item: ItemRow) -> String {
        [item.name, item.brandText, item.accessibilityExpiry]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    /// Visual-check hook: `FOOD_ITEM=<inventory id>` opens that item's detail on launch.
    private func autoOpen() {
        guard !didAutoOpen,
              let raw = ProcessInfo.processInfo.environment["FOOD_ITEM"],
              let id = Int(raw) else { return }
        didAutoOpen = true
        if let row = app.allActive.first(where: { $0.id == id }) {
            path = [row]
        }
    }
}

/// Colour-coded day badge, matching `badge()` in the Python template.
struct ExpiryBadge: View {
    let days: Int?

    var body: some View {
        Text(label)
            .font(.caption2)
            .fontWeight(days != nil && days! <= 3 ? .semibold : .regular)
            .monospacedDigit()
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
            .accessibilityHidden(true)
    }

    private var label: String {
        guard let days = days else { return "no expiry" }
        switch days {
        case ..<(-1): return "\(-days)d past"
        case -1: return "1d past"
        case 0: return "today"
        case 1: return "1d"
        default: return "\(days)d"
        }
    }

    private var color: Color {
        guard let days = days else { return .secondary }
        if days < 0 { return .secondary }
        if days <= 1 { return .red }
        if days <= 3 { return .orange }
        return .green
    }
}

/// Item detail: header badges, price chart, and the purchases & stock table. Reachable by
/// tapping a row; used / tossed are also available here for discoverability.
struct ItemDetailView: View {
    let item: ItemRow
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draftDays = 7

    var body: some View {
        let product = item.productID.flatMap(app.product) ?? [:]
        let stock = item.productID.map { app.stock($0) } ?? []
        let freshExpiry = stock.first { $0["id"]?.intValue == item.id }?["expires_on"]?.stringValue
        let daysLeft = Chat.daysLeft(freshExpiry) ?? item.daysLeft
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name).font(.title2).bold()
                    Text(headerLine(product)).font(.subheadline).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    ExpiryBadge(days: daysLeft)
                    if let days = product["shelf_life_days"]?.intValue {
                        badge("shelf life ≈ \(days)d", color: .secondary)
                    }
                    if let source = product["shelf_life_source"]?.stringValue {
                        sourceBadge(source)
                    }
                    if product["needs_review"]?.intValue == 1 {
                        badge("needs review", color: .orange)
                    }
                }
                if let fid = product["foodkeeper_id"]?.intValue {
                    badge("FoodKeeper #\(fid)", color: .secondary)
                }
            }

            if let productID = item.productID {
                Section("Price history") {
                    let points = app.pricePoints(productID)
                    if points.isEmpty {
                        Text("No priced purchases recorded.").foregroundStyle(.secondary)
                    } else {
                        priceChart(points)
                    }
                }

                Section("Purchases & stock") {
                    if stock.isEmpty {
                        Text("Never stocked.").foregroundStyle(.secondary)
                    } else {
                        stockTable(stock)
                    }
                }
            }

            if let productID = item.productID {
                Section {
                    HStack {
                        Button {
                            draftDays = max(1, draftDays - 1)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Fewer days")
                        Spacer()
                        Text("\(draftDays) days")
                            .font(.headline)
                            .monospacedDigit()
                        Spacer()
                        Button {
                            draftDays = min(3650, draftDays + 1)
                        } label: {
                            Image(systemName: "plus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("More days")
                    }
                    Button("Save shelf life", systemImage: "checkmark.circle") {
                        app.setShelfLife(productID: productID, days: draftDays)
                    }
                    if product["needs_review"]?.intValue == 1 {
                        Button("Clear review", systemImage: "checkmark.seal") {
                            app.clearReview(productID: productID)
                        }
                    } else {
                        Button("Mark as wrong", systemImage: "exclamationmark.bubble") {
                            app.flagForReview(productID: productID)
                        }
                    }
                } header: {
                    Text("Shelf life")
                } footer: {
                    Text("Your value is used for future purchases of this product. "
                        + "Marking it wrong lets the next sync re-research it.")
                }
            }

            Section {
                Button {
                    app.setStatus(item.id, "consumed")
                    dismiss()
                } label: {
                    Label("Mark used", systemImage: "checkmark")
                }
                Button(role: .destructive) {
                    app.setStatus(item.id, "tossed")
                    dismiss()
                } label: {
                    Label("Toss", systemImage: "trash")
                }
            } footer: {
                Text("Used marks it eaten; Toss marks it wasted. Both remove it from stock.")
            }
        }
        .navigationTitle(item.name)
        .onAppear {
            if let days = product["shelf_life_days"]?.intValue {
                draftDays = min(max(days, 1), 3650)
            }
        }
    }

    private func headerLine(_ product: [String: SQLValue]) -> String {
        var parts: [String] = []
        if let brand = product["brand"]?.stringValue, !brand.isEmpty { parts.append(brand) }
        if let category = product["category"]?.stringValue, !category.isEmpty { parts.append(category) }
        if let storage = product["storage"]?.stringValue, !storage.isEmpty { parts.append(storage) }
        parts.append((product["is_perishable"]?.intValue ?? 0) != 0 ? "perishable" : "shelf-stable")
        return parts.joined(separator: " · ")
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(.quaternary, in: Capsule())
            .foregroundStyle(color)
    }

    private func sourceBadge(_ source: String) -> some View {
        let color: Color = source == "foodkeeper" ? .green
            : source == "llm" ? .indigo
            : source == "user" ? .blue
            : .secondary
        let label = source == "user" ? "set by you" : "source: \(source)"
        return Text(label)
            .font(.caption2).fontWeight(.medium)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    @ViewBuilder
    private func priceChart(_ points: [[String: Any]]) -> some View {
        let series: [(date: Date, price: Double)] = points.compactMap { point in
            guard let raw = point["date"] as? String, let date = Dates.parse(raw) else { return nil }
            return (date, point["price"] as? Double ?? 0)
        }
        if series.isEmpty {
            Text("No priced purchases recorded.").foregroundStyle(.secondary)
        } else {
            Chart(series, id: \.date) { point in
                LineMark(x: .value("Date", point.date), y: .value("Price", point.price))
                    .interpolationMethod(.catmullRom)
                PointMark(x: .value("Date", point.date), y: .value("Price", point.price))
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisValueLabel {
                        if let price = value.as(Double.self) {
                            Text(String(format: "$%.2f", price))
                        }
                    }
                }
            }
            .frame(height: 160)
        }
    }

    private func stockTable(_ stock: [[String: SQLValue]]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            GridRow {
                Text("Bought"); Text("Status"); Text("Qty"); Text("Expires")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            ForEach(Array(stock.enumerated()), id: \.offset) { _, row in
                GridRow {
                    Text(row["acquired_on"]?.stringValue ?? "")
                    Text(row["status"]?.stringValue ?? "")
                    Text("×\((row["remaining_qty"]?.doubleValue ?? 0).formatted())")
                    Text(row["expires_on"]?.stringValue ?? "—")
                }
                .font(.caption)
            }
        }
    }
}

extension ItemRow: Hashable {
    static func == (lhs: ItemRow, rhs: ItemRow) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
