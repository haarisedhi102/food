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

    public init(inputTokens: Int?, outputTokens: Int?) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }

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

    public init(
        model: String,
        answers: [String: JevAnswer],
        usage: JevUsage?,
        requestID: String?
    ) {
        self.model = model
        self.answers = answers
        self.usage = usage
        self.requestID = requestID
    }

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
