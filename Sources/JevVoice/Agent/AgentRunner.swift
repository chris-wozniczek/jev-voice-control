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
    private var lastApp: CuaApp?
    private var lastWindowID: Int?
    private var lastWindowFrame: CGRect?
    private var lastSnapshot: CuaSnapshot?
    private var lastAXEntries: [String: AXEntry] = [:]
    private var lastOCRPoints: [String: CGPoint] = [:]
    private var lastWindowTitle: String?
    private var lastCDPTitle: String?
    private var lastCDPPort: Int?
    private var targetApp: String?
    private var currentGoal = ""
    private var confirmationContinuation: CheckedContinuation<Bool, Never>?
    private var cancellationRequested = false
    private var cachedApps: [CuaApp]?
    private var idleShutdownTask: Task<Void, Never>?
    private var plannerSeconds = 0.0
    private var cuaSeconds = 0.0

    var hintStore: HintStore = .shared
    var appsProvider: (() async throws -> [CuaApp])?
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
        cancelActiveRun()
        idleShutdownTask?.cancel()
        steps = []
        isRunning = true
        cancellationRequested = false
        cachedApps = nil
        lastApp = nil
        plannerSeconds = 0
        cuaSeconds = 0
        let runStarted = Date()
        targetApp = context.frontmostApp
        currentGoal = goal
        Log.agent.info(
            "run start goal=\(goal, privacy: .public) targetApp=\((self.targetApp ?? "none"), privacy: .public)"
        )
        var outcomeDescription = "unknown"
        defer {
            isRunning = false
            pendingConfirmation = false
            let total = Date().timeIntervalSince(runStarted)
            Log.agent.info(
                "run totals total=\(total) planner=\(self.plannerSeconds) cua=\(self.cuaSeconds) steps=\(self.steps.count)"
            )
            Log.agent.info("outcome=\(outcomeDescription, privacy: .public)")
            idleShutdownTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(90))
                guard let self, !self.isRunning else { return }
                CuaDriver.shared.shutdown()
            }
        }
        lastPID = nil
        lastApp = nil
        lastWindowID = nil
        lastWindowFrame = nil
        storeSnapshot(nil)
        lastWindowTitle = nil
        lastCDPTitle = nil
        lastCDPPort = nil
        var effectivePlanner = planner
        if Config.shared.appActionsEnabled,
           let action = AppActionRegistry.shared.match(
               goal: goal,
               appName: targetApp,
               bundleId: nil,
               windowTitle: lastWindowTitle,
               url: nil
           ) {
            effectivePlanner = FastPathPlanner(action: action, inner: planner)
            Log.agent.info(
                "fastpath matched action=\(action.name, privacy: .public) app=\(action.app, privacy: .public)"
            )
        }
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
            siteHost: context.siteHost,
            windowTitle: nil,
            generatedText: context.generatedText,
            snapshot: nil,
            history: [],
            stepIndex: 0
        )
        let deadline = Date().addingTimeInterval(90)
        var callCount = 0
        var previousWindowTitle: String?
        var siteShortcutIssued = false

        do {
            while Date() < deadline {
                if cancellationRequested { throw AgentError.cancelled }
                try Task.checkCancellation()
                guard callCount < 25 else { throw AgentError.budget }
                let turn = try await plannerNext(effectivePlanner, context: plannerContext)
                plannerContext.messages.append(turn.assistant)
                guard let call = turn.toolCalls.first else {
                    throw AgentError.api("The planner did not choose an action")
                }
                callCount += 1
                let started = Date()
                let windowTitleBeforeMutation = lastWindowTitle
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
                    if ["click", "click_at", "type_text", "press_key", "open_app"].contains(call.name) {
                        previousWindowTitle = windowTitleBeforeMutation
                    }
                    plannerContext.previousWindowTitle = previousWindowTitle
                    plannerContext.targetApp = targetApp
                    plannerContext.typedTextVisible = typedTextVisible(
                        goal: goal,
                        snapshot: lastSnapshot
                    )
                    plannerContext.history.append(PlannerStepRecord(
                        tool: call.name,
                        argsSummary: step.argsSummary,
                        resultText: output.text,
                        succeeded: true,
                        elementRole: elementBeforeMutation?.role,
                        elementLabel: elementBeforeMutation?.label
                    ))
                    if call.name == "observe",
                       !siteShortcutIssued,
                       context.siteHost != nil,
                       context.generatedText != nil,
                       !(lastSnapshot?.elements.contains {
                           KeyboardFocus.textRoles.contains($0.role)
                       } ?? false),
                       let action = AppActionRegistry.shared.actions.first(where: {
                           $0.site?.caseInsensitiveCompare(context.siteHost ?? "") == .orderedSame
                               && $0.name.caseInsensitiveCompare("compose post") == .orderedSame
                       }),
                       case .key(let key, let modifiers) = action.steps.first {
                        siteShortcutIssued = true
                        let shortcut = DeepSeekToolCall(
                            id: "site-shortcut-\(callCount)",
                            name: "press_key",
                            arguments: [
                                "key": .string(key),
                                "modifiers": .array(modifiers.map(JSONValue.string)),
                            ]
                        )
                        let shortcutOutput = try await execute(shortcut)
                        plannerContext.messages.append(toolMessage(
                            id: shortcut.id,
                            content: shortcutOutput.content,
                            image: shortcutOutput.image
                        ))
                        plannerContext.history.append(PlannerStepRecord(
                            tool: shortcut.name,
                            argsSummary: summarize(shortcut.arguments),
                            resultText: shortcutOutput.text,
                            succeeded: true
                        ))
                        continue
                    }
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
                    plannerContext.previousWindowTitle = previousWindowTitle
                    plannerContext.targetApp = targetApp
                    plannerContext.typedTextVisible = typedTextVisible(
                        goal: goal,
                        snapshot: lastSnapshot
                    )
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

    private func cancelActiveRun() {
        task?.cancel()
        task = nil
        cancellationRequested = true
        if let continuation = confirmationContinuation {
            confirmationContinuation = nil
            continuation.resume(returning: false)
        }
        pendingConfirmation = false
    }

    func cancel() {
        cancelActiveRun()
        CuaDriver.shared.shutdown()
        isRunning = false
    }

    func clearSteps() {
        guard !isRunning else { return }
        steps = []
    }

    func setSnapshotForTesting(_ snapshot: CuaSnapshot?) {
        storeSnapshot(snapshot)
    }

    func setAXEntriesForTesting(_ entries: [String: AXEntry]) {
        lastAXEntries = entries
    }

    func setOCRPointsForTesting(_ points: [String: CGPoint]) {
        lastOCRPoints = points
    }

    func executeForTesting(_ call: DeepSeekToolCall) async throws -> ToolOutput {
        try await execute(call)
    }

    func apps(forceRefresh: Bool = false) async throws -> [CuaApp] {
        if !forceRefresh, let cachedApps {
            return cachedApps
        }
        let started = Date()
        let fetched: [CuaApp]
        if let appsProvider {
            fetched = try await appsProvider()
        } else {
            fetched = try await CuaDriver.shared.apps()
        }
        cachedApps = fetched
        let elapsed = Date().timeIntervalSince(started)
        cuaSeconds += elapsed
        Log.agent.info("stage=apps elapsed=\(elapsed)")
        return fetched
    }

    func setAppsProviderForTesting(_ provider: (() async throws -> [CuaApp])?) {
        appsProvider = provider
        cachedApps = nil
    }

    private func plannerNext(
        _ planner: ActionPlanner,
        context: PlannerContext
    ) async throws -> PlannerTurn {
        let started = Date()
        defer {
            let elapsed = Date().timeIntervalSince(started)
            plannerSeconds += elapsed
            Log.agent.info("stage=planner elapsed=\(elapsed)")
        }
        return try await planner.next(context)
    }

    private func measureCua<T>(_ operation: () async throws -> T) async throws -> T {
        let started = Date()
        defer {
            let elapsed = Date().timeIntervalSince(started)
            cuaSeconds += elapsed
            Log.agent.info("stage=action elapsed=\(elapsed)")
        }
        return try await operation()
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
            cachedApps = nil
            lastApp = nil
            lastPID = nil
            lastWindowID = nil
            lastWindowFrame = nil
            storeSnapshot(nil)
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
            if token.hasPrefix("ax:") {
                guard let entry = lastAXEntries[token] else {
                    throw AgentError.api("Observe the window again — that element is stale")
                }
                do {
                    try AXTreeReader.press(entry)
                } catch {
                    guard let frame = entry.frame else { throw error }
                    if let pid = lastPID {
                        NSRunningApplication(processIdentifier: pid_t(pid))?.activate()
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    CGEventClicker.click(at: CGPoint(
                        x: frame.midX,
                        y: frame.midY
                    ))
                }
                return try await afterMutation("Clicked \(entry.label)")
            }
            if token.hasPrefix("ocr:") {
                guard let point = lastOCRPoints[token],
                      let pid = lastPID else {
                    throw AgentError.api("Observe the window again — that element is stale")
                }
                NSRunningApplication(processIdentifier: pid_t(pid))?.activate()
                try await Task.sleep(for: .milliseconds(100))
                CGEventClicker.click(at: point)
                return try await afterMutation("Clicked \(lastSnapshot?.element(token: token)?.label ?? "text")")
            }
            guard let pid = lastPID else { throw AgentError.api("Observe a window first") }
            do {
                let result = try await measureCua {
                    try await CuaDriver.shared.click(pid: pid, token: token)
                }
                return try await afterMutation(result.text ?? "Clicked")
            } catch {
                guard Self.shouldRetryAfterActivate(error) else { throw error }
                NSRunningApplication(processIdentifier: pid_t(pid))?.activate()
                try await Task.sleep(for: .milliseconds(200))
                Log.agent.info("click retry after activate pid=\(pid)")
                let result = try await measureCua {
                    try await CuaDriver.shared.click(pid: pid, token: token)
                }
                return try await afterMutation(result.text ?? "Clicked")
            }
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
            let result = try await measureCua {
                try await CuaDriver.shared.click(pid: pid, windowId: window, x: x, y: y)
            }
            return try await afterMutation(result.text ?? "Clicked")
        case "type_text":
            guard let text = call.arguments["text"]?.stringValue else {
                throw AgentError.api("type_text requires text")
            }
            let token = call.arguments["element_token"]?.stringValue
            guard let pid = lastPID else { throw AgentError.api("Observe a window before typing") }
            guard await KeyboardFocus.bringToFront(pid: pid_t(pid)) else {
                throw AgentError.api(
                    "Couldn't bring \(targetApp ?? lastApp?.name ?? "the app") to the front to type"
                )
            }
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
                let result = verifiedTypingResult(pid: pid, text: text, fallback: "Typed text")
                return try await afterMutation(result)
            }
            if let token, token.hasPrefix("ocr:") {
                guard let point = lastOCRPoints[token] else {
                    throw AgentError.api("Observe the window again — that element is stale")
                }
                NSRunningApplication(processIdentifier: pid_t(pid))?.activate()
                try await Task.sleep(for: .milliseconds(100))
                CGEventClicker.click(at: point)
                try await Task.sleep(for: .milliseconds(100))
                let result = try await measureCua {
                    try await CuaDriver.shared.type(
                        pid: pid,
                        text: text,
                        token: nil,
                        windowId: lastWindowID
                    )
                }
                return try await afterMutation(
                    verifiedTypingResult(pid: pid, text: text, fallback: result.text ?? "Typed text")
                )
            }
            if let token, token.hasPrefix("ax:") {
                guard let entry = lastAXEntries[token] else {
                    throw AgentError.api("Observe the window again — that element is stale")
                }
                do {
                    try AXTreeReader.focus(entry)
                } catch {
                    Log.agent.info("AX focus failed; typing into current focus error=\(error.localizedDescription, privacy: .public)")
                }
                let result = try await measureCua {
                    try await CuaDriver.shared.type(
                        pid: pid,
                        text: text,
                        token: nil,
                        windowId: lastWindowID
                    )
                }
                return try await afterMutation(
                    verifiedTypingResult(pid: pid, text: text, fallback: result.text ?? "Typed text")
                )
            }
            if token == nil {
                try await focusTextElementIfNeeded(pid: pid)
            }
            let result = try await measureCua {
                try await CuaDriver.shared.type(
                    pid: pid,
                    text: text,
                    token: token,
                    windowId: token == nil ? lastWindowID : nil
                )
            }
            return try await afterMutation(
                verifiedTypingResult(pid: pid, text: text, fallback: result.text ?? "Typed text")
            )
        case "press_key":
            guard let key = call.arguments["key"]?.stringValue,
                  let pid = lastPID,
                  let window = lastWindowID else {
                throw AgentError.api("Observe a window before pressing keys")
            }
            let modifiers = call.arguments["modifiers"]?.arrayValue?.compactMap(\.stringValue) ?? []
            guard await KeyboardFocus.bringToFront(pid: pid_t(pid)) else {
                throw AgentError.api(
                    "Couldn't bring \(targetApp ?? lastApp?.name ?? "the app") to the front to press keys"
                )
            }
            try await confirmIfRisky(tool: "press_key", token: nil, key: key)
            let viaMenu = call.arguments["via_menu"]?.boolValue == true
            if viaMenu || modifiers.contains(where: {
                $0.caseInsensitiveCompare("command") == .orderedSame
            }) {
                if AXMenuBar.pressMenuItem(
                    pid: pid_t(pid),
                    key: key,
                    modifiers: modifiers
                ) {
                    return try await afterMutation("Pressed \(key)")
                }
            }
            let result = try await measureCua {
                try await CuaDriver.shared.pressKey(
                    pid: pid,
                    key: key,
                    modifiers: modifiers,
                    windowId: window
                )
            }
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
        var runningApps = try await apps()
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
        func match(_ apps: [CuaApp]) -> CuaApp? {
            let reportedApps = apps.filter { $0.bundleId != Bundle.main.bundleIdentifier }
            return requested.flatMap { requested in
                reportedApps.first {
                $0.name.caseInsensitiveCompare(requested) == .orderedSame
                }
            } ?? requested.flatMap { requested in
                reportedApps.first {
                    $0.name.localizedCaseInsensitiveContains(requested)
                }
            }
        }
        var app = match(runningApps)
        if app == nil, requested != nil {
            runningApps = try await apps(forceRefresh: true)
            app = match(runningApps)
        }
        let reportedApps = runningApps.filter { $0.bundleId != Bundle.main.bundleIdentifier }
        guard let app else {
            let target = requested ?? "the target app"
            let reportedList = reportedApps.map(\.name).joined(separator: ", ")
            let list = reportedList.isEmpty ? "none" : reportedList
            let message = "Could not match \(target) among running apps: \(list)"
            return ToolOutput(text: message, content: message, image: nil)
        }
        targetApp = app.name
        let windowsStarted = Date()
        let windows = try await CuaDriver.shared.windows(pid: app.pid)
        let windowsElapsed = Date().timeIntervalSince(windowsStarted)
        cuaSeconds += windowsElapsed
        Log.agent.info("stage=windows elapsed=\(windowsElapsed)")
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
            lastWindowFrame = nil
            storeSnapshot(nil)
            return ToolOutput(
                text: "Running apps: \(reportedApps.map(\.name).joined(separator: ", ")); \(app.name) has no window.",
                content: "Running apps: \(reportedApps.map(\.name).joined(separator: ", ")); \(app.name) has no window.",
                image: nil
            )
        }
        let wantsImage = arguments["screenshot"]?.boolValue ?? false
        var firstSnapshot: CuaSnapshot?
        var firstEntries: [String: AXEntry] = [:]
        var firstSnapshotWindow: CuaWindow?
        var firstError: Error?
        var chosenWindow: CuaWindow?
        var snapshot: CuaSnapshot?
        var chosenEntries: [String: AXEntry] = [:]
        for candidate in candidates {
            do {
                var candidateSnapshot: CuaSnapshot
                var candidateEntries: [String: AXEntry] = [:]
                let treeStarted = Date()
                let candidateFrame = Self.cgRect(candidate.frame)
                let nativeSnapshot = Config.shared.nativeAXEnabled
                    ? await Task.detached(priority: .userInitiated) {
                        AXTreeReader.snapshot(
                            pid: app.pid,
                            windowFrame: candidateFrame
                        )
                    }.value
                    : nil
                if let ax = nativeSnapshot {
                    let axElapsed = Date().timeIntervalSince(treeStarted)
                    Log.agent.info(
                        "stage=axtree elements=\(ax.snapshot.elements.count) interactive=\(ax.snapshot.elements.filter { AXTreeReader.interactiveRoles.contains($0.role) }.count) elapsed=\(axElapsed)"
                    )
                    candidateSnapshot = ax.snapshot
                    candidateEntries = ax.entries
                    if wantsImage && Permission.screenRecording.isGranted {
                        let imageStarted = Date()
                        let imageSnapshot = try await CuaDriver.shared.windowState(
                            pid: app.pid,
                            windowId: candidate.id,
                            includeImage: true
                        )
                        cuaSeconds += Date().timeIntervalSince(imageStarted)
                        Log.agent.info("stage=tree elapsed=\(Date().timeIntervalSince(imageStarted))")
                        candidateSnapshot = CuaSnapshot(
                            snapshotId: candidateSnapshot.snapshotId,
                            treeMarkdown: candidateSnapshot.treeMarkdown,
                            elements: candidateSnapshot.elements,
                            image: imageSnapshot.image
                        )
                    }
                } else {
                    let treeStarted = Date()
                    candidateSnapshot = try await CuaDriver.shared.windowState(
                        pid: app.pid,
                        windowId: candidate.id,
                        includeImage: wantsImage && Permission.screenRecording.isGranted
                    )
                    let treeElapsed = Date().timeIntervalSince(treeStarted)
                    cuaSeconds += treeElapsed
                    Log.agent.info("stage=tree elapsed=\(treeElapsed)")
                }
                let interactive = candidateSnapshot.elements.contains {
                    AXTreeReader.interactiveRoles.contains($0.role)
                }
                Log.cua.info(
                    "window candidate id=\(candidate.id) title=\(candidate.title, privacy: .public) elements=\(candidateSnapshot.elements.count) interactive=\(interactive)"
                )
                if firstSnapshot == nil {
                    firstSnapshot = candidateSnapshot
                    firstEntries = candidateEntries
                    firstSnapshotWindow = candidate
                }
                if interactive {
                    chosenWindow = candidate
                    snapshot = candidateSnapshot
                    chosenEntries = candidateEntries
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
        guard let selectedSnapshot = snapshot ?? firstSnapshot else {
            throw firstError ?? CuaDriverError.malformedResponse
        }
        return try await observeWindow(
            app: app,
            window: window,
            includeImage: wantsImage,
            reportedApps: reportedApps,
            snapshot: selectedSnapshot,
            axEntries: chosenWindow == nil ? firstEntries : chosenEntries
        )
    }

    private func observeWindow(
        app: CuaApp,
        window: CuaWindow,
        includeImage: Bool,
        reportedApps: [CuaApp],
        snapshot: CuaSnapshot?,
        axEntries: [String: AXEntry]
    ) async throws -> ToolOutput {
        Log.cua.info(
            "chosen window title=\(window.title, privacy: .public) app=\(app.name, privacy: .public)"
        )
        var resolvedSnapshot: CuaSnapshot
        var resolvedAXEntries = axEntries
        if let providedSnapshot = snapshot {
            resolvedSnapshot = providedSnapshot
        } else {
            let treeStarted = Date()
            let nativeWindowFrame = lastWindowFrame ?? Self.cgRect(window.frame)
            let nativeSnapshot = Config.shared.nativeAXEnabled
                ? await Task.detached(priority: .userInitiated) {
                    AXTreeReader.snapshot(
                        pid: app.pid,
                        windowFrame: nativeWindowFrame
                    )
                }.value
                : nil
            if let ax = nativeSnapshot {
                let axElapsed = Date().timeIntervalSince(treeStarted)
                Log.agent.info(
                    "stage=axtree elements=\(ax.snapshot.elements.count) interactive=\(ax.snapshot.elements.filter { AXTreeReader.interactiveRoles.contains($0.role) }.count) elapsed=\(axElapsed)"
                )
                resolvedSnapshot = ax.snapshot
                resolvedAXEntries = ax.entries
                if includeImage && Permission.screenRecording.isGranted {
                    let imageStarted = Date()
                    let imageSnapshot = try await CuaDriver.shared.windowState(
                        pid: app.pid,
                        windowId: window.id,
                        includeImage: true
                    )
                    cuaSeconds += Date().timeIntervalSince(imageStarted)
                    Log.agent.info("stage=tree elapsed=\(Date().timeIntervalSince(imageStarted))")
                    resolvedSnapshot = CuaSnapshot(
                        snapshotId: resolvedSnapshot.snapshotId,
                        treeMarkdown: resolvedSnapshot.treeMarkdown,
                        elements: resolvedSnapshot.elements,
                        image: imageSnapshot.image
                    )
                }
            } else {
                let treeStarted = Date()
                resolvedSnapshot = try await CuaDriver.shared.windowState(
                    pid: app.pid,
                    windowId: window.id,
                    includeImage: includeImage && Permission.screenRecording.isGranted
                )
                let treeElapsed = Date().timeIntervalSince(treeStarted)
                cuaSeconds += treeElapsed
                Log.agent.info("stage=tree elapsed=\(treeElapsed)")
            }
        }
        lastCDPTitle = nil
        lastCDPPort = nil
        var mergedSnapshot = resolvedSnapshot
        var ocrPoints: [String: CGPoint] = [:]
        let interactiveRoles: Set<String> = [
            "AXButton", "AXLink", "AXTextField", "AXTextArea", "AXMenuItem",
            "AXTab", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXComboBox",
            "AXRow", "AXCell",
        ]
        let cdpInteractiveRoles: Set<String> = [
            "AXButton", "AXLink", "AXTextField", "AXTextArea", "AXMenuItem",
            "AXTab", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXComboBox",
            "AXRow", "AXCell",
        ]
        if Config.shared.cdpEnabled {
            let cdpStarted = Date()
            defer {
                Log.agent.info("stage=cdp elapsed=\(Date().timeIntervalSince(cdpStarted))")
            }
            if Self.shouldTryCDP(
                bundleId: app.bundleId,
                interactiveCount: resolvedSnapshot.elements.filter {
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
                    snapshotId: resolvedSnapshot.snapshotId,
                    treeMarkdown: resolvedSnapshot.treeMarkdown,
                    elements: resolvedSnapshot.elements + cdpElements,
                    image: resolvedSnapshot.image
                )
                lastCDPTitle = window.title
                lastCDPPort = Config.shared.cdpPort
                Log.cua.info(
                    "cdp merged elements=\(cdpElements.count) title=\(window.title, privacy: .public)"
                )
            }
        }
        let interactiveCount = mergedSnapshot.elements.filter {
            AXTreeReader.interactiveRoles.contains($0.role)
        }.count
        if Config.shared.ocrFallbackEnabled,
           interactiveCount < 3,
           Permission.screenRecording.isGranted,
           let frame = lastWindowFrame ?? Self.cgRect(window.frame) {
            let ocrStarted = Date()
            let hits = await Task.detached(priority: .userInitiated) {
                OCRReader.scan(windowFrame: frame)
            }.value ?? []
            Log.agent.info(
                "stage=ocr labels=\(hits.count) elapsed=\(Date().timeIntervalSince(ocrStarted))"
            )
            if !hits.isEmpty {
                let lines = hits.map { hit in
                    "[\(hit.element.token)] \(hit.element.role) \(hit.element.label)"
                }.joined(separator: "\n")
                mergedSnapshot = CuaSnapshot(
                    snapshotId: mergedSnapshot.snapshotId,
                    treeMarkdown: mergedSnapshot.treeMarkdown + "\n" + lines,
                    elements: mergedSnapshot.elements + hits.map(\.element),
                    image: mergedSnapshot.image
                )
                ocrPoints = Dictionary(uniqueKeysWithValues: hits.map {
                    ($0.element.token, $0.point)
                })
            }
        }
        lastApp = app
        lastPID = app.pid
        lastWindowID = window.id
        if let frame = Self.cgRect(window.frame) {
            lastWindowFrame = frame
        }
        lastWindowTitle = window.title
        storeSnapshot(mergedSnapshot, axEntries: resolvedAXEntries, ocrPoints: ocrPoints)
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
            treeSource = resolvedSnapshot.treeMarkdown
        }
        let tree = String(treeSource.prefix(14000))
        let shownLines = tree.split(separator: "\n").count
        let omitted = max(0, mergedSnapshot.elements.count - shownLines)
        let text = "Running apps: \(reportedApps.map(\.name).joined(separator: ", ")); " +
            "frontmost window: \(window.title). Elements: \(mergedSnapshot.elements.count).\n" +
            "\(tree)\(omitted > 0 ? "\n… \(omitted) more" : "")\(extra)"
        return ToolOutput(text: text, content: text, image: resolvedSnapshot.image)
    }

    static func shouldTryCDP(bundleId: String?, interactiveCount: Int) -> Bool {
        bundleId?.hasPrefix("com.google.Chrome") == true || interactiveCount < 3
    }

    static func shouldRetryAfterActivate(_ error: Error) -> Bool {
        let description = error.localizedDescription
        return description.contains("-25206") || description.localizedCaseInsensitiveContains("AXPress")
    }

    private func storeSnapshot(
        _ snapshot: CuaSnapshot?,
        axEntries: [String: AXEntry] = [:],
        ocrPoints: [String: CGPoint] = [:]
    ) {
        lastSnapshot = snapshot
        lastAXEntries = snapshot == nil ? [:] : axEntries
        lastOCRPoints = snapshot == nil ? [:] : ocrPoints
    }

    private static func cgRect(_ frame: [String: Double]?) -> CGRect? {
        guard let frame,
              let x = frame["x"],
              let y = frame["y"],
              let width = frame["width"],
              let height = frame["height"] else {
            return nil
        }
        return CGRect(x: x, y: y, width: width, height: height)
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
        let started = Date()
        defer {
            Log.agent.info("stage=reobserve elapsed=\(Date().timeIntervalSince(started))")
        }
        let observation: ToolOutput
        if let app = lastApp, let windowID = lastWindowID {
            do {
                try await Task.sleep(for: .milliseconds(150))
                observation = try await observeWindow(
                    app: app,
                    window: CuaWindow(
                        id: windowID,
                        title: lastWindowTitle ?? "",
                        frame: nil
                    ),
                    includeImage: false,
                    reportedApps: cachedApps ?? [app],
                    snapshot: nil,
                    axEntries: [:]
                )
            } catch {
                observation = try await observe([:])
            }
        } else {
            observation = try await observe([:])
        }
        return ToolOutput(
            text: "\(text). Window title now observed; \(lastSnapshot?.elements.count ?? 0) elements.",
            content: "\(text). Window title now observed; \(lastSnapshot?.elements.count ?? 0) elements.\n\(observation.text)",
            image: observation.image
        )
    }

    private func focusTextElementIfNeeded(pid: Int) async throws {
        if TextEntry.focusedTextInput(pid: pid_t(pid)) != nil {
            return
        }
        if TextEntry.focusTextElementIfNeeded(pid: pid_t(pid)) {
            return
        }
        let fields = lastSnapshot?.elements.filter {
            ["AXTextField", "AXTextArea", "AXSearchField"].contains($0.role)
                && !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } ?? []
        guard !fields.isEmpty else { return }
        let goalWords = Set(currentGoal.lowercased().split {
            !$0.isLetter && !$0.isNumber
        }.map(String.init))
        let element = fields.max { lhs, rhs in
            let lhsScore = Set(lhs.label.lowercased().split {
                !$0.isLetter && !$0.isNumber
            }.map(String.init)).intersection(goalWords).count
            let rhsScore = Set(rhs.label.lowercased().split {
                !$0.isLetter && !$0.isNumber
            }.map(String.init)).intersection(goalWords).count
            return lhsScore < rhsScore
        }
        guard let element else {
            return
        }
        Log.agent.info("stage=focus role=\(element.role, privacy: .public)")
        guard let entry = lastAXEntries[element.token] else {
            let result = try await measureCua {
                try await CuaDriver.shared.click(
                    pid: pid,
                    token: element.token
                )
            }
            _ = result
            return
        }
        do {
            try AXTreeReader.press(entry)
        } catch {
            do {
                try AXTreeReader.focus(entry)
            } catch {
                let result = try await measureCua {
                    try await CuaDriver.shared.click(
                        pid: pid,
                        token: element.token
                    )
                }
                _ = result
            }
        }
    }

    private func verifiedTypingResult(pid: Int, text: String, fallback: String) -> String {
        let firstReadBack: KeyboardFocus.ReadBack
        if let focused = KeyboardFocus.focusedElement(pid: pid_t(pid)),
           KeyboardFocus.textRoles.contains(focused.role) {
            firstReadBack = KeyboardFocus.readBack(value: focused.value, expected: text)
        } else {
            firstReadBack = .unobservable
        }
        switch firstReadBack {
        case .confirmed:
            return fallback
        case .unobservable:
            Log.agent.info("type readback=unobservable (unverified)")
            return fallback
        case .missing:
            Log.agent.info("type readback=miss")
            KeyboardFocus.typeUnicode(text)
            let secondReadBack: KeyboardFocus.ReadBack
            if let focused = KeyboardFocus.focusedElement(pid: pid_t(pid)),
               KeyboardFocus.textRoles.contains(focused.role) {
                secondReadBack = KeyboardFocus.readBack(value: focused.value, expected: text)
            } else {
                secondReadBack = .unobservable
            }
            switch secondReadBack {
            case .confirmed:
                return fallback
            case .unobservable:
                Log.agent.info("type readback=unobservable (unverified)")
                return fallback
            case .missing:
                return "Typed \(text) but the field did not show it"
            }
        }
    }

    private func typedTextVisible(goal: String, snapshot: CuaSnapshot?) -> Bool? {
        guard let expected = SlotExtractor.typedText(from: goal) else { return nil }
        guard let snapshot else { return false }
        let textElements = snapshot.elements.filter {
            KeyboardFocus.textRoles.contains($0.role)
        }
        guard textElements.contains(where: {
            guard let value = $0.value else { return false }
            return !value.isEmpty
        }) else {
            return nil
        }
        return snapshot.elements.contains {
            KeyboardFocus.confirmsTyped(value: $0.value, expected: expected)
                || KeyboardFocus.confirmsTyped(value: $0.label, expected: expected)
        }
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
    var siteHost: String?
    var generatedText: String?

    init(frontmostApp: String? = nil, siteHost: String? = nil, generatedText: String? = nil) {
        self.frontmostApp = frontmostApp
        self.siteHost = siteHost
        self.generatedText = generatedText
    }
}

struct ToolOutput {
    let text: String
    let content: String
    let image: Data?
}
