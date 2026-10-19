import Foundation
import FoodCore

/// Provider settings, persisted in UserDefaults. Defaults come from the environment (so a
/// simulator launch can inject keys); anything saved in Settings overrides them.
enum Settings {
    private static let apiKeyKey = "cmdApiKey"
    private static let baseURLKey = "baseURL"
    private static let modelKey = "model"
    private static let embedKeyKey = "openrouterKey"
    private static let embedModelKey = "embedModel"

    static func providerConfig() -> ProviderConfig {
        var config = ProviderConfig.fromEnvironment()
        let defaults = UserDefaults.standard
        if let v = defaults.string(forKey: apiKeyKey), !v.isEmpty { config.apiKey = v }
        if let v = defaults.string(forKey: baseURLKey), !v.isEmpty { config.baseURL = v }
        if let v = defaults.string(forKey: modelKey), !v.isEmpty {
            config.models = [v] + Array(config.models.dropFirst())
        }
        if let v = defaults.string(forKey: embedKeyKey), !v.isEmpty { config.embedAPIKey = v }
        if let v = defaults.string(forKey: embedModelKey), !v.isEmpty { config.embedModel = v }
        return config
    }

    static var apiKey: String { UserDefaults.standard.string(forKey: apiKeyKey) ?? "" }
    static var baseURL: String { UserDefaults.standard.string(forKey: baseURLKey) ?? "" }
    static var model: String { UserDefaults.standard.string(forKey: modelKey) ?? "" }
    static var embedKey: String { UserDefaults.standard.string(forKey: embedKeyKey) ?? "" }
    static var embedModel: String { UserDefaults.standard.string(forKey: embedModelKey) ?? "" }

    static func save(apiKey: String, baseURL: String, model: String, embedKey: String, embedModel: String) {
        let d = UserDefaults.standard
        d.set(apiKey, forKey: apiKeyKey)
        d.set(baseURL, forKey: baseURLKey)
        d.set(model, forKey: modelKey)
        d.set(embedKey, forKey: embedKeyKey)
        d.set(embedModel, forKey: embedModelKey)
    }
}
