import XCTest
@testable import JevVoiceCore

final class ClauseSplitterTests: XCTestCase {
    func testSplitsOnAndBeforeCommandVerb() {
        XCTAssertEqual(
            ClauseSplitter.split("open chrome and go to google.com"),
            ["open chrome", "go to google.com"]
        )
    }

    func testKeepsConjoinedObjectsTogether() {
        XCTAssertEqual(
            ClauseSplitter.split("open notes and spotify"),
            ["open notes and spotify"]
        )
    }

    func testSplitsOnThen() {
        XCTAssertEqual(
            ClauseSplitter.split("quit slack then open safari"),
            ["quit slack", "open safari"]
        )
    }

    func testAndThenSplitsOnce() {
        XCTAssertEqual(
            ClauseSplitter.split("open chrome and then go to google.com"),
            ["open chrome", "go to google.com"]
        )
    }
}

final class ClauseSplitterNewVerbTests: XCTestCase {
    func testSplitsBeforeMinimize() {
        XCTAssertEqual(ClauseSplitter.split("open safari and minimize chrome"), ["open safari", "minimize chrome"])
    }

    func testSplitsBeforeMultiwordVerbs() {
        XCTAssertEqual(ClauseSplitter.split("bring up notes then shut down music"), ["bring up notes", "shut down music"])
    }
}

final class ClauseSplitterCandidateTests: XCTestCase {
    func testCommaBoundaryDoesNotNeedJudgment() {
        let transcript = "open chrome, search for banana in google"
        let boundaries = ClauseSplitter.candidateBoundaries(transcript)

        XCTAssertEqual(boundaries.count, 1)
        XCTAssertEqual(
            (transcript as NSString).substring(from: boundaries[0].location),
            "search for banana in google"
        )
        XCTAssertFalse(boundaries[0].needsJudgment)
    }

    func testVerbBoundaryNeedsJudgment() {
        let transcript = "open chrome search for banana"
        let boundaries = ClauseSplitter.candidateBoundaries(transcript)

        XCTAssertEqual(boundaries.count, 1)
        XCTAssertEqual(
            (transcript as NSString).substring(from: boundaries[0].location),
            "search for banana"
        )
        XCTAssertTrue(boundaries[0].needsJudgment)
    }

    func testDictationTextHasNoBoundaries() {
        XCTAssertTrue(ClauseSplitter.candidateBoundaries("type open the door").isEmpty)
    }

    func testDictationKeepsPunctuationAndCommandLookingWordsAsContent() {
        XCTAssertEqual(
            ClauseSplitter.split("type the prompt. Check RAM usage"),
            ["type the prompt. Check RAM usage"]
        )
        XCTAssertEqual(
            ClauseSplitter.split("type in the prompt box, check around music"),
            ["type in the prompt box, check around music"]
        )
        XCTAssertEqual(
            ClauseSplitter.split("open Notes and then type hello, how are you. See you"),
            ["open Notes", "type hello, how are you. See you"]
        )
    }

    func testSplitsAtCommaBoundary() {
        let transcript = "open cmux, type grok"
        let boundaries = ClauseSplitter.candidateBoundaries(transcript)
        XCTAssertEqual(ClauseSplitter.split(transcript, boundaries: boundaries), ["open cmux", "type grok"])
    }

    func testSplitsAtConjunctionBoundary() {
        let transcript = "open chrome and then search for banana"
        let boundaries = ClauseSplitter.candidateBoundaries(transcript)
        XCTAssertEqual(ClauseSplitter.split(transcript, boundaries: boundaries), ["open chrome", "search for banana"])
    }

    func testStripsTrailingEndWordAndPunctuation() {
        XCTAssertEqual(ClauseSplitter.stripTrailingEndWord("open chrome, go!"), "open chrome, go!")
        XCTAssertEqual(ClauseSplitter.stripTrailingEndWord("open chrome DO IT."), "open chrome")
        XCTAssertEqual(ClauseSplitter.stripTrailingEndWord("open chrome that's it."), "open chrome")
        XCTAssertEqual(ClauseSplitter.stripTrailingEndWord("open chrome"), "open chrome")
    }

    func testSilenceTimeoutDefaultsAndBounds() {
        XCTAssertEqual(HearingSettings.defaultSilenceTimeout, 2.5)
        XCTAssertEqual(HearingSettings.constrainedSilenceTimeout(0), 1)
        XCTAssertEqual(HearingSettings.constrainedSilenceTimeout(6), 5)
    }
}
