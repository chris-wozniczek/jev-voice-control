import XCTest
@testable import JevVoiceCore

final class SilenceGateTests: XCTestCase {
    func testSameTextOnlyReschedulesOnce() {
        var gate = SilenceGate()
        XCTAssertTrue(gate.shouldReschedule(partial: "Open Chrome"))
        XCTAssertFalse(gate.shouldReschedule(partial: "open chrome"))
    }

    func testChangedTextReschedules() {
        var gate = SilenceGate()
        XCTAssertTrue(gate.shouldReschedule(partial: "Open"))
        XCTAssertTrue(gate.shouldReschedule(partial: "Open Chrome"))
    }

    func testPunctuationOnlyChangeDoesNotReschedule() {
        var gate = SilenceGate()
        XCTAssertTrue(gate.shouldReschedule(partial: "Open Chrome"))
        XCTAssertFalse(gate.shouldReschedule(partial: "Open Chrome!"))
    }
}
