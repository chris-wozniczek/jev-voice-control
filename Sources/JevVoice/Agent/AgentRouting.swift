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
        return decisions.allSatisfy { $0.action == .none }
    }

    var agentAvailable: Bool {
        config.plannerMode == .jev
            ? !config.apiKey.isEmpty
            : !config.deepSeekAPIKey.isEmpty
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
        completeTask()
    }
}
