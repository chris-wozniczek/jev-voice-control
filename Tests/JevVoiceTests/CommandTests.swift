import XCTest
@testable import JevVoiceCore

final class CommandTests: XCTestCase {
    func testDestructiveDecisionHasDestructiveRiskTier() {
        let decision = Decision(
            clause: "delete the message",
            action: .uiTask,
            destructive: true
        )

        XCTAssertEqual(decision.riskTier, .destructive)
    }

    func testUITaskExecutionSummaryIncludesTargetAndClause() {
        let decision = Decision(
            clause: "start a new session",
            action: .uiTask,
            targetApp: "Devin"
        )

        XCTAssertEqual(
            decision.executionSummary,
            "In Devin: start a new session"
        )
    }
}
