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
    private struct Candidate {
        let id: String
        let element: CuaElement

        var elementRoleIsText: Bool {
            element.role == "AXTextField" || element.role == "AXTextArea"
        }
    }

    private let client: JevAnswering
    private let canEscalate: Bool
    private var previousActionKey: String?
    private var previousFingerprint: String?

    private let interactiveRoles: Set<String> = [
        "AXButton", "AXLink", "AXTextField", "AXTextArea", "AXMenuItem",
        "AXTab", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXComboBox",
        "AXRow", "AXCell",
    ]

    init(client: JevAnswering, canEscalate: Bool) {
        self.client = client
        self.canEscalate = canEscalate
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

        let candidates = makeCandidates(snapshot.elements)
        guard !candidates.isEmpty else {
            if canEscalate {
                return escalation("no accessible controls")
            }
            return makeFailure(
                "I can't see any controls in \(ctx.targetApp ?? "the current app")",
                step: ctx.stepIndex + 1
            )
        }

        let textToType = SlotExtractor.typedText(from: ctx.goal)
        let previousActions = ctx.history.suffix(6).map {
            "\($0.tool) \($0.argsSummary) → \($0.resultText)"
        }
        let state: JSONValue = .object([
            "goal": .string(ctx.goal),
            "app": ctx.targetApp.map(JSONValue.string) ?? .null,
            "window_title": ctx.windowTitle.map(JSONValue.string) ?? .null,
            "step": .number(Double(ctx.stepIndex)),
            "previous_actions": .array(previousActions.map(JSONValue.string)),
            "text_to_type": textToType.map(JSONValue.string) ?? .null,
            "elements": .array(candidates.map { candidate in
                .object([
                    "id": .string(candidate.id),
                    "role": .string(promptRole(candidate.element.role)),
                    "label": .string(String(candidate.element.label.prefix(80))),
                    "value": candidate.element.value.map { .string(String($0.prefix(40))) } ?? .null,
                ])
            }),
        ])
        var criteria = Dictionary(uniqueKeysWithValues: candidates.map { candidate in
            (
                candidate.id,
                Optional(
                    candidate.elementRoleIsText
                        ? "Type `\(textToType ?? "")` into the \(promptRole(candidate.element.role)) labelled \"\(candidate.element.label)\""
                        : "Click the \(promptRole(candidate.element.role)) labelled \"\(candidate.element.label)\""
                )
            )
        })
        criteria["press_return"] = "Press Return to submit what is focused"
        criteria["press_escape"] = "Close the current dialog or menu"
        criteria["scroll_down"] = "Scroll to reveal more controls"
        criteria["done"] = "The goal is already complete"
        criteria["stuck"] = "No listed element can advance the goal"
        let instructions = """
        The user said `\(ctx.goal)`. `elements` lists the controls currently visible in `\(ctx.targetApp ?? "the app")`; `previous_actions` are the steps already taken. Pick the single next action that moves the goal forward now. Pick `done` only if `elements` and `window_title` already show that the goal is completed. Pick `stuck` if no listed element can advance the goal.
        """
        let questions: [String: Question] = [
            "next_action": .choice(instructions: instructions, criteria: criteria),
            "goal_reached": .noul(
                instructions: "Do `elements` and `window_title` show that `\(ctx.goal)` has already been fully completed?"
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
        Log.agent.info(
            "jev step latency=\(latency) choice=\(choice, privacy: .public) confidence=\(confidence)"
        )

        let fingerprint = snapshot.elements.map {
            "\($0.role)|\($0.label)|\($0.value ?? "")"
        }.joined(separator: "\n")
        let selectedChoice = choice == "done" && goalReached < 0.7
            ? highestAlternative(probabilities: probabilities)
            : choice
        let selectedCandidate = candidates.first { $0.id == selectedChoice }
        let selectedToken = selectedCandidate?.element.token
        let actionKey = "\(selectedChoice)|\(selectedToken ?? "")"
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
        if goalReached >= 0.7,
           ctx.history.contains(where: { ["click", "click_at", "type_text", "press_key", "open_app"].contains($0.tool) }) {
            return makeTurn(call: DeepSeekToolCall(
                id: "jev-\(ctx.stepIndex + 1)",
                name: "done",
                arguments: ["summary": .string(summary(for: ctx.goal))]
            ))
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

    private func makeCandidates(_ elements: [CuaElement]) -> [Candidate] {
        let textRoles = Set(["AXTextField", "AXTextArea"])
        let interactiveCount = elements.filter {
            interactiveRoles.contains($0.role)
                && (!$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || textRoles.contains($0.role))
        }.count
        let includeExtras = interactiveCount < 8
        var seen = Set<String>()
        let selected = elements.filter { element in
            let hasLabel = !element.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let isInteractive = interactiveRoles.contains(element.role)
                && (hasLabel || textRoles.contains(element.role))
            guard isInteractive || (includeExtras && hasLabel) else { return false }
            let key = "\(element.role)|\(element.label)|\(element.value ?? "")"
            return seen.insert(key).inserted
        }.prefix(200)
        return selected.enumerated().map { index, element in
            Candidate(id: "e\(index + 1)", element: element)
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

    private func stuckTurn(reason: String, step: Int) -> PlannerTurn {
        if canEscalate { return escalation(reason) }
        return makeFailure("I couldn't make progress", step: step)
    }

    private func uncertainTurn(app: String?, step: Int) -> PlannerTurn {
        if canEscalate { return escalation("low confidence in the next control") }
        return makeFailure(
            "I'm not sure which control does that in \(app ?? "the app")",
            step: step
        )
    }

    private func highestAlternative(probabilities: [String: Double]) -> String {
        probabilities
            .filter { $0.key != "done" && $0.key != "stuck" }
            .max { $0.value < $1.value }?.key ?? "stuck"
    }

    private func promptRole(_ role: String) -> String {
        role.replacingOccurrences(of: "AX", with: "").lowercased()
    }

    private func summary(for goal: String) -> String {
        let words = goal.split(whereSeparator: { $0.isWhitespace }).prefix(14)
        return "Done: \(words.joined(separator: " "))"
    }
}
