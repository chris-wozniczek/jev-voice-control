import XCTest
@testable import JevVoiceCore

final class TranscriptNormalizerTests: XCTestCase {
    func testSplitsGluedHosts() {
        XCTAssertEqual(TranscriptNormalizer.normalize("openx.com"), "open x.com")
        XCTAssertEqual(TranscriptNormalizer.normalize("Open websitex.com"), "Open x.com")
        XCTAssertEqual(TranscriptNormalizer.normalize("gotox.com"), "go to x.com")
    }

    func testPreservesRealHostAfterVerb() {
        XCTAssertEqual(
            TranscriptNormalizer.normalize("open openx.com"),
            "open openx.com"
        )
        XCTAssertEqual(
            TranscriptNormalizer.normalize("open notes"),
            "open notes"
        )
    }

    func testSplitsGluedHostWithinSentence() {
        XCTAssertEqual(
            TranscriptNormalizer.normalize("please visitx.com now"),
            "please visit x.com now"
        )
    }
}
