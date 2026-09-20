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
}
