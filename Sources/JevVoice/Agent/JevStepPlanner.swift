import Foundation
import JevVoiceCore

protocol JevAnswering {
    func systemOne(
        state: JSONValue,
        questions: [String: Question]
    ) async throws -> (SystemOneResponse, Double)
}

extension JevClient: JevAnswering {
    func systemOne(
        state: JSONValue,
        questions: [String: Question]
    ) async throws -> (SystemOneResponse, Double) {
        try await sendSystemOne(state: state, questions: questions)
    }

    private func sendSystemOne<State: Encodable>(
        state: State,
        questions: [String: Question]
    ) async throws -> (SystemOneResponse, Double) {
        try await systemOne(state: state, questions: questions)
    }
}

@MainActor
final class JevStepPlanner: ActionPlanner {
    nonisolated static func isRerankable(role: String, label: String) -> Bool {
        [
            "AXButton", "AXPopUpButton", "AXMenuItem", "AXTab", "AXCheckBox",
            "AXRadioButton", "AXComboBox", "AXMenuButton",
        ].contains(role)
            && label.split(whereSeparator: { $0.isWhitespace }).count <= 5
    }

    private struct Candidate {
        let id: String
        let element: CuaElement
        let overlap: Int

        var elementRoleIsText: Bool {
            ["AXTextField", "AXTextArea", "AXSearchField"].contains(element.role)
        }
    }

    private struct RankedCandidate {
        let originalIndex: Int
        let element: CuaElement
        let overlap: Int
    }

    private let client: JevAnswering
    private let canEscalate: Bool
    private let hints: HintStore
    private var previousActionKey: String?
    private var previousFingerprint: String?
    private var excludedLabels: Set<String> = []
    private var recoveryCount = 0
    private var wrongSurfaceTitle: String?
    private var closeShortcutIssued = false
    private var recentFingerprints: [String] = []
    private var initialControlTexts: Set<String>?

    private let interactiveRoles: Set<String> = [
        "AXButton", "AXLink", "AXTextField", "AXTextArea", "AXMenuItem",
        "AXTab", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXComboBox",
        "AXRow", "AXCell",
    ]

    init(client: JevAnswering, canEscalate: Bool, hints: HintStore = .shared) {
        self.client = client
        self.canEscalate = canEscalate
        self.hints = hints
    }

    func next(_ ctx: PlannerContext) async throws -> PlannerTurn {
        guard let snapshot = ctx.snapshot else {
            return makeTurn(
                call: DeepSeekToolCall(
                    id: "jev-\(ctx.stepIndex + 1)",
                    name: "observe",
                    arguments: [
                        "app": ctx.targetApp.map(JSONValue.string) ?? .null,
                        "screenshot": .bool(false),
                    ]
                )
            )
        }

        let candidates = makeCandidates(
            snapshot.elements,
            goal: ctx.goal,
            excludedLabels: ctx.excludedLabels.union(excludedLabels)
        )
        guard !candidates.isEmpty else {
            if canEscalate {
                return escalation("no accessible controls")
            }
            return makeFailure(
                "I can't see any controls in \(ctx.targetApp ?? "the current app")",
                step: ctx.stepIndex + 1
            )
        }

        let textToType = ctx.generatedText ?? SlotExtractor.typedText(from: ctx.goal)
        let hasMutation = ctx.history.contains {
            ["click", "click_at", "type_text", "press_key", "open_app"].contains($0.tool)
        }
        let clickedLabels: Set<String> = Set(ctx.history.compactMap { record -> String? in
            guard record.succeeded,
                  ["click", "click_at"].contains(record.tool),
                  let label = record.elementLabel else { return nil }
            return label
        })
        let workedBefore = (ctx.targetApp.map { hints.hints(app: $0, goal: ctx.goal) } ?? [])
            .filter { !clickedLabels.contains($0.label) }
        let workedBeforeDescriptions: [String] = workedBefore.map { hint in
            let role = promptRole(hint.role)
            return "click \(role) \"\(hint.label)\""
        }
        let previousActions = ctx.history.suffix(6).map {
            "\($0.tool) \($0.argsSummary) → \($0.resultText)"
        }
        let state: JSONValue = .object([
            "goal": .string(ctx.goal),
            "app": ctx.targetApp.map(JSONValue.string) ?? .null,
            "site": ctx.siteHost.map(JSONValue.string) ?? .null,
            "window_title": ctx.windowTitle.map(JSONValue.string) ?? .null,
            "previous_window_title": ctx.previousWindowTitle.map(JSONValue.string) ?? .null,
            "step": .number(Double(ctx.stepIndex)),
            "previous_actions": .array(previousActions.map(JSONValue.string)),
            "worked_before": .array(workedBeforeDescriptions.map(JSONValue.string)),
            "text_to_type": textToType.map(JSONValue.string) ?? .null,
            "text_is_generated": .bool(ctx.generatedText != nil),
            "elements": .array(candidates.map { candidate in
                .object([
                    "id": .string(candidate.id),
                    "role": .string(promptRole(candidate.element.role)),
                    "label": .string(String(candidate.element.label.prefix(80))),
                    "value": candidate.element.value.map { .string(String($0.prefix(40))) } ?? .null,
                    "matches_request": .bool(candidate.overlap > 0),
                ])
            }),
        ])
        var criteria: [String: String?] = Dictionary(uniqueKeysWithValues: candidates.map { candidate in
            let base = candidate.elementRoleIsText
                ? "Type `\(textToType ?? "")` into the \(promptRole(candidate.element.role)) labelled \"\(candidate.element.label)\""
                : "Click the \(promptRole(candidate.element.role)) labelled \"\(candidate.element.label)\""
            let hasWorkedBefore = workedBefore.contains {
                promptRole($0.role) == promptRole(candidate.element.role)
                    && $0.label == candidate.element.label
            }
            return (
                candidate.id,
                Optional(
                    [
                        candidate.overlap > 0 ? "\(base) — label matches the request" : base,
                        hasWorkedBefore ? "(worked before for a similar request)" : nil,
                    ]
                    .compactMap { $0 }
                    .joined(separator: " ")
                )
            )
        })
        criteria["press_return"] = "Press Return to submit what is focused"
        criteria["press_escape"] = "Close the current dialog or menu"
        criteria["scroll_down"] = "Scroll to reveal more controls"
        criteria["done"] = "The goal is already complete"
        criteria["stuck"] = "No listed element can advance the goal"
        let instructions = """
        The user said `\(ctx.goal)`. `elements` lists the controls currently visible in `\(ctx.targetApp ?? "the app")`; `previous_actions` are the steps already taken. \(ctx.siteHost.map { "The requested site is \($0). " } ?? "")Pick the single next action that moves the goal forward now. Pick `done` only if `elements` and `window_title` already show that the goal is completed. Pick `stuck` if no listed element can advance the goal.
        """
        let questions: [String: Question] = [
            "next_action": .choice(instructions: instructions, criteria: criteria),
            "goal_reached": .noul(
                instructions: "Do `elements` and `window_title` show that `\(ctx.goal)` has already been fully completed?"
            ),
            "wrong_surface": .noul(
                instructions: "Did the last action open a window or dialog (`window_title`) that is unrelated to `\(ctx.goal)` and should be closed to get back? `previous_window_title` is where we were before."
            ),
            "needs_text": .noul(
                instructions: "Does completing `\(ctx.goal)` require typing text that is not yet visible in `elements`?"
            ),
        ]
        let (response, latency) = try await client.systemOne(state: state, questions: questions)
        let choiceAnswer = response.answers["next_action"]
        let choice: String
        let confidence: Double
        let probabilities: [String: Double]
        if case .choice(let value, let answerConfidence, let answerProbabilities) = choiceAnswer {
            choice = value
            confidence = answerConfidence
            probabilities = answerProbabilities
        } else {
            choice = "stuck"
            confidence = 0
            probabilities = [:]
        }
        let goalReached: Double
        if case .noul(let value) = response.answers["goal_reached"] {
            goalReached = value
        } else {
            goalReached = 0
        }
        let needsText: Double
        if case .noul(let value) = response.answers["needs_text"] {
            needsText = value
        } else {
            needsText = 0
        }
        let wrongSurfaceNoul: Double
        if case .noul(let value) = response.answers["wrong_surface"] {
            wrongSurfaceNoul = value
        } else {
            wrongSurfaceNoul = 0
        }
        if let pendingTitle = wrongSurfaceTitle,
           ctx.windowTitle == pendingTitle,
           ctx.history.last?.tool == "press_key",
           ctx.history.last?.succeeded == true,
           recoveryCount < 2,
           !closeShortcutIssued {
            closeShortcutIssued = true
            recoveryCount += 1
            Log.agent.info("stage=recover reason=wrong_surface shortcut=command-w")
            return keyTurn(
                id: "jev-\(ctx.stepIndex + 1)",
                key: "w",
                modifiers: ["command"]
            )
        }
        if ctx.windowTitle != wrongSurfaceTitle {
            closeShortcutIssued = false
            if ctx.windowTitle != nil {
                wrongSurfaceTitle = nil
            }
        }
        let lastRecord = ctx.history.last
        let wrongSurfaceByRule: Bool = {
            guard let lastRecord,
                  lastRecord.succeeded,
                  lastRecord.tool == "click",
                  let previous = ctx.previousWindowTitle,
                  let current = ctx.windowTitle,
                  previous != current,
                  ["settings", "preferences", "about"].contains(where: {
                      current.localizedCaseInsensitiveContains($0)
                  }) else {
                return false
            }
            return GoalWords.words(ctx.goal).isDisjoint(with: ["settings", "preferences", "about"])
        }()
        if (wrongSurfaceNoul >= 0.7 || wrongSurfaceByRule),
           let label = lastRecord?.elementLabel,
           lastRecord?.succeeded == true,
           lastRecord?.tool == "click",
           recoveryCount < 2 {
            recoveryCount += 1
            excludedLabels.insert(label)
            wrongSurfaceTitle = ctx.windowTitle
            closeShortcutIssued = false
            Log.agent.info("stage=recover reason=wrong_surface label=\(label, privacy: .public)")
            return keyTurn(
                id: "jev-\(ctx.stepIndex + 1)",
                key: "escape",
                modifiers: []
            )
        }
        if (choice == "done" && confidence >= 0.5 || goalReached >= 0.7), hasMutation {
            if textToType != nil, ctx.typedTextVisible == false {
                return stuckTurn(
                    reason: "The typed text is not visible in the current field",
                    step: ctx.stepIndex + 1
                )
            }
            return makeTurn(call: DeepSeekToolCall(
                id: "jev-\(ctx.stepIndex + 1)",
                name: "done",
                arguments: ["summary": .string(summary(for: ctx.goal))]
            ))
        }
        Log.agent.info(
            "jev step latency=\(latency) choice=\(choice, privacy: .public) confidence=\(confidence)"
        )

        let fingerprint = snapshot.elements.map {
            "\($0.role)|\($0.label)|\($0.value ?? "")"
        }.joined(separator: "\n")
        if initialControlTexts == nil {
            initialControlTexts = Set(snapshot.elements.map {
                "\($0.role)|\($0.label)|\($0.value ?? "")"
            })
        }
        if hasMutation,
           let initialControlTexts,
           snapshot.elements.contains(where: { element in
               let key = "\(element.role)|\(element.label)|\(element.value ?? "")"
               guard !initialControlTexts.contains(key) else { return false }
               return !GoalWords.words(ctx.goal).isDisjoint(
                   with: GoalWords.words("\(element.label) \(element.value ?? "")")
               )
           }) {
            return makeTurn(call: DeepSeekToolCall(
                id: "jev-\(ctx.stepIndex + 1)",
                name: "done",
                arguments: ["summary": .string(summary(for: ctx.goal))]
            ))
        }
        if recentFingerprints.count >= 3,
           fingerprint == recentFingerprints[recentFingerprints.count - 2],
           recentFingerprints[recentFingerprints.count - 1]
                == recentFingerprints[recentFingerprints.count - 3] {
            return stuckTurn(
                reason: "The screen keeps toggling between two states",
                step: ctx.stepIndex + 1,
                preserveReason: true
            )
        }
        recentFingerprints.append(fingerprint)
        if recentFingerprints.count > 4 {
            recentFingerprints.removeFirst()
        }
        var selectedChoice = choice == "done" && goalReached < 0.7
            ? highestAlternative(probabilities: probabilities)
            : choice
        if let chosen = candidates.first(where: { $0.id == selectedChoice }),
           chosen.overlap == 0,
           !chosen.elementRoleIsText,
           confidence < 0.6,
           let reranked = candidates
            .filter({
                $0.overlap > 0
                    && Self.isRerankable(role: $0.element.role, label: $0.element.label)
            })
            .max(by: {
                (probabilities[$0.id] ?? 0) < (probabilities[$1.id] ?? 0)
            }) {
            selectedChoice = reranked.id
            Log.agent.info(
                "jev step rerank from=\(choice, privacy: .public) to=\(selectedChoice, privacy: .public)"
            )
        }
        let selectedCandidate = candidates.first { $0.id == selectedChoice }
        let selectedToken = selectedCandidate?.element.token
        let actionKey = "\(selectedChoice)|\(selectedToken ?? "")"
        if ["press_escape", "press_return", "scroll_down"].contains(selectedChoice),
           confidence < 0.5 {
            if actionKey == previousActionKey, fingerprint == previousFingerprint {
                return stuckTurn(
                    reason: "The same low-confidence choice repeated",
                    step: ctx.stepIndex + 1
                )
            }
            previousActionKey = actionKey
            previousFingerprint = fingerprint
            try await Task.sleep(nanoseconds: 700_000_000)
            Log.agent.info(
                "jev step defer choice=\(selectedChoice, privacy: .public) confidence=\(confidence)"
            )
            return makeTurn(call: DeepSeekToolCall(
                id: "jev-\(ctx.stepIndex + 1)",
                name: "observe",
                arguments: [
                    "app": ctx.targetApp.map(JSONValue.string) ?? .null,
                    "screenshot": .bool(false),
                ]
            ))
        }
        if let selectedCandidate,
           !selectedCandidate.elementRoleIsText,
           confidence < 0.45 {
            if actionKey == previousActionKey, fingerprint == previousFingerprint {
                return stuckTurn(
                    reason: "The same low-confidence click repeated",
                    step: ctx.stepIndex + 1
                )
            }
            previousActionKey = actionKey
            previousFingerprint = fingerprint
            try await Task.sleep(nanoseconds: 700_000_000)
            Log.agent.info(
                "jev step defer choice=\(selectedChoice, privacy: .public) confidence=\(confidence)"
            )
            return makeTurn(call: DeepSeekToolCall(
                id: "jev-\(ctx.stepIndex + 1)",
                name: "observe",
                arguments: [
                    "app": ctx.targetApp.map(JSONValue.string) ?? .null,
                    "screenshot": .bool(false),
                ]
            ))
        }
        if actionKey == previousActionKey, fingerprint == previousFingerprint {
            return stuckTurn(
                reason: "The same control did not change the screen",
                step: ctx.stepIndex + 1
            )
        }
        previousActionKey = actionKey
        previousFingerprint = fingerprint

        if confidence < 0.30 {
            return uncertainTurn(
                app: ctx.targetApp,
                step: ctx.stepIndex + 1
            )
        }
        if selectedChoice == "stuck" {
            if canEscalate { return escalation("Jev could not find a control to advance the goal") }
            return makeFailure(
                "I couldn't find a way to \(ctx.goal) in \(ctx.targetApp ?? "the app")",
                step: ctx.stepIndex + 1
            )
        }
        if let candidate = selectedCandidate {
            if candidate.elementRoleIsText {
                if let textToType {
                    return makeTurn(call: DeepSeekToolCall(
                        id: "jev-\(ctx.stepIndex + 1)",
                        name: "type_text",
                        arguments: [
                            "text": .string(textToType),
                            "element_token": .string(candidate.element.token),
                        ]
                    ))
                }
                if needsText >= 0.5 {
                    if canEscalate { return escalation("Jev needs text that was not in the request") }
                    return makeFailure(
                        "Tell me what to type, for example: type hello",
                        step: ctx.stepIndex + 1
                    )
                }
            }
            return makeTurn(call: DeepSeekToolCall(
                id: "jev-\(ctx.stepIndex + 1)",
                name: "click",
                arguments: ["element_token": .string(candidate.element.token)]
            ))
        }
        switch selectedChoice {
        case "press_return":
            return makeTurn(call: DeepSeekToolCall(
                id: "jev-\(ctx.stepIndex + 1)",
                name: "press_key",
                arguments: ["key": .string("return")]
            ))
        case "press_escape":
            return makeTurn(call: DeepSeekToolCall(
                id: "jev-\(ctx.stepIndex + 1)",
                name: "press_key",
                arguments: ["key": .string("escape")]
            ))
        case "scroll_down":
            return makeTurn(call: DeepSeekToolCall(
                id: "jev-\(ctx.stepIndex + 1)",
                name: "press_key",
                arguments: ["key": .string("pagedown")]
            ))
        default:
            if canEscalate { return escalation("Jev chose an unavailable control") }
            return makeFailure(
                "I'm not sure which control does that in \(ctx.targetApp ?? "the app")",
                step: ctx.stepIndex + 1
            )
        }
    }

    private func makeCandidates(
        _ elements: [CuaElement],
        goal: String,
        excludedLabels: Set<String>
    ) -> [Candidate] {
        let textRoles = Set(["AXTextField", "AXTextArea", "AXSearchField"])
        let interactiveCount = elements.filter {
            interactiveRoles.contains($0.role)
                && (!$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || textRoles.contains($0.role))
        }.count
        let includeExtras = interactiveCount < 8
        var seen = Set<String>()
        let selected = elements.filter { element in
            guard !excludedLabels.contains(element.label) else { return false }
            let hasLabel = !element.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let isInteractive = interactiveRoles.contains(element.role)
                && (hasLabel || textRoles.contains(element.role))
            guard isInteractive || (includeExtras && hasLabel) else { return false }
            let key = "\(element.role)|\(element.label)|\(element.value ?? "")"
            return seen.insert(key).inserted
        }.prefix(200)
        let goalWords = GoalWords.words(goal)
        var ranked: [RankedCandidate] = []
        for (index, element) in selected.enumerated() {
            let labelAndValue = "\(element.label) \(element.value ?? "")"
            let overlap = goalWords.intersection(GoalWords.words(labelAndValue)).count
            ranked.append(RankedCandidate(
                originalIndex: index,
                element: element,
                overlap: overlap
            ))
        }
        ranked.sort {
            $0.overlap != $1.overlap
                ? $0.overlap > $1.overlap
                : $0.originalIndex < $1.originalIndex
        }
        return ranked.enumerated().map { index, item in
            Candidate(id: "e\(index + 1)", element: item.element, overlap: item.overlap)
        }
    }

    private func makeTurn(call: DeepSeekToolCall) -> PlannerTurn {
        PlannerTurn(
            assistant: DeepSeekMessage(
                role: "assistant",
                content: nil,
                name: nil,
                toolCallID: nil,
                toolCalls: [call]
            ),
            toolCalls: [call]
        )
    }

    private func escalation(_ reason: String) -> PlannerTurn {
        PlannerTurn(
            assistant: DeepSeekMessage(
                role: "assistant",
                content: nil,
                name: nil,
                toolCallID: nil,
                toolCalls: nil
            ),
            toolCalls: [],
            escalation: .toDeepSeek(reason: reason)
        )
    }

    private func makeFailure(_ reason: String, step: Int) -> PlannerTurn {
        makeTurn(call: DeepSeekToolCall(
            id: "jev-\(step)",
            name: "fail",
            arguments: ["reason": .string(reason)]
        ))
    }

    private func stuckTurn(
        reason: String,
        step: Int,
        preserveReason: Bool = false
    ) -> PlannerTurn {
        if canEscalate { return escalation(reason) }
        return makeFailure(preserveReason ? reason : "I couldn't make progress", step: step)
    }

    private func uncertainTurn(app: String?, step: Int) -> PlannerTurn {
        if canEscalate { return escalation("low confidence in the next control") }
        return makeFailure(
            "I'm not sure which control does that in \(app ?? "the app")",
            step: step
        )
    }

    private func keyTurn(id: String, key: String, modifiers: [String]) -> PlannerTurn {
        makeTurn(call: DeepSeekToolCall(
            id: id,
            name: "press_key",
            arguments: [
                "key": .string(key),
                "modifiers": .array(modifiers.map(JSONValue.string)),
            ]
        ))
    }

    private func highestAlternative(probabilities: [String: Double]) -> String {
        probabilities
            .filter { $0.key != "done" && $0.key != "stuck" }
            .max { $0.value < $1.value }?.key ?? "stuck"
    }

    private func promptRole(_ role: String) -> String {
        if role == "AXStaticText" {
            return "text"
        }
        return role.replacingOccurrences(of: "AX", with: "").lowercased()
    }

    private func summary(for goal: String) -> String {
        let words = goal.split(whereSeparator: { $0.isWhitespace }).prefix(14)
        return "Done: \(words.joined(separator: " "))"
    }
}
