import SwiftUI

/// The receipt-syncing surface, reached from Settings rather than living in the tab bar
/// ("a tab bar is for navigation, not actions"). Log into a retailer in the in-app browser,
/// fetch the raw payload, then run the on-device pipeline with **Sync**.
struct SyncSheet: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var model: WebModel
    @Environment(\.dismiss) private var dismiss

    @State private var exportText = ""
    @State private var exportURL: URL?
    @State private var storageKeys: [String] = []
    @State private var showExport = false
    @State private var errorMessage: String?
    @State private var pendingPayload: String?
    @State private var pendingRetailer: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Retailer", selection: $model.retailer) {
                    ForEach(Retailer.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: model.retailer) { _, _ in model.load() }
                .padding(.horizontal)
                .padding(.top, 6)

                ZStack(alignment: .top) {
                    WebView(webView: model.webView)
                    if model.isBusy {
                        ProgressView()
                            .padding(8)
                            .background(.thinMaterial, in: Capsule())
                    }
                }

                statusBar
            }
            .navigationTitle("Sync receipts")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        model.reload()
                    } label: {
                        Label("Reload page", systemImage: "arrow.clockwise")
                    }
                }
                #if os(iOS)
                ToolbarItemGroup(placement: .bottomBar) { actionButtons }
                #else
                ToolbarItemGroup(placement: .automatic) { actionButtons }
                #endif
            }
        }
        #if os(macOS)
        // A macOS sheet sizes to its content, and WKWebView reports no intrinsic size, so
        // without an explicit frame the browser collapses and the page never shows.
        .frame(minWidth: 900, minHeight: 720)
        #endif
        .sheet(isPresented: $showExport) {
            ExportSheet(text: exportText, url: exportURL, storageKeys: storageKeys)
        }
        .onAppear { model.load() }
        .alert(
            "Sync failed",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var statusBar: some View {
        VStack(spacing: 4) {
            if !model.progress.isEmpty {
                Text(model.progress)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if app.isBusy, !app.syncStatus.isEmpty {
                Text(app.syncStatus)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !app.message.isEmpty {
                Text(app.message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func sync() async {
        guard let payload = pendingPayload, let retailer = pendingRetailer else { return }
        print("[sync] tapped Sync (\(retailer), \(payload.count) bytes)")
        // Close the browser and show the Kitchen, where the progress banner lives.
        app.selectedTab = 0
        dismiss()
        await app.sync(retailer: retailer, payloadJSON: payload)
    }

    private func fetch() async {
        model.isBusy = true
        defer { model.isBusy = false }
        let retailer = model.retailer.rawValue
        let (summary, payload, ok) = await model.fetchReceipts(
            knownKeys: app.knownReceiptKeys(for: retailer),
            since: app.latestPurchaseDate(for: retailer)
        )
        print("[fetch] \(retailer): ok=\(ok) \(summary) payload=\(payload.count) bytes")
        do {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(model.retailer.rawValue)-raw.json")
            try payload.write(to: url, atomically: true, encoding: .utf8)
            if ok {
                pendingPayload = payload
                pendingRetailer = model.retailer.rawValue
            } else {
                pendingPayload = nil
                pendingRetailer = nil
                errorMessage = summary
            }
            exportText = "\(summary)\n\nwrote \(url.lastPathComponent) (\(payload.count) bytes)"
            exportURL = url
            storageKeys = []
            showExport = true
            model.progress = "\(model.retailer.title): \(summary)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        Button("Probe") { Task { await probe() } }
            .disabled(model.isBusy)
        Button("Fetch") { Task { await fetch() } }
            .disabled(model.isBusy)
        Spacer()
        if pendingPayload != nil {
            Button {
                Task { await sync() }
            } label: {
                if app.isBusy { ProgressView() } else { Text("Sync") }
            }
            .buttonStyle(.borderedProminent)
            .disabled(app.isBusy)
        }
    }

    private func probe() async {
        model.isBusy = true
        defer { model.isBusy = false }
        let result = await model.probeDetails()
        exportText = result
        exportURL = nil
        storageKeys = []
        showExport = true
        model.progress = "probe: \(result.prefix(70))"
    }
}

/// Shows the fetched/captured output (plus POC diagnostics) and offers Share.
struct ExportSheet: View {
    let text: String
    let url: URL?
    let storageKeys: [String]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if !storageKeys.isEmpty {
                    Section("storage keys seen on this page") {
                        ForEach(storageKeys, id: \.self) {
                            Text($0).font(.system(.caption, design: .monospaced))
                        }
                    }
                }
                Section("output") {
                    Text(text)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .navigationTitle("Result")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { if let url { ShareLink(item: url) } }
            }
        }
    }
}
