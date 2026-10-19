import Foundation
import OpenAI

/// `LLMProvider` backed by MacPaw/OpenAI, so we don't maintain the HTTP/JSON plumbing, tool
/// calling or embeddings. Keeps the `LLMProvider` seam, so the pipeline is unchanged.
///
/// Two clients: chat goes to the Command Code provider (`/provider/v1`), embeddings to
/// OpenRouter — MacPaw supports a custom `basePath`, which is what makes the provider mount work.
public final class MacPawProvider: LLMProvider {
    public let config: ProviderConfig
    private let chatClient: OpenAI
    private let embedClient: OpenAI?

    public init(config: ProviderConfig) {
        self.config = config
        self.chatClient = MacPawProvider.client(baseURL: config.baseURL, key: config.apiKey)
        self.embedClient = config.embeddingsConfigured
            ? MacPawProvider.client(baseURL: config.embedBaseURL, key: config.embedAPIKey)
            : nil
    }

    static func client(baseURL: String, key: String) -> OpenAI {
        let url = URL(string: baseURL) ?? URL(string: "https://api.openai.com/v1")!
        var basePath = url.path
        if basePath.isEmpty || basePath == "/" { basePath = "/v1" }
        let configuration = OpenAI.Configuration(
            token: key,
            host: url.host ?? "api.openai.com",
            port: url.port ?? (url.scheme == "http" ? 80 : 443),
            scheme: url.scheme ?? "https",
            basePath: basePath,
            parsingOptions: .relaxed
        )
        return OpenAI(configuration: configuration)
    }

    private var primaryModel: String { config.models.first ?? "" }

    // MARK: - LLMProvider

    public func chatJSON(system: String, user: String, temperature: Double) async throws -> ChatResponse {
        let query = ChatQuery(
            messages: [.system(.init(content: .textContent(system))), .user(.init(content: .string(user)))],
            model: primaryModel,
            temperature: temperature
        )
        let result = try await chatClient.chats(query: query)
        let content = result.choices.first?.message.content ?? ""
        return ChatResponse(json: try JSONExtract.extract(content), model: result.model)
    }

    public func chatText(system: String, user: String, temperature: Double) async throws -> String {
        let query = ChatQuery(
            messages: [.system(.init(content: .textContent(system))), .user(.init(content: .string(user)))],
            model: primaryModel,
            temperature: temperature
        )
        return try await chatClient.chats(query: query).choices.first?.message.content ?? ""
    }

    public func chat(
        messages: [[String: Any]], tools: [[String: Any]]?, temperature: Double
    ) async throws -> ChatCompletion {
        let params = try messages.map(MacPawProvider.messageParam)
        let toolParams = try tools?.map(MacPawProvider.toolParam)
        let query = ChatQuery(
            messages: params,
            model: primaryModel,
            temperature: temperature,
            tools: toolParams
        )
        let result = try await chatClient.chats(query: query)
        guard let message = result.choices.first?.message else {
            return ChatCompletion(content: nil, toolCalls: [], model: result.model)
        }
        let calls = (message.toolCalls ?? []).map {
            ToolCall(id: $0.id, name: $0.function.name, arguments: $0.function.arguments)
        }
        return ChatCompletion(content: message.content, toolCalls: calls, model: result.model)
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        guard let client = embedClient else {
            throw LLMError.notConfigured("OPENROUTER_API_KEY is not set — embeddings are disabled.")
        }
        guard !texts.isEmpty else { return [] }
        let result = try await client.embeddings(
            query: EmbeddingsQuery(input: .stringList(texts), model: config.embedModel)
        )
        return result.data.map { $0.embedding.map(Float.init) }
    }

    // MARK: - OpenAI-shaped dicts -> MacPaw types

    static func messageParam(_ m: [String: Any]) throws -> ChatQuery.ChatCompletionMessageParam {
        let role = m["role"] as? String ?? "user"
        let content = m["content"] as? String ?? ""
        switch role {
        case "system":
            return .system(.init(content: .textContent(content)))
        case "assistant":
            if let raw = m["tool_calls"] as? [[String: Any]] {
                let calls = raw.compactMap { tc -> ChatQuery.ChatCompletionMessageParam.AssistantMessageParam.ToolCallParam? in
                    guard let fn = tc["function"] as? [String: Any], let name = fn["name"] as? String else { return nil }
                    return .init(
                        id: tc["id"] as? String ?? "",
                        function: .init(arguments: fn["arguments"] as? String ?? "{}", name: name)
                    )
                }
                return .assistant(.init(content: .textContent(content), toolCalls: calls))
            }
            return .assistant(.init(content: .textContent(content)))
        case "tool":
            return .tool(.init(content: .textContent(content), toolCallId: m["tool_call_id"] as? String ?? ""))
        default:
            return .user(.init(content: .string(content)))
        }
    }

    static func toolParam(_ t: [String: Any]) throws -> ChatQuery.ChatCompletionToolParam {
        guard let fn = t["function"] as? [String: Any], let name = fn["name"] as? String else {
            throw LLMError.badResponse("tool definition missing function.name")
        }
        var schema: JSONSchema?
        if let params = fn["parameters"] {
            let data = try JSONSerialization.data(withJSONObject: params)
            schema = try JSONDecoder().decode(JSONSchema.self, from: data)
        }
        return ChatQuery.ChatCompletionToolParam(
            function: .init(name: name, description: fn["description"] as? String, parameters: schema)
        )
    }
}
