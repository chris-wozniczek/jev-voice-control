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
            hasKey: !config.deepSeekAPIKey.isEmpty,
            enabled: config.computerUseEnabled,
            error: error
        )
    }

    static func shouldRoute(
        transcript: String,
        decisions: [Decision],
        verdict: ExecutionPolicy.Verdict,
        hasKey: Bool,
        enabled: Bool,
        error: Error? = nil
    ) -> Bool {
        guard enabled, hasKey else { return false }
        if error != nil || decisions.isEmpty { return true }
        if case .reject = verdict { return true }
        let startsWithLocalVerb = startsWithLocalCommand(transcript)
        let dictateOnly = decisions.allSatisfy { $0.action == .dictate }
        let words = transcript.split(whereSeparator: { $0.isWhitespace }).count
        return dictateOnly && words >= 4 && !startsWithLocalVerb
    }

    static func looksOpenEnded(_ transcript: String) -> Bool {
        transcript.split(whereSeparator: { $0.isWhitespace }).count >= 4
            && !startsWithLocalCommand(transcript)
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
