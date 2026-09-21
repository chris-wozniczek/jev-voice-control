import XCTest
@testable import JevVoice

final class SpeechAnalyzerEngineTests: XCTestCase {
    func testDefaultEngineKindUsesStreamingAvailability() {
        XCTAssertEqual(
            SpeechEngineKind.defaultKind(streamingAvailable: true),
            .appleStreaming
        )
        XCTAssertEqual(
            SpeechEngineKind.defaultKind(streamingAvailable: false),
            .apple
        )
    }

    func testAssembleFinalIncludesLastVolatileText() throws {
        guard #available(macOS 26, *) else {
            throw XCTSkip("SpeechAnalyzer requires macOS 26")
        }
        XCTAssertEqual(
            SpeechAnalyzerEngine.assembleFinal(finalized: "hello", volatile: "world"),
            "hello world"
        )
        XCTAssertEqual(
            SpeechAnalyzerEngine.assembleFinal(finalized: "", volatile: "world"),
            "world"
        )
    }
}
