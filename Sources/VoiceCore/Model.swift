import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The model, for other apps (POST /api/model/chat): Super Face asks it which expression and
/// gesture go with each sentence. It's the model AI Listen talks with (Tom's), so there's one
/// model on the Mac for everything, and only Super Voice talks to Ollama.
public protocol ModelAccess: AnyObject {
    /// The model that answers ("" when there's none yet), and where Ollama is.
    var modelName: String { get }
    /// One answer, not streamed: `format` is Ollama's (a JSON schema, or "json"), nil for text.
    func chat(messages: [[String: Any]], format: Any?, temperature: Double?, think: Bool) async throws -> String
}

/// The model through Ollama, read fresh each time (the user can pick another while it serves).
public final class OllamaModelAccess: ModelAccess {
    private let current: () -> (url: String, model: String)

    public init(current: @escaping () -> (url: String, model: String)) {
        self.current = current
    }

    public var modelName: String { current().model }

    public func chat(messages: [[String: Any]], format: Any?, temperature: Double?, think: Bool) async throws -> String {
        let (url, chosen) = current()
        let client = OllamaClient(baseURL: url)
        // None picked yet (AI Listen hasn't run): the first Ollama has, as AI Listen would take.
        var model = chosen
        if model.isEmpty { model = try await client.models().first ?? "" }
        guard !model.isEmpty else { throw AssistantError.noModel }
        return try await client.structured(model: model, messages: messages, format: format, temperature: temperature, think: think)
    }
}

extension OllamaClient {
    /// The request body for one structured answer: the format kept to, thinking off unless asked.
    public static func structuredBody(model: String, messages: [[String: Any]], format: Any?, temperature: Double?,
                                      think: Bool, sendThink: Bool = true) -> [String: Any] {
        var body: [String: Any] = ["model": model, "messages": messages, "stream": false, "keep_alive": "30m"]
        var options: [String: Any] = ["num_ctx": contextTokens]
        if let temperature { options["temperature"] = temperature }
        body["options"] = options
        if let format { body["format"] = format }
        if sendThink { body["think"] = OllamaClient.think(model: model, on: think) }
        return body
    }

    /// One answer to `messages` in `format`, any thinking taken out.
    public func structured(model: String, messages: [[String: Any]], format: Any?, temperature: Double?, think: Bool) async throws -> String {
        let data: Data
        do {
            data = try await postJSON("/api/chat", Self.structuredBody(model: model, messages: messages, format: format,
                                                                         temperature: temperature, think: think))
        } catch AssistantError.server(let status, let message) where status == 400 && message.lowercased().contains("think") {
            data = try await postJSON("/api/chat", Self.structuredBody(model: model, messages: messages, format: format,
                                                                         temperature: temperature, think: think, sendThink: false))
        }
        return try Self.answer(data).text
    }
}
