import XCTest
@testable import JevVoiceCore

final class SafetyPolicyTests: XCTestCase {
    private let policy = SafetyPolicy(
        blocked: [
            .init(pattern: #"\b(rm -rf|sudo)\b"#, reason: "shell commands are blocked")
        ],
        confirm: ["delete", "close all"],
        confirmInBrowser: ["send"]
    )

    func testBlockedPatternRejects() {
        XCTAssertEqual(
            policy.verdict(for: "please run sudo rm -rf cache"),
            .reject(reason: "shell commands are blocked")
        )
    }

    func testBrowserConfirmWordIsScoped() {
        XCTAssertNil(policy.verdict(for: "send the message"))
        XCTAssertEqual(
            policy.verdict(for: "send the message", inBrowser: true),
            .confirm(reason: "This will send — confirm?")
        )
    }

    func testBenignTranscriptIsUnchanged() {
        XCTAssertNil(policy.verdict(for: "open the settings window"))
    }

    func testOldPolicyWithoutBrowserConfirmWordsDecodes() throws {
        let data = Data(#"{"blocked":[],"confirm":["delete"]}"#.utf8)
        let decoded = try SafetyPolicy.load(from: data)
        XCTAssertEqual(decoded.confirmInBrowser, [])
    }
}
