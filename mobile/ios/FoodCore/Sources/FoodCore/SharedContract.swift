import Foundation

public enum SharedContractError: Error, CustomStringConvertible {
    case missing(String)
    public var description: String {
        switch self {
        case .missing(let name): return "missing shared resource: \(name)"
        }
    }
}

public struct JevContract: Decodable, Sendable {
    public let dayCriteria: [String: String]
    public let storageCriteria: [String: String]

    enum CodingKeys: String, CodingKey {
        case dayCriteria = "day_criteria"
        case storageCriteria = "storage_criteria"
    }
}

public struct SharedConfig: Decodable, Sendable {
    public let classifyWorkers: Int
    public let resolveWorkers: Int
    public let llmTimeoutS: Double
    public let llmMaxTokens: Int
    public let llmMaxConnections: Int
    public let jevEnabled: Bool
    public let jevBaseURL: String
    public let jevModel: String
    public let jevTimeoutS: Double

    enum CodingKeys: String, CodingKey {
        case classifyWorkers = "classify_workers"
        case resolveWorkers = "resolve_workers"
        case llmTimeoutS = "llm_timeout_s"
        case llmMaxTokens = "llm_max_tokens"
        case llmMaxConnections = "llm_max_connections"
        case jevEnabled = "jev_enabled"
        case jevBaseURL = "jev_base_url"
        case jevModel = "jev_model"
        case jevTimeoutS = "jev_timeout_s"
    }

    public static let fallback = SharedConfig(
        classifyWorkers: 6, resolveWorkers: 4, llmTimeoutS: 120,
        llmMaxTokens: 8192, llmMaxConnections: 8, jevEnabled: true,
        jevBaseURL: "https://api.commandcode.ai/provider",
        jevModel: "typesafe/jev-1.14.0", jevTimeoutS: 8
    )
}

public enum SharedContract {
    private static func data(_ name: String, ext: String, subdirectory: String? = nil) -> Data? {
        // `.process("Resources")` flattens the resources into the bundle root. A bundle
        // with a top-level `Resources` directory is rejected by codesign on device builds.
        Bundle.module
            .url(forResource: name, withExtension: ext, subdirectory: subdirectory)
            .flatMap { try? Data(contentsOf: $0) }
    }

    public static let prompts: [String: String] = {
        guard let data = data("prompts", ext: "json"),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return decoded
    }()

    public static let jev: JevContract = {
        guard let data = data("jev", ext: "json"),
              let decoded = try? JSONDecoder().decode(JevContract.self, from: data)
        else {
            return JevContract(dayCriteria: [:], storageCriteria: [:])
        }
        return decoded
    }()

    public static let config: SharedConfig = {
        guard let data = data("config", ext: "json"),
              let decoded = try? JSONDecoder().decode(SharedConfig.self, from: data)
        else { return .fallback }
        return decoded
    }()

    public static func schemaSQL() throws -> String {
        guard let data = data("schema", ext: "sql"),
              let sql = String(data: data, encoding: .utf8)
        else { throw SharedContractError.missing("schema.sql") }
        return sql
    }

    public static let costcoQuery: String = {
        guard let data = data("costco", ext: "graphql"),
              let text = String(data: data, encoding: .utf8)
        else { return "" }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }()

    public static func fixtureData(_ name: String) -> Data? {
        data(name, ext: "json")
    }
}
