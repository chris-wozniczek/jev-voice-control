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

    var isListening: Bool { status == .listening }

    let config = Config.shared
    let recognizer = SpeechRecognizer()
    let speaker = Speaker.shared

    var onListeningChanged: ((Bool) -> Void)?
    var onDone: (() -> Void)?

    private var cancellables: Set<AnyCancellable> = []
    private var startTask: Task<Void, Never>?
    private var confirmationTimeoutTask: Task<Void, Never>?
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
                if self.awaitingVoiceAnswer {
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
                self.onDone?()
            } else {
                self.status = .idle
            }
            self.onListeningChanged?(false)
        }
        recognizer.$transcript
            .filter { !$0.isEmpty }
            .sink { [weak self] in self?.transcript = $0 }
            .store(in: &cancellables)
        recognizer.$statusMessage
            .sink { [weak self] in self?.speechStatusMessage = $0 }
            .store(in: &cancellables)
    }

    deinit {
        if let frontmostObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(frontmostObserver)
        }
    }

    func refreshPermissions() {
        missingPermissions = Permission.missing
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
                onDone?()
                return
            }
            do {
                decisions = []
                transcript = ""
                suggestions = []
                suggestionClause = ""
                recognizer.contextualStrings = AppRegistry.shared.spokenVariants
                try recognizer.start()
                status = .listening
                onListeningChanged?(true)
            } catch {
                status = .error(error.localizedDescription)
                speakError(error.localizedDescription)
                onDone?()
            }
        }
    }

    private func interpretAndExecute(_ text: String) async {
        status = .thinking
        onListeningChanged?(false)
        transcript = text

        let registry = AppRegistry.shared
        let client = JevClient(apiKey: config.apiKey)
        let interpreter = CommandInterpreter(
            client: client,
            installedApps: Array(registry.names.prefix(254)),
            aliases: registry.aliases
        )

        do {
            var result = try await interpreter.interpret(
                transcript: text, frontmostApp: lastExternalFrontmostApp
            )
            latencyMs = result.map(\.latencyMs).max() ?? 0
            model = result.first?.model ?? ""
            for i in result.indices { result[i].latencyMs = latencyMs }
            decisions = result
            history = (result + history).prefix(10).map { $0 }
            if !decisions.contains(where: { $0.action != .none }),
               await offerSuggestions(for: text, decisions: decisions) {
                return
            }
        } catch {
            status = .error(error.localizedDescription)
            speakError(error.localizedDescription)
            onDone?()
            return
        }

        switch ExecutionPolicy.verdict(for: decisions, alwaysConfirm: config.alwaysConfirm) {
        case .run:
            await executeAll()
        case .confirm(let reason):
            await requestVoiceConfirmation(reason: reason)
        case .reject(let reason):
            if await offerSuggestions(for: text, decisions: decisions) {
                return
            }
            status = .error(reason)
            await speakIfEnabled(reason)
            onDone?()
        }
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
        onDone?()
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
    }

    private func executeAll() async {
        let actionable = decisions.filter { $0.action != .none }
        guard !actionable.isEmpty else {
            status = .done
            onDone?()
            return
        }
        status = .executing
        var previousAction: Action?
        var results: [String] = []
        for decision in actionable {
            do {
                if decision.action == .dictate,
                   let previousAction,
                   [.openApp, .switchApp, .openURL, .webSearch].contains(previousAction) {
                    try await Task.sleep(nanoseconds: 700_000_000)
                }
                results.append(try await Executor.execute(decision))
                previousAction = decision.action
            } catch {
                status = .error(error.localizedDescription)
                speakError(error.localizedDescription)
                onDone?()
                return
            }
        }
        status = .done
        if config.speakReplies {
            await speaker.say(results.joined(separator: ". "))
        }
        onDone?()
    }

    private func speakError(_ message: String) {
        let text = String(message.prefix(120))
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.speakIfEnabled(text)
        }
    }

    private func speakIfEnabled(_ text: String) async {
        guard config.speakReplies else { return }
        await speaker.say(text)
    }
}
