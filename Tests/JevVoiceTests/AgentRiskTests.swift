import XCTest
@testable import JevVoice

final class AgentRiskTests: XCTestCase {
    func testPostLabelIsRisky() {
        XCTAssertFalse(AgentRisk.matchesDestructiveWord("Post"))
        XCTAssertTrue(AgentRisk.matchesBrowserRisk("Post"))
    }

    func testComposeGoalIsNotRisky() {
        XCTAssertFalse(AgentRisk.matchesDestructiveGoal("compose a post"))
        XCTAssertTrue(AgentRisk.matchesBrowserGoal("post a message"))
    }
}
