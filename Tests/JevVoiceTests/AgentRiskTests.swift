import XCTest
@testable import JevVoice

final class AgentRiskTests: XCTestCase {
    func testPostLabelIsRisky() {
        XCTAssertTrue(AgentRisk.matchesDestructiveWord("Post"))
    }

    func testComposeGoalIsNotRisky() {
        XCTAssertFalse(AgentRisk.matchesDestructiveGoal("compose a post"))
    }
}
