import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var app: AppModel
    @State private var apiKey = Settings.apiKey
    @State private var baseURL = Settings.baseURL
    @State private var model = Settings.model
    @State private var embedKey = Settings.embedKey
    @State private var embedModel = Settings.embedModel
    @State private var saved = false
    @State private var showingSync = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case apiKey, baseURL, model, embedKey, embedModel
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        showingSync = true
                    } label: {
                        Label("Sync receipts", systemImage: "tray.and.arrow.down")
                    }
                    if app.repairCount > 0 {
                        Button {
                            Task { await app.retryPending() }
                        } label: {
                            Label(
                                "Retry pending items (\(app.repairCount))",
                                systemImage: "arrow.clockwise"
                            )
                        }
                        .disabled(app.isBusy)
                    }
                } footer: {
                    Text("Log into Kroger or Costco in the in-app browser, fetch your receipts, "
                        + "and rebuild your fridge on this device. Retry re-runs items left "
                        + "pending or named from their receipt text.")
                }

                Section("Provider") {
                    SecureField("API key (CMD_API_KEY)", text: $apiKey)
                        .focused($focusedField, equals: .apiKey)
                    TextField("Base URL", text: $baseURL)
                        .focused($focusedField, equals: .baseURL)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                        .autocorrectionDisabled()
                    TextField("Model", text: $model)
                        .focused($focusedField, equals: .model)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit { focusedField = nil }
                }
                Section("Embeddings (optional)") {
                    SecureField("OpenRouter key", text: $embedKey)
                        .focused($focusedField, equals: .embedKey)
                    TextField("Embedding model", text: $embedModel)
                        .focused($focusedField, equals: .embedModel)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit { focusedField = nil }
                }
                #if DEBUG
                Section {
                    Button("Reset kitchen data", role: .destructive) {
                        app.resetKitchenData()
                    }
                } header: {
                    Text("Debug")
                } footer: {
                    Text("Clears receipts, products and inventory in this simulator.")
                }
                #endif
                Section {
                    if let logURL = AppLog.url {
                        ShareLink(item: logURL) {
                            Label("Export logs", systemImage: "square.and.arrow.up")
                        }
                    }
                } header: {
                    Text("Diagnostics")
                } footer: {
                    Text("App/OS version, provider configuration (keys redacted) and recent run "
                        + "output, including Rust transport errors.")
                }
                Section {
                    Button("Save") {
                        Settings.save(
                            apiKey: apiKey, baseURL: baseURL, model: model,
                            embedKey: embedKey, embedModel: embedModel
                        )
                        saved = true
                    }
                    if saved {
                        Text("Saved").font(.caption).foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Leave a field blank to use the built-in default. Stored in UserDefaults.")
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .keyboardDismissOnTap()
            .safeAreaInset(edge: .top, spacing: 0) {
                SyncStatusBanner(
                    stage: app.isBusy ? app.syncStatus : "",
                    toast: app.syncToast,
                    toastFailed: app.syncToastFailed
                )
                .animation(.snappy, value: app.isBusy)
                .animation(.snappy, value: app.syncToast)
            }
            .navigationTitle("Settings")
            #if os(iOS)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedField = nil }
                }
            }
            #endif
            .sheet(isPresented: $showingSync) {
                SyncSheet()
            }
        }
    }
}
