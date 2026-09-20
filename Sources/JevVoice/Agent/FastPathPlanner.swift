import Foundation

@MainActor
final class FastPathPlanner: ActionPlanner {
    private let action: AppAction
    private let inner: ActionPlanner

    init(action: AppAction, inner: ActionPlanner) {
        self.action = action
        self.inner = inner
    }

    func next(_ ctx: PlannerContext) async throws -> PlannerTurn {
        guard !ctx.history.contains(where: { !$0.succeeded }) else {
            return try await inner.next(ctx)
        }
        guard !ctx.history.isEmpty else {
            return makeTurn(
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
        guard ctx.history.first?.tool == "observe",
              ctx.history.dropFirst().allSatisfy({ $0.tool == "press_key" }) else {
            return try await inner.next(ctx)
        }
        let stepIndex = ctx.history.dropFirst().count
        guard stepIndex < action.steps.count else {
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
