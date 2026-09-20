import Foundation

struct PlannerStepRecord: Equatable {
    let tool: String
    let argsSummary: String
    let resultText: String
    let succeeded: Bool
    let elementRole: String?
    let elementLabel: String?

    init(
        tool: String,
        argsSummary: String,
        resultText: String,
        succeeded: Bool,
        elementRole: String? = nil,
        elementLabel: String? = nil
    ) {
        self.tool = tool
        self.argsSummary = argsSummary
        self.resultText = resultText
        self.succeeded = succeeded
        self.elementRole = elementRole
        self.elementLabel = elementLabel
    }
}

struct PlannerContext {
    var messages: [DeepSeekMessage]
    var goal: String = ""
    var targetApp: String? = nil
    var siteHost: String? = nil
    var windowTitle: String? = nil
    var previousWindowTitle: String? = nil
    var generatedText: String? = nil
    var snapshot: CuaSnapshot? = nil
    var typedTextVisible: Bool? = nil
    var excludedLabels: Set<String> = []
    var history: [PlannerStepRecord] = []
    var stepIndex: Int = 0

    init(
        messages: [DeepSeekMessage] = [],
        goal: String = "",
        targetApp: String? = nil,
        siteHost: String? = nil,
        windowTitle: String? = nil,
        previousWindowTitle: String? = nil,
        generatedText: String? = nil,
        snapshot: CuaSnapshot? = nil,
        typedTextVisible: Bool? = nil,
        excludedLabels: Set<String> = [],
        history: [PlannerStepRecord] = [],
        stepIndex: Int = 0
    ) {
        self.messages = messages
        self.goal = goal
        self.targetApp = targetApp
        self.siteHost = siteHost
        self.windowTitle = windowTitle
        self.previousWindowTitle = previousWindowTitle
        self.generatedText = generatedText
        self.snapshot = snapshot
        self.typedTextVisible = typedTextVisible
        self.excludedLabels = excludedLabels
        self.history = history
        self.stepIndex = stepIndex
    }
}

enum PlannerEscalation: Equatable {
    case none
    case toDeepSeek(reason: String)
}

struct PlannerTurn {
    let assistant: DeepSeekMessage
    let toolCalls: [DeepSeekToolCall]
    var escalation: PlannerEscalation = .none
}

struct DeepSeekToolCall {
    let id: String
    let name: String
    let arguments: [String: JSONValue]
}

struct DeepSeekMessage {
    let role: String
    let content: JSONValue?
    let name: String?
    let toolCallID: String?
    let toolCalls: [DeepSeekToolCall]?
    let reasoningContent: String?

    init(
        role: String,
        content: JSONValue?,
        name: String?,
        toolCallID: String?,
        toolCalls: [DeepSeekToolCall]?,
        reasoningContent: String? = nil
    ) {
        self.role = role
        self.content = content
        self.name = name
        self.toolCallID = toolCallID
        self.toolCalls = toolCalls
        self.reasoningContent = reasoningContent
    }

    func jsonValue() -> JSONValue {
        var object: [String: JSONValue] = ["role": .string(role)]
        if let content { object["content"] = content }
        if let reasoningContent {
            object["reasoning_content"] = .string(reasoningContent)
        }
        if let name { object["name"] = .string(name) }
        if let toolCallID { object["tool_call_id"] = .string(toolCallID) }
        if let toolCalls {
            object["tool_calls"] = .array(toolCalls.map { call in
                .object([
                    "id": .string(call.id),
                    "type": .string("function"),
                    "function": .object([
                        "name": .string(call.name),
                        "arguments": .string(Self.encodeArguments(call.arguments)),
                    ]),
                ])
            })
        }
        return .object(object)
    }

    private static func encodeArguments(_ arguments: [String: JSONValue]) -> String {
        guard let data = try? JSONEncoder().encode(JSONValue.object(arguments)) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }
}

@MainActor
final class DeepSeekPlanner: ActionPlanner {
    private let apiKey: String
    private let session: URLSession

    private let thinking: DeepSeekThinking

    init(
        apiKey: String,
        thinking: DeepSeekThinking = .off,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.thinking = thinking
        self.session = session
    }

    func next(_ context: PlannerContext) async throws -> PlannerTurn {
        guard let url = URL(string: "https://api.deepseek.com/chat/completions") else {
            throw AgentError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var messages = context.messages
        if let generatedText = context.generatedText {
            messages.append(DeepSeekMessage(
                role: "system",
                content: .string("The text to type is provided verbatim: \(generatedText). Do not rewrite it."),
                name: nil,
                toolCallID: nil,
                toolCalls: nil
            ))
        }
        let body = Self.body(messages: messages, thinking: thinking)
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(decoding: data.prefix(300), as: UTF8.self)
            Log.agent.info(
                "DeepSeek HTTP status=\(status) errorBody=\(body, privacy: .public)"
            )
            throw AgentError.api("DeepSeek returned HTTP \(status)")
        }
        return try Self.decodeTurn(data: data)
    }

    static func decodeTurn(data: Data) throws -> PlannerTurn {
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let message = value["choices"]?.arrayValue?.first?["message"]?.objectValue else {
            throw AgentError.invalidResponse
        }
        let calls = (message["tool_calls"]?.arrayValue ?? []).compactMap { value -> DeepSeekToolCall? in
            guard let object = value.objectValue,
                  let id = object["id"]?.stringValue,
                  let function = object["function"]?.objectValue,
                  let name = function["name"]?.stringValue,
                  let arguments = function["arguments"]?.stringValue,
                  let argumentData = arguments.data(using: .utf8),
                  let parsed = try? JSONDecoder().decode(JSONValue.self, from: argumentData),
                  let parsedObject = parsed.objectValue else { return nil }
            return DeepSeekToolCall(id: id, name: name, arguments: parsedObject)
        }
        let content = message["content"]
        let reasoningContent = message["reasoning_content"]?.stringValue
        let assistant = DeepSeekMessage(
            role: "assistant",
            content: content,
            name: nil,
            toolCallID: nil,
            toolCalls: calls.isEmpty ? nil : calls,
            reasoningContent: reasoningContent
        )
        return PlannerTurn(assistant: assistant, toolCalls: calls)
    }

    static func body(messages: [DeepSeekMessage], thinking: DeepSeekThinking) -> JSONValue {
        var object: [String: JSONValue] = [
            "model": .string("deepseek-flash"),
            "messages": .array(messages.map { $0.jsonValue() }),
            "tools": .array(Self.tools),
            "tool_choice": .string("auto"),
            "stream": .bool(false),
            "thinking": .object([
                "type": .string(thinking == .off ? "disabled" : "enabled"),
            ]),
        ]
        if thinking != .off {
            object["reasoning_effort"] = .string(thinking == .low ? "low" : "high")
        }
        return .object(object)
    }

    static let tools: [JSONValue] = [
        function("observe", "Observe running apps and the target window. Set screenshot=true when you need a screenshot.", [
            "app": property(.string("string"), description: "Optional app name."),
            "screenshot": property(.string("boolean"), description: "Request a screenshot."),
        ]),
        function("open_app", "Launch an installed app.", [
            "name": property(.string("string"), description: "Installed app name."),
        ], required: ["name"]),
        function("click", "Click a current observation element.", [
            "element_token": property(.string("string"), description: "Latest observation token."),
        ], required: ["element_token"]),
        function("click_at", "Click window-local screenshot coordinates.", [
            "x": property(.string("number"), description: "Window-local x."),
            "y": property(.string("number"), description: "Window-local y."),
        ], required: ["x", "y"]),
        function("type_text", "Type text into the current target.", [
            "text": property(.string("string"), description: "Text to type."),
            "element_token": property(.string("string"), description: "Optional latest token."),
        ], required: ["text"]),
        function("press_key", "Press one key in the current target.", [
            "key": property(.string("string"), description: "Key name."),
            "modifiers": property(.string("array"), description: "Modifier names."),
        ], required: ["key"]),
        function("wait", "Wait briefly for the UI to settle.", [
            "seconds": property(.string("number"), description: "Seconds, at most 3."),
        ], required: ["seconds"]),
        function("done", "Finish with one short spoken sentence.", [
            "summary": property(.string("string"), description: "Past-tense spoken summary."),
        ], required: ["summary"]),
        function("fail", "Stop when the goal cannot be completed.", [
            "reason": property(.string("string"), description: "One-sentence reason."),
        ], required: ["reason"]),
    ]

    private static func property(
        _ type: JSONValue, description: String
    ) -> JSONValue {
        .object(["type": type, "description": .string(description)])
    }

    private static func function(
        _ name: String,
        _ description: String,
        _ properties: [String: JSONValue],
        required: [String] = []
    ) -> JSONValue {
        .object([
            "type": .string("function"),
            "function": .object([
                "name": .string(name),
                "description": .string(description),
                "parameters": .object([
                    "type": .string("object"),
                    "properties": .object(properties),
                    "required": .array(required.map(JSONValue.string)),
                    "additionalProperties": .bool(false),
                ]),
            ]),
        ])
    }
}

protocol ActionPlanner {
    func next(_ ctx: PlannerContext) async throws -> PlannerTurn
}

@MainActor
final class CascadePlanner: ActionPlanner {
    private let jev: ActionPlanner
    private let deepSeek: ActionPlanner?
    private var usingDeepSeek = false

    init(jev: ActionPlanner, deepSeek: ActionPlanner?) {
        self.jev = jev
        self.deepSeek = deepSeek
    }

    func next(_ ctx: PlannerContext) async throws -> PlannerTurn {
        if usingDeepSeek {
            guard let deepSeek else {
                assertionFailure("Jev escalation requires a DeepSeek planner")
                throw AgentError.api("DeepSeek fallback is unavailable")
            }
            return try await deepSeek.next(ctx)
        }
        let turn = try await jev.next(ctx)
        if case .toDeepSeek(let reason) = turn.escalation {
            Log.agent.info("escalate to deepseek reason=\(reason, privacy: .public)")
            usingDeepSeek = true
            guard let deepSeek else {
                assertionFailure("Jev escalation requires a DeepSeek planner")
                throw AgentError.api("DeepSeek fallback is unavailable")
            }
            return try await deepSeek.next(ctx)
        }
        return turn
    }
}

enum AgentError: Error, LocalizedError {
    case api(String)
    case invalidResponse
    case budget
    case cancelled

    var errorDescription: String? {
        switch self {
        case .api(let message): return message
        case .invalidResponse: return "DeepSeek returned an invalid response"
        case .budget: return "Ran out of steps"
        case .cancelled: return "Cancelled"
        }
    }
}
