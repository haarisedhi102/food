import Foundation
import RigPocKit

/// `LLMProvider` and `JevProvider` backed by the Rig/Rust wrapper. Rig owns transport,
/// auth, timeouts, message conversion, embeddings, and Jev; Swift keeps all domain behavior.
public final class RigProvider: LLMProvider, JevProvider {
    public let config: ProviderConfig
    private let configJSON: String

    public init(config: ProviderConfig) {
        self.config = config
        let data = (try? JSONEncoder().encode(config)) ?? Data()
        self.configJSON = String(decoding: data, as: UTF8.self)
    }

    // MARK: - LLMProvider

    public func chatJSON(system: String, user: String, temperature: Double) async throws -> ChatResponse {
        let result = try await chatJsonConfigured(
            configJson: configJSON, system: system, user: user, temperature: temperature
        )
        print("[llm] model=\(result.model) chars=\(result.text.count)")
        return ChatResponse(json: try JSONExtract.extract(result.text), model: result.model)
    }

    public func chatText(system: String, user: String, temperature: Double) async throws -> String {
        let result = try await chatTextConfigured(
            configJson: configJSON, system: system, user: user, temperature: temperature
        )
        return result.text
    }

    public func chat(
        messages: [[String: Any]], tools: [[String: Any]]?, temperature: Double, forceTool: String?
    ) async throws -> ChatCompletion {
        let result = try await chatWithToolsConfigured(
            configJson: configJSON,
            messagesJson: try serialize(messages),
            toolsJson: try tools.map(serialize) ?? "[]",
            forceTool: forceTool,
            temperature: temperature
        )
        return ChatCompletion(
            content: result.content,
            toolCalls: result.toolCalls.map {
                ToolCall(id: $0.id, name: $0.name, arguments: $0.arguments)
            },
            model: result.model
        )
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        return try await embedConfigured(configJson: configJSON, texts: texts)
    }

    // MARK: - JevProvider

    public func decide(
        state: [String: Any], questions: [String: Any]
    ) async throws -> JevResponse {
        let result = try await jevDynamicConfigured(
            configJson: configJSON,
            stateJson: try serialize(state),
            questionsJson: try serialize(questions)
        )
        let answers = try JSONDecoder().decode(
            [String: JevAnswer].self, from: Data(result.answersJson.utf8)
        )
        let usage: JevUsage? = result.inputTokens == nil && result.outputTokens == nil
            ? nil
            : JevUsage(
                inputTokens: result.inputTokens.map(Int.init),
                outputTokens: result.outputTokens.map(Int.init)
            )
        return JevResponse(
            model: result.model, answers: answers, usage: usage, requestID: result.requestId
        )
    }

    // MARK: - Helpers

    private func serialize(_ object: Any) throws -> String {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw LLMError.badResponse("request is not valid JSON")
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }
}
