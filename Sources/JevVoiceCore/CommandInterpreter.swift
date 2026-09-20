import Foundation

public final class CommandInterpreter {
    private let client: JevClient
    private let installedApps: [String]
    private let aliases: [String: String]
    private let siteResolver: SiteResolver
    private let defaultBrowser: String

    private static let browserNames: Set<String> = [
        "safari", "google chrome", "chrome", "firefox", "arc", "brave browser",
        "microsoft edge", "opera", "vivaldi", "orion", "duckduckgo",
    ]

    private static let uiTaskVerbs: Set<String> = [
        "click", "press", "tap", "select", "choose", "start", "create", "new",
        "open", "add", "scroll", "go", "pick", "toggle", "enable", "disable",
        "check", "uncheck", "send", "ask", "reply", "search", "find", "play",
        "pause", "next", "previous",
    ]

    public init(
        client: JevClient,
        installedApps: [String],
        aliases: [String: String] = [:],
        siteResolver: SiteResolver = SiteResolver(sites: SiteResolver.defaultSites),
        defaultBrowser: String = "Google Chrome"
    ) {
        self.client = client
        self.installedApps = installedApps
        self.aliases = aliases
        self.siteResolver = siteResolver
        self.defaultBrowser = defaultBrowser
    }

    struct State: Encodable {
        let clause: String
        let fullTranscript: String
        let frontmostApp: String?
        let installedApps: [String]
        let aliases: [String: String]

        enum CodingKeys: String, CodingKey {
            case clause
            case fullTranscript = "full_transcript"
            case frontmostApp = "frontmost_app"
            case installedApps = "installed_apps"
            case aliases
        }
    }

    private struct BoundaryCandidate: Encodable {
        let index: Int
        let before: String
        let after: String
    }

    private struct BoundaryState: Encodable {
        let transcript: String
        let candidates: [BoundaryCandidate]
    }

    public func interpret(transcript: String, frontmostApp: String?) async throws -> [Decision] {
        let boundaries = ClauseSplitter.candidateBoundaries(transcript)
        let judgmentBoundaries = boundaries.filter(\.needsJudgment)
        let clauses: [String]
        if judgmentBoundaries.isEmpty {
            clauses = ClauseSplitter.split(transcript, boundaries: boundaries)
        } else {
            let ns = transcript as NSString
            let candidates = judgmentBoundaries.enumerated().map { index, boundary in
                BoundaryCandidate(
                    index: index,
                    before: ns.substring(with: NSRange(location: 0, length: boundary.location))
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                    after: ns.substring(from: boundary.location)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            let questions = Dictionary(uniqueKeysWithValues: candidates.map { candidate in
                (
                    "boundary_\(candidate.index)",
                    Question.noul(
                        instructions: "In the spoken transcript `transcript`, does the text `candidates[\(candidate.index)].after` begin a new, separate command that the user wants performed after `candidates[\(candidate.index)].before`, rather than being the content, object, or continuation of the previous command (for example words to be typed, a search phrase, or a website name)?"
                    )
                )
            })
            do {
                let boundaryResponse = try await client.systemOne(
                    state: BoundaryState(transcript: transcript, candidates: candidates),
                    questions: questions
                )
                let response = boundaryResponse.response
                let accepted = boundaries.filter { boundary in
                    guard boundary.needsJudgment,
                          let index = judgmentBoundaries.firstIndex(of: boundary),
                          case .noul(let probability) = response.answers["boundary_\(index)"]
                    else {
                        return !boundary.needsJudgment
                    }
                    return probability > 0.6
                }
                clauses = ClauseSplitter.split(transcript, boundaries: accepted)
            } catch {
                clauses = ClauseSplitter.split(transcript)
            }
        }
        return Self.propagateContext(try await interpretClauses(
            clauses, transcript: transcript, frontmostApp: frontmostApp
        ))
    }

    private func interpretClauses(
        _ clauses: [String], transcript: String, frontmostApp: String?
    ) async throws -> [Decision] {
        return try await withThrowingTaskGroup(of: (Int, [Decision]).self) { group in
            for (index, clause) in clauses.enumerated() {
                group.addTask {
                    if let local = Self.localDecisions(
                        clause: clause,
                        installedApps: self.installedApps,
                        aliases: self.aliases,
                        frontmostApp: frontmostApp,
                        siteResolver: self.siteResolver,
                        defaultBrowser: self.defaultBrowser
                    ) {
                        return (index, local)
                    }
                    let decision = try await self.interpretClause(
                        clause, transcript: transcript, frontmostApp: frontmostApp
                    )
                    return (index, [decision])
                }
            }
            var ordered: [(Int, [Decision])] = []
            for try await result in group { ordered.append(result) }
            return ordered.sorted { $0.0 < $1.0 }.flatMap(\.1)
        }
    }

    static func localDecisions(
        clause: String,
        installedApps: [String],
        aliases: [String: String],
        frontmostApp: String?,
        siteResolver: SiteResolver = SiteResolver(sites: SiteResolver.defaultSites),
        defaultBrowser: String = "Google Chrome"
    ) -> [Decision]? {
        guard let local = LocalCommandParser.parse(
            clause: clause,
            installedApps: installedApps,
            aliases: aliases,
            frontmostApp: frontmostApp,
            siteResolver: siteResolver,
            defaultBrowser: defaultBrowser
        ) else {
            return nil
        }
        guard [.openApp, .switchApp].contains(local.action),
              let targetApp = local.targetApp else {
            return [local]
        }
        let residual = AppMatcher.residualWords(
            clause: clause,
            matchedApp: targetApp,
            aliases: aliases
        )
        guard residual.count >= 2 else {
            return [local]
        }
        let spokenVerb = clause
            .split(whereSeparator: { $0.isWhitespace })
            .first
            .map(String.init) ?? "open"
        let verb = local.action == .switchApp ? "\(spokenVerb) \(spokenVerb == "switch" ? "to " : "")" : "\(spokenVerb) "
        let reduced = Decision(
            clause: "\(verb)\(targetApp)",
            action: local.action,
            actionProbabilities: local.actionProbabilities,
            targetApp: local.targetApp,
            siteHost: local.siteHost,
            spokenTarget: local.spokenTarget,
            targetAppProbabilities: local.targetAppProbabilities,
            systemAction: local.systemAction,
            url: local.url,
            query: local.query,
            text: local.text,
            percent: local.percent,
            destructive: local.destructive,
            confidence: local.confidence,
            latencyMs: local.latencyMs,
            model: local.model
        )
        return [
            reduced,
            Decision(
                clause: residual.joined(separator: " "),
                action: .uiTask,
                targetApp: targetApp,
                confidence: 0.85,
                model: "local"
            ),
        ]
    }

    static func composes(from answer: Answer, action: Action) -> Bool {
        guard [.dictate, .uiTask].contains(action),
              case .noul(let probability) = answer else {
            return false
        }
        return probability > 0.6
    }

    private func interpretClause(
        _ clause: String, transcript: String, frontmostApp: String?
    ) async throws -> Decision {
        var appCriteria: [String: String?] = ["none": "No application mentioned"]
        for app in installedApps.prefix(254) { appCriteria[app] = nil }

        var actionCriteria: [String: String?] = [:]
        for action in Action.allCases { actionCriteria[action.rawValue] = action.description }

        var systemCriteria: [String: String?] = [:]
        for action in SystemAction.allCases { systemCriteria[action.rawValue] = action.description }

        let questions: [String: Question] = [
            "action": .choice(
                instructions: "What action does this spoken command clause request? Clause: \"\(clause)\"",
                criteria: actionCriteria
            ),
            "target_app": .choice(
                instructions: "Which application does the clause refer to? Clause: \"\(clause)\"",
                criteria: appCriteria
            ),
            "system_action": .choice(
                instructions: "Which system action does the clause request? Clause: \"\(clause)\"",
                criteria: systemCriteria
            ),
            "mentions_url": .noul(
                instructions: "Does the clause \"\(clause)\" mention a website or URL?"
            ),
            "refers_to_frontmost": .noul(
                instructions: "Does the clause \"\(clause)\" refer to the currently active app rather than naming one?"
            ),
            "composes": .noul(
                instructions: "Does the clause \"\(clause)\" ask Jev to write or compose the wording itself (e.g. an apology, a reply, a summary, a message about something) rather than typing the exact words spoken?"
            ),
            "destructive": .noul(
                instructions: "Does the clause \"\(clause)\" ask to delete, remove, send, submit, pay, buy, sign out, shut down, or otherwise do something that is hard to undo?"
            ),
        ]

        let state = State(
            clause: clause,
            fullTranscript: transcript,
            frontmostApp: frontmostApp,
            installedApps: installedApps,
            aliases: aliases
        )
        let (response, latencyMs) = try await client.systemOne(state: state, questions: questions)

        var action = Action.none
        var actionProbs: [String: Double] = [:]
        var actionConfidence = 0.0
        if case .choice(let choice, let confidence, let probs) = response.answers["action"] {
            action = Action(rawValue: choice) ?? .none
            actionProbs = probs
            actionConfidence = confidence
        }
        if action == .none,
           clause.split(whereSeparator: { $0.isWhitespace }).count >= 2,
           let firstWord = clause.split(whereSeparator: { $0.isWhitespace }).first?
            .lowercased(),
           Self.uiTaskVerbs.contains(firstWord) {
            action = .uiTask
        }

        var targetApp: String?
        var targetProbs: [String: Double] = [:]
        var targetConfidence = 1.0
        if case .choice(let choice, let confidence, let probs) = response.answers["target_app"] {
            targetProbs = probs
            targetConfidence = confidence
            if choice != "none" { targetApp = choice }
        }

        var systemAction: SystemAction?
        var systemConfidence = 1.0
        if case .choice(let choice, let confidence, _) = response.answers["system_action"] {
            systemConfidence = confidence
            let parsed = SystemAction(rawValue: choice) ?? .none
            if parsed != .none { systemAction = parsed }
        }

        var refersToFrontmost = false
        if case .noul(let p) = response.answers["refers_to_frontmost"] {
            refersToFrontmost = p > 0.5
        }

        let url = SlotExtractor.url(from: clause)
        var query = SlotExtractor.searchQuery(from: clause)
        var text = SlotExtractor.dictationText(from: clause)
        let percent = SlotExtractor.numberPercent(from: clause)

        if action == .openURL && url == nil, let q = query {
            action = .webSearch
            query = q
        }
        let localMatch = refersToFrontmost
            ? nil : AppMatcher.match(
                clause: clause, installedApps: installedApps, aliases: aliases
            )
        if url == nil, query == nil, action != .openURL, action != .webSearch,
           action != .uiTask,
           let verbAction = AppMatcher.verbAction(clause: clause), let local = localMatch {
            action = verbAction
            actionConfidence = max(actionConfidence, 0.95)
            targetApp = local.app
            targetConfidence = local.confidence
            systemAction = nil
            systemConfidence = 1.0
        }
        if targetApp == nil && Action.appTargeted.contains(action) {
            if refersToFrontmost {
                if action != .openApp, let front = frontmostApp {
                    targetApp = front
                } else {
                    action = .none
                }
            } else if let local = localMatch {
                targetApp = local.app
                targetConfidence = local.confidence
            }
        }
        if action == .webSearch, targetApp == nil {
            targetApp = SlotExtractor.searchBrowser(from: clause)
        }
        if (action == .openURL || action == .webSearch),
           let app = targetApp,
           !CommandInterpreter.browserNames.contains(app.lowercased()) {
            targetApp = nil
        }
        if action == .system && systemAction == nil {
            systemAction = SystemAction.none
        }
        if systemAction != nil && action == .none {
            action = .system
        }

        let composes = response.answers["composes"]
            .map { Self.composes(from: $0, action: action) } ?? false
        if composes, let brief = SlotExtractor.composeRequest(from: clause) {
            query = brief
            text = nil
        }
        let site = siteResolver.site(in: clause, installedApps: installedApps)
        var siteHost: String?
        if let site, action == .uiTask || (action == .dictate && composes) {
            siteHost = site.host
            targetApp = SlotExtractor.searchBrowser(from: clause) ?? defaultBrowser
        }

        let destructive: Bool
        if case .noul(let probability) = response.answers["destructive"] {
            destructive = probability > 0.6
        } else {
            destructive = false
        }
        let confidence = action == .uiTask
            ? actionConfidence
            : min(actionConfidence, targetConfidence, systemConfidence)

        return Decision(
            clause: clause,
            action: action,
            actionProbabilities: actionProbs,
            targetApp: targetApp,
            siteHost: siteHost,
            spokenTarget: AppMatcher.spokenTarget(from: clause),
            targetAppProbabilities: targetProbs,
            systemAction: systemAction,
            url: url,
            query: query,
            text: text,
            percent: percent,
            destructive: destructive,
            composes: composes,
            confidence: confidence,
            latencyMs: latencyMs,
            model: response.model
        )
    }

    static func propagateContext(_ decisions: [Decision]) -> [Decision] {
        var result = decisions
        var lastBrowser: String?
        var lastTarget: String?
        for index in result.indices {
            let decision = result[index]
            if (decision.action == .openApp || decision.action == .switchApp),
               let targetApp = decision.targetApp {
                lastTarget = targetApp
                if browserNames.contains(targetApp.lowercased()) {
                    lastBrowser = targetApp
                }
            } else if decision.action == .uiTask,
                      result[index].targetApp == nil,
                      let lastTarget {
                result[index].targetApp = lastTarget
            } else if (decision.action == .openURL || decision.action == .webSearch),
                      result[index].targetApp == nil {
                result[index].targetApp = lastBrowser
            }
        }
        return result
    }
}
