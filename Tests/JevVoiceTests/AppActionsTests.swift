import XCTest
@testable import JevVoice

final class AppActionsTests: XCTestCase {
    func testRegistryMatchesSpecificAndWildcardActions() {
        let registry = AppActionRegistry(
            bundledActions: [
                AppAction(
                    app: "Devin",
                    bundleId: nil,
                    name: "new session",
                    phrases: ["new session", "start a session"],
                    steps: [.key(key: "n", modifiers: ["command"])]
                ),
                AppAction(
                    app: "*",
                    bundleId: nil,
                    name: "new tab",
                    phrases: ["new tab"],
                    steps: [.key(key: "t", modifiers: ["command"])]
                ),
            ],
            userActions: []
        )

        XCTAssertEqual(
            registry.match(goal: "start a new session", appName: "Devin", bundleId: nil)?.name,
            "new session"
        )
        XCTAssertNil(registry.match(goal: "new session", appName: "Notes", bundleId: nil))
        XCTAssertEqual(
            registry.match(goal: "new tab", appName: "Safari", bundleId: nil)?.name,
            "new tab"
        )
    }

    func testRegistryRejectsCompoundAndUnboundedPhrases() {
        let registry = AppActionRegistry(
            bundledActions: [
                AppAction(
                    app: "Devin",
                    bundleId: nil,
                    name: "new session",
                    phrases: ["new session"],
                    steps: [.key(key: "n", modifiers: ["command"])]
                ),
                AppAction(
                    app: "*",
                    bundleId: nil,
                    name: "new tab",
                    phrases: ["new tab"],
                    steps: [.key(key: "t", modifiers: ["command"])]
                ),
            ],
            userActions: []
        )

        XCTAssertNil(
            registry.match(
                goal: "new session and type hello world please",
                appName: "Devin",
                bundleId: nil
            )
        )
        XCTAssertNil(
            registry.match(goal: "renew tabulation", appName: "Safari", bundleId: nil)
        )
    }

    func testUserActionOverridesBundledAction() {
        let registry = AppActionRegistry(
            bundledActions: [
                AppAction(
                    app: "Devin",
                    bundleId: nil,
                    name: "new session",
                    phrases: ["new session"],
                    steps: [.key(key: "n", modifiers: ["command"])]
                ),
            ],
            userActions: [
                AppAction(
                    app: "devin",
                    bundleId: nil,
                    name: "New Session",
                    phrases: ["new session"],
                    steps: [.key(key: "s", modifiers: ["command", "shift"])]
                ),
            ]
        )

        XCTAssertEqual(registry.actions.count, 1)
        XCTAssertEqual(
            registry.match(goal: "new session", appName: "Devin", bundleId: nil)?.steps,
            [.key(key: "s", modifiers: ["command", "shift"])]
        )
    }

    func testSpecificActionWinsOverWildcard() {
        let registry = AppActionRegistry(
            bundledActions: [
                AppAction(
                    app: "Devin",
                    bundleId: nil,
                    name: "new session",
                    phrases: ["new session"],
                    steps: [.key(key: "n", modifiers: ["command"])]
                ),
                AppAction(
                    app: "*",
                    bundleId: nil,
                    name: "new session",
                    phrases: ["new session"],
                    steps: [.key(key: "s", modifiers: ["command"])]
                ),
            ],
            userActions: []
        )

        XCTAssertEqual(
            registry.match(goal: "in Devin, new session", appName: "Devin", bundleId: nil)?.app,
            "Devin"
        )
    }

    func testBundledActionsDecode() {
        XCTAssertGreaterThanOrEqual(AppActionRegistry.shared.actions.count, 5)
    }

    @MainActor
    func testFastPathObservesThenPressesKeysThenDelegates() async throws {
        let inner = StubPlanner()
        let action = AppAction(
            app: "Devin",
            bundleId: nil,
            name: "new session",
            phrases: ["new session"],
            steps: [.key(key: "n", modifiers: ["command"])]
        )
        let planner = FastPathPlanner(action: action, inner: inner)

        let observe = try await planner.next(
            PlannerContext(goal: "new session", targetApp: "Devin")
        )
        XCTAssertEqual(observe.toolCalls.first?.name, "observe")
        XCTAssertEqual(observe.toolCalls.first?.arguments["app"]?.stringValue, "Devin")
        XCTAssertEqual(observe.escalation, .none)

        let press = try await planner.next(PlannerContext(
            goal: "new session",
            targetApp: "Devin",
            history: [
                PlannerStepRecord(
                    tool: "observe",
                    argsSummary: "",
                    resultText: "observed",
                    succeeded: true
                ),
            ]
        ))
        XCTAssertEqual(press.toolCalls.first?.name, "press_key")
        XCTAssertEqual(press.toolCalls.first?.arguments["key"]?.stringValue, "n")
        XCTAssertEqual(
            press.toolCalls.first?.arguments["modifiers"]?.arrayValue?.compactMap(\.stringValue),
            ["command"]
        )

        let delegated = try await planner.next(PlannerContext(
            goal: "new session",
            targetApp: "Devin",
            history: [
                PlannerStepRecord(
                    tool: "observe",
                    argsSummary: "",
                    resultText: "observed",
                    succeeded: true
                ),
                PlannerStepRecord(
                    tool: "press_key",
                    argsSummary: "key=n",
                    resultText: "Pressed n",
                    succeeded: true
                ),
            ]
        ))
        XCTAssertEqual(delegated.toolCalls.first?.name, "done")
        XCTAssertEqual(inner.calls, 1)
    }

    @MainActor
    func testFastPathDelegatesAfterFailure() async throws {
        let inner = StubPlanner()
        let action = AppAction(
            app: "Devin",
            bundleId: nil,
            name: "new session",
            phrases: ["new session"],
            steps: [.key(key: "n", modifiers: ["command"])]
        )
        let planner = FastPathPlanner(action: action, inner: inner)

        let turn = try await planner.next(PlannerContext(
            goal: "new session",
            targetApp: "Devin",
            history: [
                PlannerStepRecord(
                    tool: "observe",
                    argsSummary: "",
                    resultText: "failed",
                    succeeded: false
                ),
            ]
        ))
        XCTAssertEqual(turn.toolCalls.first?.name, "done")
        XCTAssertEqual(inner.calls, 1)
    }
}

@MainActor
private final class StubPlanner: ActionPlanner {
    var calls = 0

    func next(_ ctx: PlannerContext) async throws -> PlannerTurn {
        calls += 1
        let call = DeepSeekToolCall(
            id: "inner-\(calls)",
            name: "done",
            arguments: ["summary": .string("delegated")]
        )
        return PlannerTurn(
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
}
