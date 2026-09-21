import XCTest
@testable import JevVoiceCore

final class EndOfTurnPolicyTests: XCTestCase {
    func testFinalizeBoundary() {
        XCTAssertEqual(
            EndOfTurnPolicy.decide(probability: 0.75, silenceTimeout: 2.5),
            .finalize
        )
    }

    func testWaitBoundaryUsesMinimum() {
        XCTAssertEqual(
            EndOfTurnPolicy.decide(probability: 0.35, silenceTimeout: 2.5),
            .wait(4)
        )
        XCTAssertEqual(
            EndOfTurnPolicy.decide(probability: 0.2, silenceTimeout: 5),
            .wait(5)
        )
    }

    func testMiddleProbabilityUsesExistingTimer() {
        XCTAssertEqual(
            EndOfTurnPolicy.decide(probability: 0.5, silenceTimeout: 2.5),
            .timer
        )
    }
}
