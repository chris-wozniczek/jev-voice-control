import XCTest
@testable import JevVoice

final class ContentGeneratorTests: XCTestCase {
    func testDeepSeekBodyIncludesDisabledThinking() throws {
        let body = OpenAICompatibleGenerator.body(
            brief: "a short thank-you message",
            context: ComposeContext(app: "Mail", windowTitle: "Inbox"),
            model: "deepseek-flash",
            endpoint: URL(string: "https://api.deepseek.com/chat/completions")!,
            thinking: .off
        )
        XCTAssertEqual(body["thinking"]?["type"]?.stringValue, "disabled")
        XCTAssertTrue(
            body["messages"]?.arrayValue?.first?["content"]?.stringValue?
                .contains("Output only the text to type") == true
        )
    }

    func testOMLXBodyOmitsThinking() {
        let body = OpenAICompatibleGenerator.body(
            brief: "a short thank-you message",
            context: ComposeContext(app: nil, windowTitle: nil),
            model: "local-model",
            endpoint: URL(string: "http://127.0.0.1:8000/v1/chat/completions")!,
            thinking: nil
        )
        XCTAssertNil(body["thinking"])
    }

    func testRequestHeadersOnlyAuthorizeWhenKeyExists() {
        XCTAssertNil(OpenAICompatibleGenerator.requestHeaders(apiKey: nil)["Authorization"])
        XCTAssertNil(OpenAICompatibleGenerator.requestHeaders(apiKey: "")["Authorization"])
        XCTAssertEqual(
            OpenAICompatibleGenerator.requestHeaders(apiKey: "secret")["Authorization"],
            "Bearer secret"
        )
    }

    func testCleanStripsQuotesAndTrimsAtSentenceBoundary() {
        XCTAssertEqual(
            OpenAICompatibleGenerator.clean("\"Hello there. This is extra text.\"", max: 18),
            "Hello there."
        )
    }
}
