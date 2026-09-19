import XCTest
@testable import JevVoiceCore

final class AppMatcherTests: XCTestCase {
    let apps = ["Google Chrome", "Safari", "Notes", "Visual Studio Code", "Music", "Go"]

    func testPartialName() {
        XCTAssertEqual(AppMatcher.match(clause: "close chrome", installedApps: apps),
                       .init(app: "Google Chrome", confidence: 0.8))
    }

    func testFullName() {
        XCTAssertEqual(AppMatcher.match(clause: "open visual studio code", installedApps: apps),
                       .init(app: "Visual Studio Code", confidence: 0.95))
    }

    func testCaseInsensitive() {
        XCTAssertEqual(AppMatcher.match(clause: "Open Safari please", installedApps: apps)?.app, "Safari")
    }

    func testNoApp() {
        XCTAssertNil(AppMatcher.match(clause: "close the app", installedApps: apps))
    }

    func testSubstringDoesNotBeatToken() {
        XCTAssertEqual(AppMatcher.match(clause: "open google", installedApps: apps)?.app, "Google Chrome")
    }

    func testTieIsLowConfidence() {
        let match = AppMatcher.match(clause: "close chrome",
                                     installedApps: ["Google Chrome", "Chrome Remote Desktop"])
        XCTAssertEqual(match?.confidence, 0.5)
    }

    func testBuiltInAlias() {
        XCTAssertEqual(
            AppMatcher.match(
                clause: "open see mux",
                installedApps: ["cmux"],
                aliases: AppMatcher.builtInAliases
            ),
            .init(app: "cmux", confidence: 0.95)
        )
    }

    func testAliasWhoseTargetIsNotInstalledDoesNotMatch() {
        XCTAssertNil(AppMatcher.match(
            clause: "open chrome",
            installedApps: ["Safari"],
            aliases: AppMatcher.builtInAliases
        ))
    }

    func testCandidatesUseAliasesAndFuzzySpelling() {
        XCTAssertEqual(
            AppMatcher.candidates(
                for: "see max",
                installedApps: ["cmux"],
                aliases: AppMatcher.builtInAliases
            ),
            ["cmux"]
        )
        XCTAssertTrue(
            AppMatcher.candidates(
                for: "devon",
                installedApps: ["Devin"],
                aliases: AppMatcher.builtInAliases
            ).contains("Devin")
        )
        XCTAssertTrue(
            AppMatcher.candidates(
                for: "zzzz gibberish",
                installedApps: ["cmux", "Devin"],
                aliases: AppMatcher.builtInAliases
            ).isEmpty
        )
    }
}

final class VerbActionTests: XCTestCase {
    func testVerbs() {
        XCTAssertEqual(AppMatcher.verbAction(clause: "Minimize chrome"), .minimizeApp)
        XCTAssertEqual(AppMatcher.verbAction(clause: "switch to safari"), .switchApp)
        XCTAssertEqual(AppMatcher.verbAction(clause: "hide notes"), .hideApp)
        XCTAssertEqual(AppMatcher.verbAction(clause: "quit music"), .closeApp)
        XCTAssertEqual(AppMatcher.verbAction(clause: "open safari"), .openApp)
        XCTAssertNil(AppMatcher.verbAction(clause: "set volume to 30"))
    }

    func testVerbWordIsNotAnAppToken() {
        XCTAssertEqual(AppMatcher.match(clause: "minimize chrome", installedApps: ["Google Chrome"])?.app, "Google Chrome")
    }
}
