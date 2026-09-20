import JevVoiceCore

extension VoiceController {
    func shouldUseComputerAgent(
        transcript: String,
        decisions: [Decision],
        verdict: ExecutionPolicy.Verdict,
        error: Error?
    ) -> Bool {
        Self.shouldRoute(
            transcript: transcript,
            decisions: decisions,
            verdict: verdict,
            agentAvailable: agentAvailable,
            enabled: config.computerUseEnabled,
            installedApps: AppRegistry.shared.names,
            aliases: AppRegistry.shared.aliases,
            error: error
        )
    }

    static func shouldRoute(
        transcript: String,
        decisions: [Decision],
        verdict: ExecutionPolicy.Verdict,
        agentAvailable: Bool,
        enabled: Bool,
        installedApps: [String] = [],
        aliases: [String: String] = [:],
        error: Error? = nil
    ) -> Bool {
        guard enabled, agentAvailable else { return false }
        if error != nil || decisions.isEmpty { return true }
        if case .reject = verdict { return true }
        if decisions.allSatisfy({ $0.action == .none }) { return true }
        if decisions.contains(where: { decision in
            guard decision.model == "local",
                  [.openApp, .switchApp].contains(decision.action) else {
                return false
            }
            guard let app = decision.targetApp else { return true }
            return !AppMatcher.residualWords(
                clause: decision.clause,
                matchedApp: app,
                aliases: aliases
            ).isEmpty
        }) {
            return true
        }
        let startsWithLocalVerb = startsWithLocalCommand(transcript)
        let dictateOnly = decisions.allSatisfy { $0.action == .dictate }
        let words = transcript.split(whereSeparator: { $0.isWhitespace }).count
        return dictateOnly && words >= 4 && !startsWithLocalVerb
    }

    private var agentAvailable: Bool {
        config.plannerMode == .jev
            ? !config.apiKey.isEmpty
            : !config.deepSeekAPIKey.isEmpty
    }

    private static func startsWithLocalCommand(_ transcript: String) -> Bool {
        if AppMatcher.verbAction(clause: transcript) != nil { return true }
        guard let first = transcript.split(whereSeparator: { $0.isWhitespace }).first?
            .lowercased() else { return false }
        return ["type", "write", "dictate", "say", "search", "google"].contains(first)
    }

    func agentFallback(transcript: String) async {
        status = .executing
        onListeningChanged?(false)
        let outcome = await AgentRunner.shared.run(
            goal: transcript,
            context: AgentContext(frontmostApp: lastExternalFrontmostApp)
        )
        switch outcome {
        case .done(let summary):
            status = .done
            self.transcript = summary
            await self.speakIfEnabled(summary)
        case .failed(let reason):
            status = .error(reason)
            await self.speakIfEnabled(reason)
        case .cancelled:
            status = .idle
        }
        onDone?()
    }
}
