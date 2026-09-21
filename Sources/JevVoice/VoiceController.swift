import AppKit
import Combine
import JevVoiceCore
import SwiftUI

@MainActor
final class VoiceController: ObservableObject {
    enum Status: Equatable {
        case idle, listening, thinking, awaitingConfirm, executing, done
        case error(String)
    }

    @Published var status: Status = .idle
    @Published var transcript = ""
    @Published var decisions: [Decision] = []
    @Published var latencyMs: Double = 0
    @Published var model = ""
    @Published var history: [Decision] = []
    @Published var showSettings = false
    @Published var missingPermissions: [Permission] = Permission.missing
    @Published var hotKeyRegistered = true
    @Published var awaitingVoiceAnswer = false
    @Published var speechStatusMessage: String?
    @Published var suggestions: [String] = []
    @Published var suggestionClause = ""
    @Published var taskSeconds: Double = 0

    var isListening: Bool { status == .listening }

    let config = Config.shared
    let recognizer = SpeechRecognizer()
    let speaker = Speaker.shared

    var onListeningChanged: ((Bool) -> Void)?
    var onDone: (() -> Void)?

    private var cancellables: Set<AnyCancellable> = []
    private var startTask: Task<Void, Never>?
    private var confirmationTimeoutTask: Task<Void, Never>?
    private var taskStartedAt: Date?
    private var frontmostObserver: NSObjectProtocol?
    private(set) var lastExternalFrontmostApp: String?

    init() {
        let ownBundleID = Bundle.main.bundleIdentifier
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.bundleIdentifier != ownBundleID {
            lastExternalFrontmostApp = frontmost.localizedName
        }
        frontmostObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication,
                app.bundleIdentifier != ownBundleID else { return }
            let name = app.localizedName
            Task { @MainActor [weak self] in
                self?.lastExternalFrontmostApp = name
            }
        }

        recognizer.onFinalTranscript = { [weak self] text in
            Task { @MainActor in
                guard let self else { return }
                self.beginTask()
                if AgentRunner.shared.isRunning,
                   ["stop", "cancel", "never mind", "nevermind"].contains(text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)) {
                    AgentRunner.shared.cancel()
                    self.status = .idle
                    self.completeTask()
                } else if AgentRunner.shared.resolveConfirmation(text) {
                    self.awaitingVoiceAnswer = false
                } else if self.awaitingVoiceAnswer {
                    await self.handleConfirmAnswer(text)
                } else {
                    await self.interpretAndExecute(text)
                }
            }
        }
        recognizer.onEndedWithoutSpeech = { [weak self] error in
            guard let self, self.status == .listening else { return }
            if self.awaitingVoiceAnswer {
                return
            }
            if let error {
                self.status = .error("Speech recognition failed: \(error.localizedDescription)")
                self.speakError(error.localizedDescription)
                self.completeTask()
            } else {
                self.status = .idle
            }
            self.onListeningChanged?(false)
        }
        recognizer.$transcript
            .filter { !$0.isEmpty }
            .sink { [weak self] in self?.transcript = TranscriptNormalizer.normalize($0) }
            .store(in: &cancellables)
        recognizer.$statusMessage
            .sink { [weak self] in self?.speechStatusMessage = $0 }
            .store(in: &cancellables)
        AgentRunner.shared.confirmationHandler = { [weak self] reason in
            guard let self else { return }
            self.status = .awaitingConfirm
            self.awaitingVoiceAnswer = true
            await self.speakIfEnabled("\(reason). Yes or no?")
            self.startListening()
        }
    }

    deinit {
        if let frontmostObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(frontmostObserver)
        }
    }

    func refreshPermissions() {
        missingPermissions = Permission.missing
    }

    private func beginTask() {
        taskSeconds = 0
        taskStartedAt = Date()
    }

    func completeTask() {
        if let taskStartedAt {
            taskSeconds = Date().timeIntervalSince(taskStartedAt)
            self.taskStartedAt = nil
        }
        onDone?()
    }

    func clearHistory() {
        decisions = []
        if case .done = status {
            suggestions = []
            suggestionClause = ""
            status = .idle
        } else if case .error = status {
            suggestions = []
            suggestionClause = ""
            status = .idle
        }
    }

    func requestMissingPermissions() async {
        for permission in Permission.missing where permission.canPrompt {
            await permission.request()
        }
        refreshPermissions()
    }

    func toggle() {
        switch status {
        case .listening:
            recognizer.stop()
        case .executing:
            startListening()
        case .idle, .done, .error:
            startListening()
        default:
            break
        }
    }

    func stopListening() {
        recognizer.stop()
    }

    func startListening() {
        speaker.stop()
        guard startTask == nil else { return }
        startTask = Task {
            defer { startTask = nil }
            let granted = await SpeechRecognizer.requestAuthorization()
            refreshPermissions()
            guard granted else {
                status = .error("Microphone or Speech Recognition permission denied")
                await speaker.say("Microphone or Speech Recognition permission denied")
                completeTask()
                return
            }
            do {
                decisions = []
                transcript = ""
                suggestions = []
                suggestionClause = ""
                recognizer.contextualStrings = SpeechRecognizer.orderedVocabulary(
                    extra: config.customVocabulary,
                    appNames: AppRegistry.shared.spokenVariants
                )
                try recognizer.start()
                status = .listening
                onListeningChanged?(true)
            } catch {
                status = .error(error.localizedDescription)
                speakError(error.localizedDescription)
                completeTask()
            }
        }
    }

    private func interpretAndExecute(_ text: String) async {
        let normalizedText = TranscriptNormalizer.normalize(text)
        if normalizedText != text {
            Log.speech.info(
                "transcript normalized from=\(text, privacy: .public) to=\(normalizedText, privacy: .public)"
            )
        }
        let text = normalizedText
        status = .thinking
        onListeningChanged?(false)
        transcript = text
        if !AgentRunner.shared.isRunning {
            AgentRunner.shared.clearSteps()
        }

        let registry = AppRegistry.shared
        let client = JevClient(apiKey: config.apiKey)
        let interpreter = CommandInterpreter(
            client: client,
            installedApps: Array(registry.names.prefix(254)),
            aliases: registry.aliases,
            siteResolver: WebSiteRegistry.shared.resolver,
            defaultBrowser: config.defaultBrowser
        )

        var interpretationError: Error?
        do {
            var result = try await interpreter.interpret(
                transcript: text, frontmostApp: lastExternalFrontmostApp
            )
            latencyMs = result.map(\.latencyMs).max() ?? 0
            model = result.first?.model ?? ""
            for i in result.indices { result[i].latencyMs = latencyMs }
            result = Self.rerouteActionlessSystems(
                result,
                targetApp: lastExternalFrontmostApp
            )
            decisions = result
            history = (result + history).prefix(10).map { $0 }
        } catch {
            interpretationError = error
        }
        Log.command.info(
            "transcript=\(text, privacy: .public) decisions=\(self.decisions.count) error=\((interpretationError?.localizedDescription ?? "none"), privacy: .public)"
        )
        for decision in decisions {
            Log.command.info(
                "decision action=\(decision.action.rawValue, privacy: .public) target=\((decision.targetApp ?? ""), privacy: .public) confidence=\(decision.confidence) model=\(decision.model, privacy: .public)"
            )
        }

        if !(await generateComposedText()) {
            return
        }
        let verdict = ExecutionPolicy.verdict(
            for: decisions,
            alwaysConfirm: config.alwaysConfirm,
            previewGeneratedText: config.previewGeneratedText
        )
        Log.command.info("verdict=\(String(describing: verdict), privacy: .public)")
        let routesToAgent = shouldUseComputerAgent(
            transcript: text, decisions: decisions, verdict: verdict, error: interpretationError
        )
        Log.command.info("route=\(routesToAgent ? "agent" : "local", privacy: .public)")
        if !routesToAgent,
           !decisions.contains(where: { $0.action != .none }),
           await offerSuggestions(for: text, decisions: decisions) {
            return
        }
        if routesToAgent {
            await agentFallback(transcript: text)
            return
        }
        if let interpretationError {
            status = .error(interpretationError.localizedDescription)
            speakError(interpretationError.localizedDescription)
            completeTask()
            return
        }

        switch verdict {
        case .run:
            await executeAll()
        case .confirm(let reason):
            await requestVoiceConfirmation(reason: reason)
        case .reject(let reason):
            if !routesToAgent, await offerSuggestions(for: text, decisions: decisions) {
                return
            }
            status = .error(reason)
            await speakIfEnabled(reason)
            completeTask()
        }
    }

    static func rerouteActionlessSystems(
        _ decisions: [Decision],
        targetApp: String?
    ) -> [Decision] {
        decisions.map { decision in
            guard decision.action == .system,
                  decision.systemAction == nil || decision.systemAction == SystemAction.none else {
                return decision
            }
            var rerouted = decision
            rerouted.action = .uiTask
            rerouted.targetApp = targetApp
            Log.command.info(
                "reroute from=system to=uiTask target=\((targetApp ?? ""), privacy: .public)"
            )
            return rerouted
        }
    }

    func makeGenerator() -> ContentGenerating? {
        switch config.generatorSource {
        case .deepSeek:
            guard !config.deepSeekAPIKey.isEmpty,
                  let endpoint = URL(string: "https://api.deepseek.com/chat/completions") else {
                return nil
            }
            return OpenAICompatibleGenerator(
                endpoint: endpoint,
                apiKey: config.deepSeekAPIKey,
                model: "deepseek-flash",
                thinking: .off
            )
        case .omlx:
            guard !config.omlxTextModel.isEmpty else { return nil }
            let base = config.omlxBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let endpoint = URL(string: "\(base)/v1/chat/completions") else { return nil }
            return OpenAICompatibleGenerator(
                endpoint: endpoint,
                apiKey: nil,
                model: config.omlxTextModel,
                thinking: nil
            )
        }
    }

    private func generateComposedText() async -> Bool {
        let indices = decisions.indices.filter {
            decisions[$0].composes && decisions[$0].generatedText == nil
        }
        guard !indices.isEmpty else { return true }
        guard let generator = makeGenerator() else {
            let reason = "Add a DeepSeek key (or set up oMLX) in Settings so Jev can write text for you"
            status = .error(reason)
            await speakIfEnabled(reason)
            completeTask()
            return false
        }
        status = .thinking
        for index in indices {
            let decision = decisions[index]
            do {
                let generated = try await generator.compose(
                    brief: decision.query ?? decision.clause,
                    context: ComposeContext(
                        app: decision.targetApp ?? lastExternalFrontmostApp,
                        windowTitle: AgentRunner.shared.currentWindowTitle,
                        siteHost: decision.siteHost,
                        maxCharacters: decision.siteHost?.caseInsensitiveCompare("x.com") == .orderedSame
                            ? 280 : 600
                    )
                )
                decisions[index].generatedText = generated
                if decisions[index].action == .dictate {
                    decisions[index].text = generated
                }
            } catch {
                let reason = error.localizedDescription
                status = .error(reason)
                await speakIfEnabled(reason)
                completeTask()
                return false
            }
        }
        return true
    }

    @MainActor
    private func offerSuggestions(for text: String, decisions: [Decision]) async -> Bool {
        let registry = AppRegistry.shared
        let candidateDecision = decisions.first {
            Action.appTargeted.contains($0.action) && $0.targetApp == nil
        }
        let clause = candidateDecision?.clause
            ?? ClauseSplitter.split(text, boundaries: ClauseSplitter.candidateBoundaries(text))
                .first(where: { AppMatcher.verbAction(clause: $0) != nil })
            ?? text
        let spoken = candidateDecision?.spokenTarget ?? AppMatcher.spokenTarget(from: clause)
        guard let spoken, !spoken.isEmpty else { return false }
        let candidates = AppMatcher.candidates(
            for: spoken,
            installedApps: registry.names,
            aliases: registry.aliases
        )
        guard !candidates.isEmpty else { return false }
        suggestions = candidates
        suggestionClause = clause
        status = .error("I didn't catch the app")
        await speakIfEnabled("I didn't catch the app — did you mean \(candidates[0])?")
        completeTask()
        return true
    }

    func useSuggestion(_ app: String, teachAlias: Bool = false) {
        let clause = suggestionClause
        guard !clause.isEmpty else { return }
        let phrase = AppMatcher.spokenTarget(from: clause) ?? ""
        guard !phrase.isEmpty else { return }
        if teachAlias {
            config.appAliases[phrase.lowercased()] = app
            AppRegistry.shared.refresh()
        }
        let replacement = clause.replacingOccurrences(
            of: phrase,
            with: app,
            options: [.caseInsensitive]
        )
        suggestions = []
        suggestionClause = ""
        Task { await interpretAndExecute(replacement) }
    }

    private func requestVoiceConfirmation(reason: String) async {
        status = .awaitingConfirm
        awaitingVoiceAnswer = true
        let summaries = decisions
            .filter { $0.action != .none }
            .map(\.executionSummary)
            .joined(separator: ", then ")
        let question = summaries.isEmpty
            ? "\(reason). Yes or no?"
            : "\(reason). \(summaries). Yes or no?"
        await speakIfEnabled(question)
        guard awaitingVoiceAnswer else { return }
        confirmationTimeoutTask?.cancel()
        confirmationTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self, self.awaitingVoiceAnswer else { return }
            self.dismissConfirmation()
        }
        startListening()
    }

    private func handleConfirmAnswer(_ text: String) async {
        confirmationTimeoutTask?.cancel()
        let answer = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if matches(answer, pattern: #"^(yes|yeah|yep|yup|do it|go|run|ok|okay|confirm|sure)\b"#) {
            await confirmAndExecute()
        } else if matches(
            answer,
            pattern: #"^(no|nope|cancel|stop|dismiss|never mind|nevermind|don't)\b"#
        ) {
            dismissConfirmation()
            await speakIfEnabled("Cancelled")
        } else {
            dismissConfirmation()
            await interpretAndExecute(text)
        }
    }

    private func matches(_ text: String, pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    func confirmAndExecute() async {
        confirmationTimeoutTask?.cancel()
        awaitingVoiceAnswer = false
        recognizer.stop()
        await executeAll()
    }

    func dismiss() {
        dismissConfirmation()
    }

    private func dismissConfirmation() {
        confirmationTimeoutTask?.cancel()
        confirmationTimeoutTask = nil
        awaitingVoiceAnswer = false
        recognizer.stop()
        guard status == .awaitingConfirm || status == .listening else { return }
        decisions = []
        suggestions = []
        suggestionClause = ""
        status = .idle
        completeTask()
    }

    private func executeAll() async {
        let actionable = decisions.filter { $0.action != .none }
        guard !actionable.isEmpty else {
            let reason = agentUnavailableReason()
            status = .error(reason)
            await speakIfEnabled(reason)
            completeTask()
            return
        }
        status = .executing
        var previousAction: Action?
        var results: [String] = []
        for decision in actionable {
            do {
                if decision.action == .uiTask {
                    guard config.computerUseEnabled, agentAvailable else {
                        let reason = agentUnavailableReason()
                        status = .error(reason)
                        await speakIfEnabled(reason)
                        completeTask()
                        return
                    }
                    if previousAction == .openApp {
                        try await Task.sleep(nanoseconds: 1_200_000_000)
                    }
                    status = .executing
                    let target = decision.targetApp ?? lastExternalFrontmostApp
                    if let siteHost = decision.siteHost {
                        await ensureSiteOpen(host: siteHost, browser: target)
                    }
                    let outcome = await AgentRunner.shared.run(
                        goal: decision.clause,
                        context: AgentContext(
                            frontmostApp: target,
                            siteHost: decision.siteHost,
                            generatedText: decision.generatedText
                        )
                    )
                    switch outcome {
                    case .done(let summary):
                        results.append(summary)
                        Log.command.info(
                            "executor result action=uiTask result=\(summary, privacy: .public)"
                        )
                        previousAction = .uiTask
                    case .failed(let reason):
                        Log.command.info(
                            "executor error action=uiTask error=\(reason, privacy: .public)"
                        )
                        status = .error(reason)
                        await speakIfEnabled(reason)
                        completeTask()
                        return
                    case .cancelled:
                        status = .idle
                        completeTask()
                        return
                    }
                    continue
                }
                if decision.action == .dictate, decision.composes,
                   let siteHost = decision.siteHost {
                    await ensureSiteOpen(host: siteHost, browser: decision.targetApp ?? config.defaultBrowser)
                }
                if decision.action == .dictate,
                   let previousAction,
                   [.openApp, .switchApp, .openURL, .webSearch].contains(previousAction) {
                    try await Task.sleep(nanoseconds: 700_000_000)
                }
                let result = try await Executor.execute(
                    decision,
                    frontmostApp: decision.siteHost == nil
                        ? lastExternalFrontmostApp
                        : decision.targetApp
                )
                if decision.action == .dictate, decision.composes, decision.generatedText != nil {
                    let words = decision.generatedText?
                        .split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count ?? 0
                    results.append("Typed a \(words)-word message")
                } else {
                    results.append(result)
                }
                Log.command.info(
                    "executor result action=\(decision.action.rawValue, privacy: .public) result=\(result, privacy: .public)"
                )
                previousAction = decision.action
            } catch {
                Log.command.info(
                    "executor error action=\(decision.action.rawValue, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
                status = .error(error.localizedDescription)
                speakError(error.localizedDescription)
                completeTask()
                return
            }
        }
        status = .done
        if config.speakReplies {
            await speaker.say(results.joined(separator: ". "))
        }
        completeTask()
    }

    func agentUnavailableReason() -> String {
        if !config.computerUseEnabled {
            return "I don't know how to do that locally. Turn on Computer use in Settings."
        }
        if config.plannerMode == .jev {
            return "Add a TypeSafe API key in Settings to let Jev operate apps"
        }
        return "Add a DeepSeek API key in Settings to let Jev do open-ended tasks"
    }

    func ensureSiteOpen(host: String, browser: String?) async {
        let started = Date()
        let browserName = browser ?? config.defaultBrowser
        func matches() -> Bool {
            guard let app = NSWorkspace.shared.runningApplications.first(where: {
                $0.localizedName?.caseInsensitiveCompare(browserName) == .orderedSame
            }) else { return false }
            return AXTreeReader.windowIdentifiers(pid: app.processIdentifier).contains {
                $0.localizedCaseInsensitiveContains(host)
            }
        }
        var opened = false
        if !matches(), let url = URL(string: "https://\(host)") {
            opened = true
            _ = try? await Executor.execute(
                Decision(
                    clause: "open \(host)",
                    action: .openURL,
                    targetApp: browserName,
                    url: url.absoluteString
                )
            )
        }
        let deadline = Date().addingTimeInterval(4)
        while !matches(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        Log.command.info(
            "stage=site host=\(host, privacy: .public) opened=\(opened) elapsed=\(elapsed)"
        )
    }

    private func speakError(_ message: String) {
        let text = String(message.prefix(120))
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.speakIfEnabled(text)
        }
    }

    func speakIfEnabled(_ text: String) async {
        guard config.speakReplies else { return }
        await speaker.say(text)
    }
}
