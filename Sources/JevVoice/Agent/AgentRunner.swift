import AppKit
import Combine
import Foundation
import JevVoiceCore

enum AgentStepResult: Equatable {
    case ok(String)
    case failed(String)
    case pendingConfirm
}

struct AgentStep: Identifiable, Equatable {
    let id = UUID()
    let index: Int
    let tool: String
    let argsSummary: String
    var result: AgentStepResult
    var elapsed: TimeInterval
}

enum AgentOutcome: Equatable {
    case done(String)
    case failed(String)
    case cancelled
}

@MainActor
final class AgentRunner: ObservableObject {
    static let shared = AgentRunner()

    @Published private(set) var steps: [AgentStep] = []
    @Published private(set) var isRunning = false
    @Published private(set) var pendingConfirmation = false

    var confirmationHandler: (@MainActor (String) async -> Void)?

    private var task: Task<AgentOutcome, Never>?
    private var lastPID: Int?
    private var lastWindowID: Int?
    private var lastSnapshot: CuaSnapshot?
    private var targetApp: String?
    private var confirmationContinuation: CheckedContinuation<Bool, Never>?
    private var cancellationRequested = false

    private init() {}

    func run(goal: String, context: AgentContext = AgentContext()) async -> AgentOutcome {
        await run(
            goal: goal,
            context: context,
            planner: DeepSeekPlanner(apiKey: Config.shared.deepSeekAPIKey)
        )
    }

    func run(
        goal: String,
        context: AgentContext = AgentContext(),
        planner: ActionPlanner
    ) async -> AgentOutcome {
        cancel()
        steps = []
        isRunning = true
        cancellationRequested = false
        targetApp = context.frontmostApp
        Log.agent.info(
            "run start goal=\(goal, privacy: .public) targetApp=\((self.targetApp ?? "none"), privacy: .public)"
        )
        var outcomeDescription = "unknown"
        defer {
            isRunning = false
            pendingConfirmation = false
            Log.agent.info("outcome=\(outcomeDescription, privacy: .public)")
        }
        lastPID = nil
        lastWindowID = nil
        lastSnapshot = nil
        let frontmost = context.frontmostApp
            ?? NSWorkspace.shared.frontmostApplication?.localizedName
            ?? "unknown"
        var plannerContext = PlannerContext(messages: [
            DeepSeekMessage(
                role: "system",
                content: .string(AgentPrompt.system),
                name: nil,
                toolCallID: nil,
                toolCalls: nil
            ),
            DeepSeekMessage(
                role: "user",
                content: .string(
                    "Current date/time: \(ISO8601DateFormatter().string(from: Date())). " +
                    "Target app: \(frontmost). Goal: \(goal)"
                ),
                name: nil,
                toolCallID: nil,
                toolCalls: nil
            ),
        ])
        let deadline = Date().addingTimeInterval(90)
        var callCount = 0

        do {
            while Date() < deadline {
                if cancellationRequested { throw AgentError.cancelled }
                try Task.checkCancellation()
                guard callCount < 25 else { throw AgentError.budget }
                let turn = try await planner.next(plannerContext)
                plannerContext.messages.append(turn.assistant)
                guard let call = turn.toolCalls.first else {
                    throw AgentError.api("The planner did not choose an action")
                }
                callCount += 1
                let started = Date()
                var step = AgentStep(
                    index: callCount,
                    tool: call.name,
                    argsSummary: summarize(call.arguments),
                    result: .pendingConfirm,
                    elapsed: 0
                )
                steps.append(step)
                Log.agent.info(
                    "tool call index=\(callCount) tool=\(call.name, privacy: .public) args=\(self.summarize(call.arguments), privacy: .public)"
                )
                do {
                    let output = try await execute(call)
                    step.result = .ok(output.text)
                    step.elapsed = Date().timeIntervalSince(started)
                    steps[steps.count - 1] = step
                    Log.agent.info(
                        "tool result success=true first=\(String(output.text.prefix(200)), privacy: .public) elapsed=\(step.elapsed)"
                    )
                    plannerContext.messages.append(toolMessage(
                        id: call.id, content: output.content, image: output.image
                    ))
                    if call.name == "done" {
                        outcomeDescription = "done"
                        return .done(output.text)
                    }
                    if call.name == "fail" {
                        outcomeDescription = "failed"
                        return .failed(output.text)
                    }
                } catch is CancellationError {
                    throw AgentError.cancelled
                } catch {
                    step.result = .failed(error.localizedDescription)
                    step.elapsed = Date().timeIntervalSince(started)
                    steps[steps.count - 1] = step
                    Log.agent.info(
                        "tool result success=false first=\(String(error.localizedDescription.prefix(200)), privacy: .public) elapsed=\(step.elapsed)"
                    )
                    plannerContext.messages.append(toolMessage(
                        id: call.id, content: error.localizedDescription, image: nil
                    ))
                }
            }
            throw AgentError.budget
        } catch is CancellationError {
            outcomeDescription = "cancelled"
            return .cancelled
        } catch AgentError.cancelled {
            outcomeDescription = "cancelled"
            return .cancelled
        } catch {
            outcomeDescription = "failed"
            return .failed(error.localizedDescription)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        cancellationRequested = true
        if let continuation = confirmationContinuation {
            confirmationContinuation = nil
            continuation.resume(returning: false)
        }
        pendingConfirmation = false
        CuaDriver.shared.shutdown()
        isRunning = false
    }

    func clearSteps() {
        guard !isRunning else { return }
        steps = []
    }

    func resolveConfirmation(_ transcript: String) -> Bool {
        guard pendingConfirmation, let continuation = confirmationContinuation else {
            return false
        }
        let answer = transcript.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let accepted = answer.range(of: #"^(yes|yeah|yep|yup|do it|go|run|ok|okay|confirm|sure)\b"#,
                                   options: .regularExpression) != nil
        let declined = answer.range(of: #"^(no|nope|cancel|stop|dismiss|never mind|nevermind|don't)\b"#,
                                   options: .regularExpression) != nil
        guard accepted || declined else { return false }
        confirmationContinuation = nil
        pendingConfirmation = false
        continuation.resume(returning: accepted)
        return true
    }

    private func requestConfirmation(_ reason: String) async -> Bool {
        pendingConfirmation = true
        return await withCheckedContinuation { continuation in
            confirmationContinuation = continuation
            Task { @MainActor [weak self] in
                await self?.confirmationHandler?(reason)
            }
        }
    }

    private func execute(_ call: DeepSeekToolCall) async throws -> ToolOutput {
        switch call.name {
        case "observe":
            return try await observe(call.arguments)
        case "open_app":
            guard let name = call.arguments["name"]?.stringValue else {
                throw AgentError.api("open_app requires a name")
            }
            let decision = Decision(clause: "open \(name)", action: .openApp, targetApp: name)
            let text = try await Executor.execute(decision)
            targetApp = name
            return try await afterMutation(text)
        case "click":
            guard let token = call.arguments["element_token"]?.stringValue else {
                throw AgentError.api("click requires an element token")
            }
            try await confirmIfRisky(tool: "click", token: token, key: nil)
            guard let pid = lastPID else { throw AgentError.api("Observe a window first") }
            let result = try await CuaDriver.shared.click(pid: pid, token: token)
            return try await afterMutation(result.text ?? "Clicked")
        case "click_at":
            guard let pid = lastPID, let window = lastWindowID,
                  let x = number(call.arguments["x"]),
                  let y = number(call.arguments["y"]) else {
                throw AgentError.api("Observe a window before clicking coordinates")
            }
            try await confirmIfRisky(tool: "click_at", token: nil, key: nil)
            let result = try await CuaDriver.shared.click(pid: pid, windowId: window, x: x, y: y)
            return try await afterMutation(result.text ?? "Clicked")
        case "type_text":
            guard let text = call.arguments["text"]?.stringValue,
                  let pid = lastPID else { throw AgentError.api("Observe a window before typing") }
            let token = call.arguments["element_token"]?.stringValue
            try await confirmIfRisky(tool: "type_text", token: token, key: nil)
            let result = try await CuaDriver.shared.type(pid: pid, text: text, token: token)
            return try await afterMutation(result.text ?? "Typed text")
        case "press_key":
            guard let key = call.arguments["key"]?.stringValue,
                  let pid = lastPID else { throw AgentError.api("Observe a window before pressing keys") }
            let modifiers = call.arguments["modifiers"]?.arrayValue?.compactMap(\.stringValue) ?? []
            try await confirmIfRisky(tool: "press_key", token: nil, key: key)
            let result = try await CuaDriver.shared.pressKey(pid: pid, key: key, modifiers: modifiers)
            return try await afterMutation(result.text ?? "Pressed \(key)")
        case "wait":
            let seconds = min(3, max(0, number(call.arguments["seconds"]) ?? 0.5))
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return ToolOutput(text: "Waited \(seconds) seconds", content: "Waited \(seconds) seconds", image: nil)
        case "done":
            let summary = String(call.arguments["summary"]?.stringValue ?? "Task completed").prefix(200)
            return ToolOutput(text: String(summary), content: String(summary), image: nil)
        case "fail":
            let reason = String(call.arguments["reason"]?.stringValue ?? "The task could not be completed").prefix(200)
            return ToolOutput(text: String(reason), content: String(reason), image: nil)
        default:
            throw AgentError.api("Unknown agent tool: \(call.name)")
        }
    }

    private func observe(_ arguments: [String: JSONValue]) async throws -> ToolOutput {
        let apps = try await CuaDriver.shared.apps()
        let reportedApps = apps.filter { app in
            app.bundleId != Bundle.main.bundleIdentifier
        }
        let explicit = arguments["app"]?.stringValue
        if let explicit, !explicit.isEmpty {
            targetApp = explicit
        }
        var frontmost: String?
        if targetApp == nil,
           let application = NSWorkspace.shared.frontmostApplication,
           application.bundleIdentifier != Bundle.main.bundleIdentifier {
            frontmost = application.localizedName
        }
        let requested = explicit.flatMap { $0.isEmpty ? nil : $0 } ?? targetApp ?? frontmost
        let app = requested.flatMap { requested in
            reportedApps.first {
                $0.name.caseInsensitiveCompare(requested) == .orderedSame
            }
        } ?? requested.flatMap { requested in
            reportedApps.first {
                $0.name.localizedCaseInsensitiveContains(requested)
            }
        }
        guard let app else {
            let target = requested ?? "the target app"
            let reportedList = reportedApps.map(\.name).joined(separator: ", ")
            let list = reportedList.isEmpty ? "none" : reportedList
            let message = "Could not match \(target) among running apps: \(list)"
            return ToolOutput(text: message, content: message, image: nil)
        }
        targetApp = app.name
        let windows = try await CuaDriver.shared.windows(pid: app.pid)
        let preferredWindowID = app.pid == lastPID ? lastWindowID : nil
        guard let window = Self.pickWindow(windows, preferring: preferredWindowID) else {
            lastPID = app.pid
            lastWindowID = nil
            lastSnapshot = nil
            return ToolOutput(
                text: "Running apps: \(reportedApps.map(\.name).joined(separator: ", ")); \(app.name) has no window.",
                content: "Running apps: \(reportedApps.map(\.name).joined(separator: ", ")); \(app.name) has no window.",
                image: nil
            )
        }
        Log.cua.info(
            "chosen window title=\(window.title, privacy: .public) app=\(app.name, privacy: .public)"
        )
        let wantsImage = arguments["screenshot"]?.boolValue ?? false
        let includeImage = wantsImage || windows.count < 3
        let snapshot = try await CuaDriver.shared.windowState(
            pid: app.pid,
            windowId: window.id,
            includeImage: includeImage && Permission.screenRecording.isGranted
        )
        lastPID = app.pid
        lastWindowID = window.id
        lastSnapshot = snapshot
        let extra = includeImage && !Permission.screenRecording.isGranted
            ? " Screenshot unavailable: allow Screen Recording and proceed with AX only."
            : ""
        let interactiveRoles: Set<String> = [
            "AXButton", "AXLink", "AXTextField", "AXTextArea", "AXMenuItem",
            "AXTab", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXComboBox",
            "AXRow", "AXCell",
        ]
        let hasRoleData = snapshot.elements.contains { !$0.role.isEmpty }
        let treeSource: String
        if hasRoleData {
            let ordered = snapshot.elements.enumerated().sorted {
                let lhs = interactiveRoles.contains($0.element.role)
                let rhs = interactiveRoles.contains($1.element.role)
                return lhs != rhs ? lhs : $0.offset < $1.offset
            }.map { _, element in
                let value = element.value.map { " value=\($0)" } ?? ""
                return "[\(element.token)] \(element.role) \(element.label)\(value)"
            }.joined(separator: "\n")
            treeSource = ordered
        } else {
            treeSource = snapshot.treeMarkdown
        }
        let tree = String(treeSource.prefix(14000))
        let shownLines = tree.split(separator: "\n").count
        let omitted = max(0, snapshot.elements.count - shownLines)
        let text = "Running apps: \(reportedApps.map(\.name).joined(separator: ", ")); " +
            "frontmost window: \(window.title). Elements: \(snapshot.elements.count).\n" +
            "\(tree)\(omitted > 0 ? "\n… \(omitted) more" : "")\(extra)"
        return ToolOutput(text: text, content: text, image: snapshot.image)
    }

    static func pickWindow(_ windows: [CuaWindow], preferring lastWindowID: Int?) -> CuaWindow? {
        if let lastWindowID,
           let previous = windows.first(where: { $0.id == lastWindowID }) {
            return previous
        }
        guard let qualifying = windows.first(where: { window in
            guard let frame = window.frame else { return false }
            return (frame["width"] ?? 0) >= 200
                && (frame["height"] ?? 0) >= 150
                && !window.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            return windows.first
        }
        return qualifying
    }

    private func afterMutation(_ text: String) async throws -> ToolOutput {
        let observation = try await observe([:])
        return ToolOutput(
            text: "\(text). Window title now observed; \(lastSnapshot?.elements.count ?? 0) elements.",
            content: "\(text). Window title now observed; \(lastSnapshot?.elements.count ?? 0) elements.\n\(observation.text)",
            image: observation.image
        )
    }

    private func confirmIfRisky(tool: String, token: String?, key: String?) async throws {
        guard isRisky(token: token, key: key) else { return }
        let reason = "This \(tool) may be destructive"
        steps[steps.count - 1].result = .pendingConfirm
        pendingConfirmation = true
        let allowed = await requestConfirmation(reason)
        pendingConfirmation = false
        guard allowed else {
            throw AgentError.api("user declined; choose another approach or fail")
        }
    }

    private func isRisky(token: String?, key: String?) -> Bool {
        let label = token.flatMap { lastSnapshot?.element(token: $0)?.label }?.lowercased() ?? ""
        if AgentRisk.matchesDestructiveWord(label) { return true }
        guard let key = key?.lowercased(), key == "return" || key == "enter" else { return false }
        let latestLabel = (lastSnapshot?.elements.last?.label ?? "").lowercased()
        return AgentRisk.matchesDestructiveWord(latestLabel)
    }

    private func number(_ value: JSONValue?) -> Double? {
        if case .number(let number) = value { return number }
        if case .string(let string) = value { return Double(string) }
        return nil
    }

    private func summarize(_ args: [String: JSONValue]) -> String {
        args.map { key, value in
            let text = value.stringValue ?? "\(value)"
            return "\(key)=\(String(text.prefix(40)))"
        }.sorted().joined(separator: ", ")
    }

    private func toolMessage(id: String, content: String, image: Data?) -> DeepSeekMessage {
        var value: JSONValue = .string(content)
        if let image {
            value = .array([
                .object(["type": .string("text"), "text": .string(content)]),
                .object([
                    "type": .string("image_url"),
                    "image_url": .object([
                        "url": .string("data:image/png;base64,\(image.base64EncodedString())"),
                        "detail": .string("low"),
                    ]),
                ]),
            ])
        }
        return DeepSeekMessage(role: "tool", content: value, name: nil, toolCallID: id, toolCalls: nil)
    }
}

struct AgentContext {
    var frontmostApp: String?
    init(frontmostApp: String? = nil) {
        self.frontmostApp = frontmostApp
    }
}

struct ToolOutput {
    let text: String
    let content: String
    let image: Data?
}
