import Foundation

/// Minimal client for the TypeSafe System One endpoint exposed by Command Code.
///
/// This is intentionally separate from `LLMProvider`: Jev is not a chat model. The resolver
/// runs research first, then asks Jev for the terminal typed verdicts.
public protocol JevProvider: Sendable {
    func decide(state: [String: Any], questions: [String: Any]) async throws -> JevResponse
}

public struct JevUsage: Decodable, Sendable {
    public let inputTokens: Int?
    public let outputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
    }
}

public struct JevAnswer: Decodable, Sendable {
    public let type: String
    public let noul: Double?
    public let choice: String?
    public let confidence: Double?
    public let probabilities: [String: Double]?
    public let score: Double?
}

public struct JevResponse: Decodable, Sendable {
    public let model: String
    public let answers: [String: JevAnswer]
    public let usage: JevUsage?
    public let requestID: String?

    enum CodingKeys: String, CodingKey {
        case model
        case answers
        case usage
        case requestID = "request_id"
    }
}

public struct JevError: Error, CustomStringConvertible, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

public struct JevClient: JevProvider {
    private let config: ProviderConfig

    public init(config: ProviderConfig) {
        self.config = config
    }

    public func decide(
        state: [String: Any], questions: [String: Any]
    ) async throws -> JevResponse {
        guard config.jevEnabled else {
            throw JevError("Jev is disabled")
        }
        guard !config.apiKey.isEmpty else {
            throw JevError("CMD_API_KEY is not set")
        }
        guard let root = URL(string: config.jevBaseURL) else {
            throw JevError("invalid Jev base URL: \(config.jevBaseURL)")
        }
        let url = root.appendingPathComponent("v1").appendingPathComponent("systemone")
        let body: [String: Any] = [
            "model": config.jevModel,
            "state": state,
            "questions": questions,
        ]
        guard JSONSerialization.isValidJSONObject(body) else {
            throw JevError("Jev request is not valid JSON")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = config.jevTimeout
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw JevError("Jev returned a non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(decoding: data, as: UTF8.self).prefix(300)
            if http.statusCode == 429 {
                let retry = http.value(forHTTPHeaderField: "retry-after") ?? "?"
                throw JevError("Jev rate limited (retry-after=\(retry))")
            }
            throw JevError("Jev HTTP \(http.statusCode): \(text)")
        }
        return try JSONDecoder().decode(JevResponse.self, from: data)
    }
}
