import XCTest
@testable import JevVoiceCore

final class GoalWordsTests: XCTestCase {
    func testDropsStopWordsAndAddsNaiveSingular() {
        XCTAssertEqual(
            GoalWords.words("change the models"),
            Set(["models", "model"])
        )
    }

    func testSplitsOnPunctuationAndDropsShortWords() {
        XCTAssertEqual(
            GoalWords.words("Pick x.com in My App"),
            Set(["com", "app"])
        )
    }

    func testSubmitIntent() {
        XCTAssertTrue(SubmitIntent.matches(goal: "send it"))
        XCTAssertTrue(SubmitIntent.matches(goal: "submit the form"))
        XCTAssertTrue(SubmitIntent.matches(goal: "press enter"))
        XCTAssertFalse(SubmitIntent.matches(goal: "send a message to Bob on Slack"))
        XCTAssertFalse(SubmitIntent.matches(goal: "post notifications"))
        XCTAssertFalse(SubmitIntent.matches(goal: "open the send dialog"))
    }
}
