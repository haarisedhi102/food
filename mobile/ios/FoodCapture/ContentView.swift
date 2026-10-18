import SwiftUI

struct ContentView: View {
    @StateObject private var model = WebModel()
    @State private var exportText = ""
    @State private var exportURL: URL?
    @State private var storageKeys: [String] = []
    @State private var showExport = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("Retailer", selection: $model.retailer) {
                    ForEach(Retailer.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: model.retailer) { _, _ in model.load() }

                Button {
                    model.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .padding(.horizontal)
            .padding(.top, 6)

            ZStack(alignment: .top) {
                WebView(webView: model.webView)
                if model.isBusy {
                    ProgressView().padding(8).background(.thinMaterial, in: Capsule())
                }
            }

            VStack(spacing: 6) {
                Text(model.progress)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    Button("Probe") { Task { await probe() } }
                        .buttonStyle(.bordered)
                        .disabled(model.isBusy)
                    Button("Fetch") { Task { await fetch() } }
                        .buttonStyle(.bordered)
                        .disabled(model.isBusy)
                    Spacer()
                    Button("Capture") { Task { await capture() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isBusy)
                }
            }
            .padding(10)
        }
        .sheet(isPresented: $showExport) {
            ExportSheet(text: exportText, url: exportURL, storageKeys: storageKeys)
        }
        .onAppear { model.load() }
        // Deep link so capture can be triggered headlessly: `foodcapture://capture`.
        .onOpenURL { url in
            if url.scheme == "foodcapture", url.host == "capture" {
                Task { await capture() }
            }
        }
        .alert(
            "Capture failed",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func fetch() async {
        model.isBusy = true
        defer { model.isBusy = false }
        let (summary, payload) = await model.fetchReceipts()
        do {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(model.retailer.rawValue)-raw.json")
            try payload.write(to: url, atomically: true, encoding: .utf8)
            exportText = "\(summary)\n\nwrote \(url.lastPathComponent) (\(payload.count) bytes)"
            exportURL = url
            storageKeys = []
            showExport = true
            model.progress = "\(model.retailer.title): \(summary)"
        } catch {
            errorMessage = error.localizedDescription
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

    private func capture() async {
        model.isBusy = true
        defer { model.isBusy = false }

        let fresh = await model.capture()
        storageKeys = (fresh.storage["local"]?.keys.sorted() ?? []).map { "local.\($0)" }
            + (fresh.storage["session"]?.keys.sorted() ?? []).map { "session.\($0)" }

        // Merge into whatever we captured before, so Kroger + Costco end up in one file.
        var accumulated = Session.load(from: model.sessionURL) ?? Session()
        accumulated.merge(fresh)

        do {
            exportText = try accumulated.json()
            try exportText.write(to: model.sessionURL, atomically: true, encoding: .utf8)
            exportURL = model.sessionURL
            showExport = true
            let host = fresh.pageURL.flatMap { URL(string: $0)?.host } ?? "?"
            model.progress =
                "cookies \(accumulated.cookieCount), tokens \(accumulated.tokens.count), "
                + "storage keys \(storageKeys.count), page \(host)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Shows the captured `session.json` (plus POC diagnostics) and offers Share to move it to
/// the machine running the `food` pipeline.
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
                        ForEach(storageKeys, id: \.self) { key in
                            Text(key).font(.system(.caption, design: .monospaced))
                        }
                    }
                }
                Section("output") {
                    Text(text)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .navigationTitle("capture")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if let url { ShareLink(item: url) }
                }
            }
        }
    }
}
