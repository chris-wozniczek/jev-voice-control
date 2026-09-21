import Foundation

@MainActor
final class FastPathPlanner: ActionPlanner {
    private struct Fingerprint {
        let windowTitle: String?
        let labels: Set<String>
    }

    private let action: AppAction
    private let inner: ActionPlanner
    private var initialFingerprint: Fingerprint?
    private var unchangedPolls = 0
    private var menuRetryIssued = false

    init(action: AppAction, inner: ActionPlanner) {
        self.action = action
        self.inner = inner
    }

    func next(_ ctx: PlannerContext) async throws -> PlannerTurn {
        guard !ctx.history.contains(where: { !$0.succeeded }) else {
            return try await inner.next(ctx)
        }
        guard !ctx.history.isEmpty else {
            return observeTurn(ctx)
        }
        guard ctx.history.first?.tool == "observe",
              ctx.history.dropFirst().allSatisfy({
                  $0.tool == "press_key" || $0.tool == "observe"
              }) else {
            return try await inner.next(ctx)
        }
        if initialFingerprint == nil, let snapshot = ctx.snapshot {
            initialFingerprint = Fingerprint(
                windowTitle: ctx.windowTitle,
                labels: Set(snapshot.elements.map { "\($0.role)|\($0.label)" })
            )
        }
        let pressCount = ctx.history.dropFirst().filter { $0.tool == "press_key" }.count
        let stepIndex = pressCount
        guard stepIndex < action.steps.count else {
            if let initialFingerprint,
               let snapshot = ctx.snapshot {
                let latestLabels = Set(snapshot.elements.map { "\($0.role)|\($0.label)" })
                let titleChanged = initialFingerprint.windowTitle != ctx.windowTitle
                let distance = Self.jaccardDistance(initialFingerprint.labels, latestLabels)
                let elementsChanged = distance >= 0.3
                if titleChanged || elementsChanged {
                    let change = titleChanged ? "title" : "elements"
                    Log.agent.info(
                        "fastpath verified action=\(self.action.name, privacy: .public) app=\(self.action.app, privacy: .public) change=\(change, privacy: .public)"
                    )
                    return makeTurn(DeepSeekToolCall(
                        id: "fastpath-\(ctx.stepIndex + 1)",
                        name: "done",
                        arguments: [
                            "summary": .string("\(action.name) in \(action.app)"),
                        ]
                    ))
                }
                if unchangedPolls < 3 {
                    unchangedPolls += 1
                    try await Task.sleep(nanoseconds: 700_000_000)
                    Log.agent.info(
                        "fastpath poll n=\(self.unchangedPolls, privacy: .public)"
                    )
                    return observeTurn(ctx)
                }
                if !menuRetryIssued,
                   let lastStep = action.steps.last,
                   case .key(let key, let modifiers) = lastStep,
                   modifiers.contains(where: { $0.caseInsensitiveCompare("command") == .orderedSame }) {
                    menuRetryIssued = true
                    Log.agent.info(
                        "fastpath retry menu action=\(self.action.name, privacy: .public)"
                    )
                    return makeTurn(DeepSeekToolCall(
                        id: "fastpath-\(ctx.stepIndex + 1)",
                        name: "press_key",
                        arguments: [
                            "key": .string(key),
                            "modifiers": .array(modifiers.map(JSONValue.string)),
                            "via_menu": .bool(true),
                        ]
                    ))
                }
            }
            return try await inner.next(ctx)
        }
        guard case .key(let key, let modifiers) = action.steps[stepIndex] else {
            return try await inner.next(ctx)
        }
        Log.agent.info(
            "fastpath action=\(self.action.name, privacy: .public) app=\(self.action.app, privacy: .public) step=\(stepIndex + 1)"
        )
        return makeTurn(
            DeepSeekToolCall(
                id: "fastpath-\(ctx.stepIndex + 1)",
                name: "press_key",
                arguments: [
                    "key": .string(key),
                    "modifiers": .array(modifiers.map(JSONValue.string)),
                ]
            )
        )
    }

    private func observeTurn(_ ctx: PlannerContext) -> PlannerTurn {
        makeTurn(
            DeepSeekToolCall(
                id: "fastpath-\(ctx.stepIndex + 1)",
                name: "observe",
                arguments: [
                    "app": ctx.targetApp.map(JSONValue.string) ?? .null,
                    "screenshot": .bool(false),
                ]
            )
        )
    }

    private static func jaccardDistance(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
        let union = lhs.union(rhs)
        guard !union.isEmpty else { return 0 }
        return 1 - Double(lhs.intersection(rhs).count) / Double(union.count)
    }

    private func makeTurn(_ call: DeepSeekToolCall) -> PlannerTurn {
        PlannerTurn(
            assistant: DeepSeekMessage(
                role: "assistant",
                content: nil,
                name: nil,
                toolCallID: nil,
                toolCalls: [call]
            ),
            toolCalls: [call],
            escalation: .none
        )
    }
}
