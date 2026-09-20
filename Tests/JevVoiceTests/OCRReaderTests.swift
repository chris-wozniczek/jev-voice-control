import CoreGraphics
import XCTest
@testable import JevVoice

final class OCRReaderTests: XCTestCase {
    func testMapsVisionCoordinatesToScreenCoordinates() {
        let frame = CGRect(x: 100, y: 200, width: 800, height: 600)
        let hits = OCRReader.hits(
            from: [
                OCRObservation(
                    text: "Open",
                    box: CGRect(x: 0.5, y: 0.5, width: 0.1, height: 0.05),
                    confidence: 0.9
                )
            ],
            windowFrame: frame
        )
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].point.x, 540, accuracy: 0.001)
        XCTAssertEqual(hits[0].point.y, 485, accuracy: 0.001)
        XCTAssertEqual(hits[0].element.token, "ocr:1")
        XCTAssertEqual(hits[0].element.role, "AXStaticText")
        XCTAssertEqual(hits[0].element.label, "Open")
    }

    func testSkipsLowConfidenceAndShortTextAndTrimsWhitespace() {
        let hits = OCRReader.hits(
            from: [
                OCRObservation(text: "low", box: .zero, confidence: 0.29),
                OCRObservation(text: "x", box: .zero, confidence: 0.9),
                OCRObservation(text: "  OK  ", box: .zero, confidence: 0.9),
            ],
            windowFrame: CGRect(x: 0, y: 0, width: 100, height: 100)
        )
        XCTAssertEqual(hits.map(\.element.label), ["OK"])
    }

    func testDedupesAndCapsWithSequentialTokens() {
        let duplicate = OCRObservation(
            text: "Open",
            box: CGRect(x: 0.1, y: 0.2, width: 0.1, height: 0.1),
            confidence: 0.9
        )
        let observations = [duplicate, duplicate] + (0..<160).map {
            OCRObservation(
                text: "Item \($0)",
                box: CGRect(x: CGFloat($0) / 1000, y: 0.2, width: 0.1, height: 0.1),
                confidence: 0.9
            )
        }
        let hits = OCRReader.hits(
            from: observations,
            windowFrame: CGRect(x: 0, y: 0, width: 1000, height: 1000)
        )
        XCTAssertEqual(hits.count, 150)
        XCTAssertEqual(hits.first?.element.label, "Open")
        XCTAssertEqual(hits.first?.element.token, "ocr:1")
        XCTAssertEqual(hits.last?.element.token, "ocr:150")
        XCTAssertEqual(Set(hits.map(\.element.token)).count, 150)
    }

    @MainActor
    func testUnknownOCRTokenProducesStaleElementError() async {
        AgentRunner.shared.setOCRPointsForTesting([:])
        let call = DeepSeekToolCall(
            id: "test",
            name: "click",
            arguments: ["element_token": .string("ocr:999")]
        )
        do {
            _ = try await AgentRunner.shared.executeForTesting(call)
            XCTFail("Expected stale element error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("element is stale"))
        }
    }
}
