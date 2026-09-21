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

#if compiler(>=6.2)
    func testStreamingEngineIsCompiledIntoCurrentToolchain() {
        XCTAssertTrue(SpeechEngineKind.streamingCompiledIn)
    }

    func testSpeechAnalyzerStartsInputSequenceOnlyOnce() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/JevVoice/SpeechAnalyzerEngine.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let normalized = source
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\t", with: "")
            .replacingOccurrences(of: "\n", with: "")
        XCTAssertFalse(normalized.contains("SpeechAnalyzer(inputSequence:"))
        XCTAssertEqual(normalized.components(separatedBy: "start(inputSequence:").count - 1, 1)
    }

    func testRestartWaitsForPreviousAnalyzerFinish() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/JevVoice/SpeechAnalyzerEngine.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertTrue(source.contains("start waiting for previous finish"))
        XCTAssertTrue(source.contains("await previousFinish.value"))
        XCTAssertTrue(source.contains("let shouldFinish = self.finishing"))
        XCTAssertTrue(source.contains("if shouldFinish"))
    }
#endif

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
