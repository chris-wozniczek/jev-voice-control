import XCTest
@testable import JevVoiceCore

final class ExecutionPolicyTests: XCTestCase {
    func testRunsSafeHighConfidenceDecision() {
        let decision = Decision(
            clause: "open chrome", action: .openApp,
            targetApp: "Google Chrome", confidence: 0.95
        )
        XCTAssertEqual(
            ExecutionPolicy.verdict(for: [decision], alwaysConfirm: false), .run
        )
    }

    func testConfirmsWhenAlwaysConfirmIsEnabled() {
        let decision = Decision(clause: "mute", action: .system, confidence: 0.9)
        XCTAssertEqual(
            ExecutionPolicy.verdict(for: [decision], alwaysConfirm: true),
            .confirm(reason: "Ask before running is on")
        )
    }

    func testConfirmsAmbiguousApp() {
        let decision = Decision(
            clause: "open chrome", action: .openApp,
            targetApp: "Google Chrome",
            targetAppProbabilities: ["Google Chrome": 0.5, "Chrome Remote Desktop": 0.5],
            confidence: 0.5
        )
        XCTAssertEqual(
            ExecutionPolicy.verdict(for: [decision], alwaysConfirm: false),
            .confirm(reason: "Ambiguous app: Chrome Remote Desktop or Google Chrome")
        )
    }

    func testRejectsMissingApp() {
        let decision = Decision(clause: "maximize", action: .maximizeApp, confidence: 0.9)
        XCTAssertEqual(
            ExecutionPolicy.verdict(for: [decision], alwaysConfirm: false),
            .reject(reason: "I didn't catch which app")
        )
    }

    func testCautionRunsAutomatically() {
        let decision = Decision(
            clause: "close chrome", action: .closeApp,
            targetApp: "Google Chrome", confidence: 0.95
        )
        XCTAssertEqual(
            ExecutionPolicy.verdict(for: [decision], alwaysConfirm: false), .run
        )
        XCTAssertEqual(decision.riskTier, .caution)
    }

    func testDestructiveDecisionRequiresConfirmation() {
        let decision = Decision(
            clause: "submit the order",
            action: .uiTask,
            destructive: true,
            confidence: 0.9
        )
        XCTAssertEqual(
            ExecutionPolicy.verdict(for: [decision], alwaysConfirm: false),
            .confirm(reason: "This sounds hard to undo — confirm?")
        )
    }

    func testLowConfidenceUITaskRunsWithoutConfirmation() {
        let decision = Decision(
            clause: "click the new session button",
            action: .uiTask,
            confidence: 0.3
        )
        XCTAssertEqual(
            ExecutionPolicy.verdict(for: [decision], alwaysConfirm: false),
            .run
        )
    }
}
