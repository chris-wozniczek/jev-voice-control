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
    private var lastWindowTitle: String?
    private var lastCDPTitle: String?
    private var lastCDPPort: Int?
    private var targetApp: String?
    private var confirmationContinuation: CheckedContinuation<Bool, Never>?
    private var cancellationRequested = false

    var hintStore: HintStore = .shared
    var currentWindowTitle: String? { lastWindowTitle }

    private init() {}

    func run(goal: String, context: AgentContext = AgentContext()) async -> AgentOutcome {
        let config = Config.shared
        switch config.plannerMode {
        case .jev:
            guard !config.apiKey.isEmpty else {
                return .failed("Add a TypeSafe API key in Settings")
            }
            let jev = JevStepPlanner(
                client: JevClient(apiKey: config.apiKey),
                canEscalate: !config.deepSeekAPIKey.isEmpty
            )
            let deepSeek = config.deepSeekAPIKey.isEmpty
                ? nil
                : DeepSeekPlanner(
                    apiKey: config.deepSeekAPIKey,
                    thinking: config.deepSeekThinking
                )
            return await run(
                goal: goal,
                context: context,
                planner: CascadePlanner(jev: jev, deepSeek: deepSeek)
            )
        case .deepSeek:
            guard !config.deepSeekAPIKey.isEmpty else {
                return .failed("Add a DeepSeek API key in Settings")
            }
            return await run(
                goal: goal,
                context: context,
                planner: DeepSeekPlanner(
                    apiKey: config.deepSeekAPIKey,
                    thinking: config.deepSeekThinking
                )
            )
        }
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
        lastWindowTitle = nil
        lastCDPTitle = nil
        lastCDPPort = nil
        var successfulHints: [(app: String, role: String, label: String)] = []
        let frontmost = context.frontmostApp
            ?? NSWorkspace.shared.frontmostApplication?.localizedName
            ?? "unknown"
        var plannerContext = PlannerContext(
            messages: [
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
            ],
            goal: goal,
            targetApp: targetApp,
            windowTitle: nil,
            generatedText: context.generatedText,
            snapshot: nil,
            history: [],
            stepIndex: 0
        )
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
                let elementBeforeMutation: CuaElement? = {
                    guard ["click", "type_text"].contains(call.name),
                          let token = call.arguments["element_token"]?.stringValue else {
                        return nil
                    }
                    return lastSnapshot?.element(token: token)
                }()
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
                    plannerContext.snapshot = lastSnapshot
                    plannerContext.windowTitle = lastWindowTitle
                    plannerContext.targetApp = targetApp
                    plannerContext.history.append(PlannerStepRecord(
                        tool: call.name,
                        argsSummary: step.argsSummary,
                        resultText: output.text,
                        succeeded: true,
                        elementRole: elementBeforeMutation?.role,
                        elementLabel: elementBeforeMutation?.label
                    ))
                    if call.name == "click" || call.name == "type_text",
                       let app = targetApp,
                       let role = elementBeforeMutation?.role,
                       let label = elementBeforeMutation?.label,
                       !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        successfulHints.append((app: app, role: role, label: label))
                    }
                    plannerContext.stepIndex = callCount
                    if call.name == "done" {
                        for hint in successfulHints {
                            hintStore.record(
                                app: hint.app,
                                goal: goal,
                                role: hint.role,
                                label: hint.label
                            )
                        }
                        hintStore.save()
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
                    plannerContext.snapshot = lastSnapshot
                    plannerContext.windowTitle = lastWindowTitle
                    plannerContext.targetApp = targetApp
                    plannerContext.history.append(PlannerStepRecord(
                        tool: call.name,
                        argsSummary: step.argsSummary,
                        resultText: error.localizedDescription,
                        succeeded: false,
                        elementRole: elementBeforeMutation?.role,
                        elementLabel: elementBeforeMutation?.label
                    ))
                    plannerContext.stepIndex = callCount
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

    func setSnapshotForTesting(_ snapshot: CuaSnapshot?) {
        lastSnapshot = snapshot
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
            if token.hasPrefix("cdp:") {
                guard let title = lastCDPTitle, let port = lastCDPPort else {
                    throw AgentError.api("Observe a Chrome page first")
                }
                try await CDPBridge.shared.click(port: port, windowTitle: title, token: token)
                return try await afterMutation("Clicked")
            }
            guard let pid = lastPID else { throw AgentError.api("Observe a window first") }
            let result = try await CuaDriver.shared.click(pid: pid, token: token)
            return try await afterMutation(result.text ?? "Clicked")
        case "click_at":
            guard let pid = lastPID, let window = lastWindowID,
                  let x = number(call.arguments["x"]),
                  let y = number(call.arguments["y"]) else {
                throw AgentError.api("Observe a window before clicking coordinates")
            }
            guard Permission.screenRecording.isGranted else {
                throw AgentError.api(
                    "Screen Recording is not allowed, so coordinate clicks are unavailable — allow it in System Settings › Privacy & Security"
                )
            }
            try await confirmIfRisky(tool: "click_at", token: nil, key: nil)
            let result = try await CuaDriver.shared.click(pid: pid, windowId: window, x: x, y: y)
            return try await afterMutation(result.text ?? "Clicked")
        case "type_text":
            guard let text = call.arguments["text"]?.stringValue else {
                throw AgentError.api("type_text requires text")
            }
            let token = call.arguments["element_token"]?.stringValue
            try await confirmIfRisky(tool: "type_text", token: token, key: nil)
            if let token, token.hasPrefix("cdp:") {
                guard let title = lastCDPTitle, let port = lastCDPPort else {
                    throw AgentError.api("Observe a Chrome page first")
                }
                try await CDPBridge.shared.type(
                    port: port,
                    windowTitle: title,
                    token: token,
                    text: text
                )
                return try await afterMutation("Typed text")
            }
            guard let pid = lastPID else { throw AgentError.api("Observe a window before typing") }
            let result = try await CuaDriver.shared.type(
                pid: pid,
                text: text,
                token: token,
                windowId: token == nil ? lastWindowID : nil
            )
            return try await afterMutation(result.text ?? "Typed text")
        case "press_key":
            guard let key = call.arguments["key"]?.stringValue,
                  let pid = lastPID,
                  let window = lastWindowID else {
                throw AgentError.api("Observe a window before pressing keys")
            }
            let modifiers = call.arguments["modifiers"]?.arrayValue?.compactMap(\.stringValue) ?? []
            try await confirmIfRisky(tool: "press_key", token: nil, key: key)
            let result = try await CuaDriver.shared.pressKey(
                pid: pid,
                key: key,
                modifiers: modifiers,
                windowId: window
            )
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
        let focusedFrame = AXWindowLocator.focusedWindowFrame(pid: pid_t(app.pid))
        let candidates = Self.rankWindows(
            windows,
            preferring: preferredWindowID,
            focusedFrame: focusedFrame
        ).prefix(3)
        guard let firstCandidate = candidates.first else {
            lastPID = app.pid
            lastWindowID = nil
            lastSnapshot = nil
            return ToolOutput(
                text: "Running apps: \(reportedApps.map(\.name).joined(separator: ", ")); \(app.name) has no window.",
                content: "Running apps: \(reportedApps.map(\.name).joined(separator: ", ")); \(app.name) has no window.",
                image: nil
            )
        }
        let wantsImage = arguments["screenshot"]?.boolValue ?? false
        let includeImage = wantsImage || windows.count < 3
        let interactiveRoles: Set<String> = [
            "AXButton", "AXLink", "AXTextField", "AXTextArea", "AXMenuItem",
            "AXTab", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXComboBox",
            "AXRow", "AXCell",
        ]
        var firstSnapshot: CuaSnapshot?
        var firstSnapshotWindow: CuaWindow?
        var firstError: Error?
        var chosenWindow: CuaWindow?
        var snapshot: CuaSnapshot?
        for candidate in candidates {
            do {
                let candidateSnapshot = try await CuaDriver.shared.windowState(
                    pid: app.pid,
                    windowId: candidate.id,
                    includeImage: includeImage && Permission.screenRecording.isGranted
                )
                let interactive = candidateSnapshot.elements.contains {
                    interactiveRoles.contains($0.role)
                }
                Log.cua.info(
                    "window candidate id=\(candidate.id) title=\(candidate.title, privacy: .public) elements=\(candidateSnapshot.elements.count) interactive=\(interactive)"
                )
                if firstSnapshot == nil {
                    firstSnapshot = candidateSnapshot
                    firstSnapshotWindow = candidate
                }
                if interactive {
                    chosenWindow = candidate
                    snapshot = candidateSnapshot
                    break
                }
            } catch {
                if firstSnapshot == nil { firstError = error }
                Log.cua.info(
                    "window candidate id=\(candidate.id) title=\(candidate.title, privacy: .public) elements=0 interactive=false error=\(error.localizedDescription, privacy: .public)"
                )
            }
        }
        let window = chosenWindow ?? firstSnapshotWindow ?? firstCandidate
        guard let snapshot = snapshot ?? firstSnapshot else {
            throw firstError ?? CuaDriverError.malformedResponse
        }
        Log.cua.info(
            "chosen window title=\(window.title, privacy: .public) app=\(app.name, privacy: .public)"
        )
        lastCDPTitle = nil
        lastCDPPort = nil
        var mergedSnapshot = snapshot
        let cdpInteractiveRoles: Set<String> = [
            "AXButton", "AXLink", "AXTextField", "AXTextArea", "AXMenuItem",
            "AXTab", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXComboBox",
            "AXRow", "AXCell",
        ]
        if Config.shared.cdpEnabled,
           Self.shouldTryCDP(
               bundleId: app.bundleId,
               interactiveCount: snapshot.elements.filter {
                   cdpInteractiveRoles.contains($0.role)
               }.count
           ),
           await CDPBridge.shared.isAvailable(port: Config.shared.cdpPort),
           let cdpElements = try? await CDPBridge.shared.elements(
               port: Config.shared.cdpPort,
               windowTitle: window.title
           ),
           !cdpElements.isEmpty {
            mergedSnapshot = CuaSnapshot(
                snapshotId: snapshot.snapshotId,
                treeMarkdown: snapshot.treeMarkdown,
                elements: snapshot.elements + cdpElements,
                image: snapshot.image
            )
            lastCDPTitle = window.title
            lastCDPPort = Config.shared.cdpPort
            Log.cua.info(
                "cdp merged elements=\(cdpElements.count) title=\(window.title, privacy: .public)"
            )
        }
        lastPID = app.pid
        lastWindowID = window.id
        lastWindowTitle = window.title
        lastSnapshot = mergedSnapshot
        let extra = includeImage && !Permission.screenRecording.isGranted
            ? " Screenshot unavailable: allow Screen Recording and proceed with AX only."
            : ""
        let hasRoleData = mergedSnapshot.elements.contains { !$0.role.isEmpty }
        let treeSource: String
        if hasRoleData {
            let ordered = mergedSnapshot.elements.enumerated().sorted {
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
        let omitted = max(0, mergedSnapshot.elements.count - shownLines)
        let text = "Running apps: \(reportedApps.map(\.name).joined(separator: ", ")); " +
            "frontmost window: \(window.title). Elements: \(mergedSnapshot.elements.count).\n" +
            "\(tree)\(omitted > 0 ? "\n… \(omitted) more" : "")\(extra)"
        return ToolOutput(text: text, content: text, image: snapshot.image)
    }

    static func shouldTryCDP(bundleId: String?, interactiveCount: Int) -> Bool {
        bundleId?.hasPrefix("com.google.Chrome") == true || interactiveCount < 3
    }

    static func rankWindows(
        _ windows: [CuaWindow],
        preferring lastWindowID: Int?,
        focusedFrame: CGRect?
    ) -> [CuaWindow] {
        var ranked: [CuaWindow] = []
        var seen = Set<Int>()
        func append(_ candidates: [CuaWindow]) {
            for candidate in candidates where seen.insert(candidate.id).inserted {
                ranked.append(candidate)
            }
        }

        if let lastWindowID {
            append(windows.filter { $0.id == lastWindowID })
        }
        if let focusedFrame {
            append(windows.filter { window in
                guard let frame = window.frame else { return false }
                return abs((frame["x"] ?? 0) - focusedFrame.origin.x) <= 4
                    && abs((frame["y"] ?? 0) - focusedFrame.origin.y) <= 4
                    && abs((frame["width"] ?? 0) - focusedFrame.size.width) <= 4
                    && abs((frame["height"] ?? 0) - focusedFrame.size.height) <= 4
            })
        }
        let qualifying = windows.filter { window in
            guard let frame = window.frame else { return false }
            return (frame["width"] ?? 0) >= 200
                && (frame["height"] ?? 0) >= 150
        }
        append(qualifying.filter {
            !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })
        append(qualifying.filter {
            $0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })
        append(windows)
        return ranked
    }

    static func pickWindow(_ windows: [CuaWindow], preferring lastWindowID: Int?) -> CuaWindow? {
        rankWindows(windows, preferring: lastWindowID, focusedFrame: nil).first
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

    func isRisky(token: String?, key: String?) -> Bool {
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
    var generatedText: String?

    init(frontmostApp: String? = nil, generatedText: String? = nil) {
        self.frontmostApp = frontmostApp
        self.generatedText = generatedText
    }
}

struct ToolOutput {
    let text: String
    let content: String
    let image: Data?
}
