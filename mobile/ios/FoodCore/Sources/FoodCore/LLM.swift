import Foundation

/// The LLM seam. Concrete access lives in `MacPawProvider` (MacPaw/OpenAI); this file holds
/// only the config, the protocol, and the small shared value types, so the pipeline depends on
/// the interface rather than any client.

public struct ProviderConfig: Sendable {
    public var baseURL: String
    public var apiKey: String
    public var models: [String]
    public var temperature: Double
    public var embedBaseURL: String
    public var embedModel: String
    public var embedAPIKey: String

    public init(
        baseURL: String = "https://api.commandcode.ai/provider/v1",
        apiKey: String = "",
        models: [String] = ["xiaomi/mimo-v2.6-flash"],
        temperature: Double = 0.0,
        embedBaseURL: String = "https://openrouter.ai/api/v1",
        embedModel: String = "baai/bge-base-en-v1.5",
        embedAPIKey: String = ""
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.models = models
        self.temperature = temperature
        self.embedBaseURL = embedBaseURL
        self.embedModel = embedModel
        self.embedAPIKey = embedAPIKey
    }

    public var embeddingsConfigured: Bool { !embedAPIKey.isEmpty }

    /// Mirrors `food/config.py`'s env names. Optionally reads a `.env` file first (real env wins,
    /// like python-dotenv).
    public static func fromEnvironment(envFile: URL? = nil) -> ProviderConfig {
        var env = ProcessInfo.processInfo.environment
        if let envFile = envFile, let text = try? String(contentsOf: envFile, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { continue }
                let key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
                let value = String(trimmed[trimmed.index(after: eq)...])
                    .trimmingCharacters(in: .whitespaces)
                if env[key] == nil { env[key] = value }
            }
        }
        let fallbacks = (env["FOOD_FALLBACK_MODELS"] ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return ProviderConfig(
            baseURL: env["FOOD_BASE_URL"] ?? "https://api.commandcode.ai/provider/v1",
            apiKey: env["CMD_API_KEY"] ?? "",
            models: [env["FOOD_MODEL"] ?? "xiaomi/mimo-v2.6-flash"] + fallbacks,
            embedBaseURL: env["FOOD_EMBED_BASE_URL"] ?? "https://openrouter.ai/api/v1",
            embedModel: env["FOOD_EMBED_MODEL"] ?? "baai/bge-base-en-v1.5",
            embedAPIKey: env["OPENROUTER_API_KEY"] ?? ""
        )
    }
}

public enum LLMError: Error, CustomStringConvertible {
    case notConfigured(String)
    case allModelsFailed([String], String)
    case badResponse(String)

    public var description: String {
        switch self {
        case .notConfigured(let m): return m
        case .allModelsFailed(let models, let detail): return "all models failed (\(models)): \(detail)"
        case .badResponse(let m): return "bad response: \(m)"
        }
    }
}

public struct ChatResponse {
    public let json: [String: Any]
    public let model: String
}

/// One tool call the model asked for (function name + JSON arguments).
public struct ToolCall {
    public let id: String
    public let name: String
    public let arguments: String
}

/// A raw completion: either assistant text, or tool calls to run, or both.
public struct ChatCompletion {
    public let content: String?
    public let toolCalls: [ToolCall]
    public let model: String
}

public protocol LLMProvider {
    func chatJSON(system: String, user: String, temperature: Double) async throws -> ChatResponse
    func embed(_ texts: [String]) async throws -> [[Float]]
    func chat(messages: [[String: Any]], tools: [[String: Any]]?, temperature: Double) async throws -> ChatCompletion
    func chatText(system: String, user: String, temperature: Double) async throws -> String
}

public extension LLMProvider {
    // Defaults keep the plain (non-agent) test doubles small.
    func chat(messages: [[String: Any]], tools: [[String: Any]]?, temperature: Double) async throws -> ChatCompletion {
        throw LLMError.notConfigured("this provider does not support tool-calling chat")
    }

    func chatText(system: String, user: String, temperature: Double) async throws -> String {
        let response = try await chatJSON(system: system, user: user, temperature: temperature)
        return (response.json["text"] as? String) ?? ""
    }
}

/// Pull the first JSON object out of free-form model text (ported from `llm.extract_json`) —
/// free models wrap JSON in prose or fences.
public enum JSONExtract {
    public static func extract(_ text: String) throws -> [String: Any] {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            let parts = t.components(separatedBy: "```")
            if parts.count >= 2 { t = parts[1] }
            if t.hasPrefix("json") { t.removeFirst(4) }
        }
        guard let start = t.firstIndex(of: "{"), let end = t.lastIndex(of: "}"), start < end else {
            throw LLMError.badResponse("no JSON object found in: \(text.prefix(200))")
        }
        let slice = Data(t[start...end].utf8)
        guard let obj = try JSONSerialization.jsonObject(with: slice) as? [String: Any] else {
            throw LLMError.badResponse("JSON was not an object")
        }
        return obj
    }
}
