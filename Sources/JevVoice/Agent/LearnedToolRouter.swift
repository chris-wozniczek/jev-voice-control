import Foundation
import JevVoiceCore

enum LearnedToolRoute {
    case notHandled
    case completed(String)
    case failed(String)
    case needsConfirmation(
        reason: String,
        operation: () async -> LearnedToolResult<String>
    )
}

@MainActor
struct LearnedToolRouter {
    let config: Config
    let store: LearnedToolStore
    let client: JevClient?
    let generator: ContentGenerating?

    func route(transcript: String, frontmostApp: String?, installedApps: [String]) async -> LearnedToolRoute {
        let enabled = store.enabledTools()
        guard !enabled.isEmpty || client != nil else { return .notHandled }

        var selected: StoredLearnedTool?
        if !enabled.isEmpty, let client {
            selected = await cachedMatch(
                transcript: transcript,
                tools: enabled,
                client: client
            )
        }

        var tool: LearnedTool
        var rounds = 1
        var cached = false
        if let selected {
            tool = selected.tool
            cached = true
        } else {
            guard let client, let generator else { return .notHandled }
            let scriptable = await scriptable(
                transcript: transcript,
                frontmostApp: frontmostApp,
                installedApps: installedApps,
                client: client
            )
            guard scriptable else { return .notHandled }
            switch await ToolSynthesizer(
                generator: generator,
                jev: client,
                safetyPolicy: config.safetyPolicy
            ).synthesize(transcript: transcript) {
            case .success(let generated):
                tool = generated.tool
                rounds = generated.rounds
            case .failure(let reason):
                return .failed(reason)
            }
        }

        switch await ToolExecutor.arguments(
            for: tool,
            transcript: transcript,
            jev: client
        ) {
        case .failure(let reason):
            return .failed(reason)
        case .success(let args):
            let operation: () async -> LearnedToolResult<String> = {
                await ToolExecutor.execute(
                    tool: tool,
                    args: args,
                    transcript: transcript,
                    store: store,
                    jev: client,
                    safetyPolicy: config.safetyPolicy,
                    cached: cached,
                    rounds: rounds
                )
            }
            if tool.mutates {
                return .needsConfirmation(
                    reason: "Run \(tool.description)? Yes or no.",
                    operation: operation
                )
            }
            switch await operation() {
            case .success(let result):
                Log.agent.info(
                    "stage=tool name=\(tool.name, privacy: .public) cached=\(cached) gates=compile,policy,review rounds=1 elapsed=0"
                )
                return .completed(result)
            case .failure(let reason):
                return .failed(reason)
            }
        }
    }

    private func cachedMatch(
        transcript: String,
        tools: [StoredLearnedTool],
        client: JevClient
    ) async -> StoredLearnedTool? {
        let criteria = Dictionary(
            uniqueKeysWithValues: tools.map { ($0.tool.name, Optional($0.tool.description)) }
                + [("none of these", nil)]
        )
        let descriptions = tools.map {
            "\($0.tool.name): \($0.tool.description); examples: \($0.tool.utteranceExamples.joined(separator: ", "))"
        }.joined(separator: "\n")
        do {
            let response = try await client.systemOne(
                state: ToolMatchState(transcript: transcript, tools: descriptions),
                questions: [
                    "tool": .choice(
                        instructions: "Which cached tool matches this request? Choose none of these if no tool matches.",
                        criteria: criteria
                    ),
                ]
            ).response
            guard case .choice(let choice, let confidence, _) = response.answers["tool"],
                  confidence >= 0.7,
                  choice != "none of these" else {
                return nil
            }
            return tools.first {
                $0.tool.name.caseInsensitiveCompare(choice) == .orderedSame
            }
        } catch {
            return nil
        }
    }

    private func scriptable(
        transcript: String,
        frontmostApp: String?,
        installedApps: [String],
        client: JevClient
    ) async -> Bool {
        do {
            let response = try await client.systemOne(
                state: ScriptableState(
                    transcript: transcript,
                    frontmostApp: frontmostApp ?? "",
                    installedApps: Array(installedApps.prefix(254))
                ),
                questions: [
                    "scriptable": .noul(
                        instructions: """
                        Can this request be fulfilled by running an AppleScript/JXA script on macOS
                        without operating an app's window with mouse and keyboard (system settings,
                        Reminders, Calendar, Notes creation, Finder file ops, timers, Music playback,
                        Wi-Fi, Do Not Disturb, volume, dark mode)? Answer no for anything that means
                        clicking/typing inside an app's UI, browsing the web, or operating Devin/terminal apps.
                        """
                    ),
                ]
            ).response
            if case .noul(let probability) = response.answers["scriptable"] {
                return probability >= 0.7
            }
        } catch {}
        return false
    }
}

private struct ToolMatchState: Encodable {
    let transcript: String
    let tools: String
}

private struct ScriptableState: Encodable {
    let transcript: String
    let frontmostApp: String
    let installedApps: [String]
}
