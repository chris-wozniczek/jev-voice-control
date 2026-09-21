import XCTest
@testable import JevVoiceCore

final class SafetyPolicyTests: XCTestCase {
    private let policy = SafetyPolicy(
        blocked: [
            .init(pattern: #"\b(rm -rf|sudo)\b"#, reason: "shell commands are blocked")
        ],
        confirm: ["send", "close all"]
    )

    func testBlockedPatternRejects() {
        XCTAssertEqual(
            policy.verdict(for: "please run sudo rm -rf cache"),
            .reject(reason: "shell commands are blocked")
        )
    }

    func testConfirmWordConfirms() {
        XCTAssertEqual(
            policy.verdict(for: "send the message"),
            .confirm(reason: "send— confirm?")
        )
    }

    func testBenignTranscriptIsUnchanged() {
        XCTAssertNil(policy.verdict(for: "open the settings window"))
    }
}
