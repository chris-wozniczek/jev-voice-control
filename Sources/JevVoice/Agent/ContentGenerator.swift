import Foundation
import JevVoiceCore

struct ComposeContext {
    var app: String?
    var windowTitle: String?
    var maxCharacters: Int = 600
}

protocol ContentGenerating {
    func compose(brief: String, context: ComposeContext) async throws -> String
}

struct OpenAICompatibleGenerator: ContentGenerating {
    let endpoint: URL
    let apiKey: String?
    let model: String
    let thinking: DeepSeekThinking?
    let session: URLSession

    init(
        endpoint: URL,
        apiKey: String?,
        model: String,
        thinking: DeepSeekThinking? = nil,
        session: URLSession = .shared
    ) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.model = model
        self.thinking = thinking
        self.session = session
    }

    func compose(brief: String, context: ComposeContext) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.allHTTPHeaderFields = Self.requestHeaders(apiKey: apiKey)
        request.httpBody = try JSONEncoder().encode(
            Self.body(
                brief: brief,
                context: context,
                model: model,
                endpoint: endpoint,
                thinking: thinking
            )
        )
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw AgentError.api("Text generator returned HTTP \(status)")
        }
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let reply = value["choices"]?.arrayValue?.first?["message"]?["content"]?.stringValue else {
            throw AgentError.invalidResponse
        }
        let cleaned = Self.clean(reply, max: context.maxCharacters)
        guard !cleaned.isEmpty else {
            throw AgentError.api("Couldn't compose that")
        }
        Log.agent.info("compose len=\(cleaned.count) model=\(self.model, privacy: .public)")
        return cleaned
    }

    static func body(
        brief: String,
        context: ComposeContext,
        model: String,
        endpoint: URL,
        thinking: DeepSeekThinking?
    ) -> JSONValue {
        let system = "You write short text that will be typed on the user's behalf. Output only the text to type — no quotes, no preamble, no markdown, no sign-off placeholders. Plain, natural, ≤ \(context.maxCharacters) characters. Language: same as the request."
        var user = brief
        if let app = context.app, !app.isEmpty {
            user += "\nApp: \(app)"
        }
        if let windowTitle = context.windowTitle, !windowTitle.isEmpty {
            user += "\nWindow: \(windowTitle)"
        }
        var object: [String: JSONValue] = [
            "model": .string(model),
            "messages": .array([
                .object(["role": .string("system"), "content": .string(system)]),
                .object(["role": .string("user"), "content": .string(user)]),
            ]),
            "stream": .bool(false),
        ]
        if endpoint.host?.caseInsensitiveCompare("api.deepseek.com") == .orderedSame {
            object["thinking"] = .object(["type": .string("disabled")])
        }
        return .object(object)
    }

    static func requestHeaders(apiKey: String?) -> [String: String] {
        var headers = ["Content-Type": "application/json"]
        if let apiKey, !apiKey.isEmpty {
            headers["Authorization"] = "Bearer \(apiKey)"
        }
        return headers
    }

    static func clean(_ reply: String, max: Int) -> String {
        var cleaned = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.count >= 2 {
            let pairs: [(Character, Character)] = [("\"", "\""), ("'", "'"), ("“", "”")]
            if pairs.contains(where: {
                cleaned.first == $0.0 && cleaned.last == $0.1
            }) {
                cleaned.removeFirst()
                cleaned.removeLast()
                cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        guard max > 0, cleaned.count > max else { return cleaned }
        let prefix = String(cleaned.prefix(max))
        if let boundary = prefix.lastIndex(where: { ".!?".contains($0) }) {
            return String(prefix[...boundary]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return prefix.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
