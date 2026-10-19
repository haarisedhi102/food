import SwiftUI

struct SettingsView: View {
    @State private var apiKey = Settings.apiKey
    @State private var baseURL = Settings.baseURL
    @State private var model = Settings.model
    @State private var embedKey = Settings.embedKey
    @State private var embedModel = Settings.embedModel
    @State private var saved = false
    @State private var showingSync = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        showingSync = true
                    } label: {
                        Label("Sync receipts", systemImage: "tray.and.arrow.down")
                    }
                } footer: {
                    Text("Log into Kroger or Costco in the in-app browser, fetch your receipts, "
                        + "and rebuild your fridge on this device.")
                }

                Section("Provider") {
                    SecureField("API key (CMD_API_KEY)", text: $apiKey)
                    TextField("Base URL", text: $baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("Model", text: $model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("Embeddings (optional)") {
                    SecureField("OpenRouter key", text: $embedKey)
                    TextField("Embedding model", text: $embedModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
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
            .navigationTitle("Settings")
            .sheet(isPresented: $showingSync) {
                SyncSheet()
            }
        }
    }
}
