import XCTest
@testable import JevVoiceCore

final class SlotExtractorTests: XCTestCase {
    func testSpokenDotURL() {
        XCTAssertEqual(SlotExtractor.url(from: "go to google dot com"), "https://google.com")
    }

    func testURLWithPath() {
        XCTAssertEqual(SlotExtractor.url(from: "open github.com/chris"), "https://github.com/chris")
    }

    func testNoURL() {
        XCTAssertNil(SlotExtractor.url(from: "open notes"))
    }

    func testSearchQuery() {
        XCTAssertEqual(
            SlotExtractor.searchQuery(from: "search for swift concurrency"),
            "swift concurrency"
        )
    }

    func testSearchQueryStripsGooglePhrase() {
        XCTAssertEqual(
            SlotExtractor.searchQuery(from: "search for banana in google"),
            "banana"
        )
    }

    func testSearchQueryStripsChromePhraseAndFindsBrowser() {
        let clause = "search for banana in chrome"
        XCTAssertEqual(SlotExtractor.searchQuery(from: clause), "banana")
        XCTAssertEqual(SlotExtractor.searchBrowser(from: clause), "Google Chrome")
    }

    func testSearchQueryWithoutEngine() {
        XCTAssertEqual(
            SlotExtractor.searchQuery(from: "search for apple pie"),
            "apple pie"
        )
    }

    func testFallbackSearchQueryStripsLeadingVerbAndArticle() {
        XCTAssertEqual(
            SlotExtractor.fallbackSearchQuery(from: "Check the last Juventus game"),
            "last Juventus game"
        )
    }

    func testFallbackSearchQueryKeepsQuestionWhole() {
        XCTAssertEqual(
            SlotExtractor.fallbackSearchQuery(from: "Who is Juventus coach"),
            "Who is Juventus coach"
        )
    }

    func testFallbackSearchQueryRejectsShortRemainder() {
        XCTAssertNil(SlotExtractor.fallbackSearchQuery(from: "Find"))
    }

    func testDictationText() {
        XCTAssertEqual(SlotExtractor.dictationText(from: "type hello world"), "hello world")
    }

    func testRequestedDictationText() {
        XCTAssertEqual(
            SlotExtractor.dictationText(from: "type please analyze this issue"),
            "please analyze this issue"
        )
    }

    func testTypedText() {
        XCTAssertEqual(SlotExtractor.typedText(from: "type hello there"), "hello there")
        XCTAssertEqual(SlotExtractor.typedText(from: "write a note saying hello"), "hello")
        XCTAssertEqual(SlotExtractor.typedText(from: "ask it to analyze this"), "analyze this")
        XCTAssertNil(SlotExtractor.typedText(from: "click new session"))
    }

    func testComposeRequest() {
        XCTAssertEqual(
            SlotExtractor.composeRequest(from: "write a note apologising for the delay"),
            "a note apologising for the delay"
        )
        XCTAssertNil(SlotExtractor.composeRequest(from: "type hello there"))
        XCTAssertNil(SlotExtractor.composeRequest(from: "write a message saying hello"))
        XCTAssertNotNil(SlotExtractor.composeRequest(from: "reply with a polite thank you message"))
        XCTAssertEqual(
            SlotExtractor.composeRequest(from: "compose a post about the new release"),
            "a post about the new release"
        )
        XCTAssertEqual(
            SlotExtractor.composeRequest(from: "post on x about the new release"),
            "about the new release"
        )
        XCTAssertNil(SlotExtractor.composeRequest(from: "compose a post saying 'hello'"))
    }

    func testPercentDigits() {
        XCTAssertEqual(SlotExtractor.numberPercent(from: "set volume to 30 percent"), 30)
    }

    func testPercentWords() {
        XCTAssertEqual(SlotExtractor.numberPercent(from: "set volume to max"), 100)
        XCTAssertEqual(SlotExtractor.numberPercent(from: "set volume to half"), 50)
    }
}
