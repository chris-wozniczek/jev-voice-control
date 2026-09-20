import XCTest
@testable import JevVoiceCore

final class LocalCommandParserTests: XCTestCase {
    let apps = [
        "Google Chrome", "Safari", "cmux", "Devin", "Visual Studio Code",
        "System Settings", "TextEdit", "Finder",
    ]

    func testLocalCommands() {
        let cases: [(String, Action, String?, String?, Int?)] = [
            ("open chrome", .openApp, "Google Chrome", nil, nil),
            ("open see mux", .openApp, "cmux", nil, nil),
            ("open devon", .openApp, "Devin", nil, nil),
            ("launch code", .openApp, "Visual Studio Code", nil, nil),
            ("maximize chrome", .maximizeApp, "Google Chrome", nil, nil),
            ("maximise safari", .maximizeApp, "Safari", nil, nil),
            ("maximize", .maximizeApp, "Safari", nil, nil),
            ("maximize this window", .maximizeApp, "Safari", nil, nil),
            ("full screen chrome", .fullscreenApp, "Google Chrome", nil, nil),
            ("restore chrome", .restoreApp, "Google Chrome", nil, nil),
            ("minimize it", .minimizeApp, "Safari", nil, nil),
            ("hide chrome", .hideApp, "Google Chrome", nil, nil),
            ("switch to text edit", .switchApp, "TextEdit", nil, nil),
            ("close chrome", .closeApp, "Google Chrome", nil, nil),
            ("open settings", .openApp, "System Settings", nil, nil),
            ("type hello world", .dictate, nil, "hello world", nil),
            ("search for banana in google", .webSearch, nil, "banana", nil),
            ("go to github.com", .openURL, nil, nil, nil),
            ("mute", .system, nil, nil, nil),
            ("volume 40 percent", .system, nil, nil, 40),
        ]

        for (clause, action, target, slot, percent) in cases {
            let decision = LocalCommandParser.parse(
                clause: clause,
                installedApps: apps,
                aliases: AppMatcher.builtInAliases,
                frontmostApp: "Safari"
            )
            XCTAssertEqual(decision?.action, action, clause)
            XCTAssertEqual(decision?.targetApp, target, clause)
            XCTAssertEqual(decision?.text ?? decision?.query, slot, clause)
            XCTAssertEqual(decision?.percent, percent, clause)
            XCTAssertGreaterThanOrEqual(decision?.confidence ?? 0, 0.8, clause)
            XCTAssertEqual(decision?.model, "local", clause)
        }
    }

    func testUnknownAndAmbiguousCommandsUseJev() {
        XCTAssertNil(LocalCommandParser.parse(
            clause: "open", installedApps: apps,
            aliases: AppMatcher.builtInAliases, frontmostApp: "Safari"
        ))
        XCTAssertNil(LocalCommandParser.parse(
            clause: "do something weird", installedApps: apps,
            aliases: AppMatcher.builtInAliases, frontmostApp: "Safari"
        ))
        XCTAssertNil(LocalCommandParser.parse(
            clause: "open chrome or safari",
            installedApps: apps,
            aliases: AppMatcher.builtInAliases,
            frontmostApp: "Safari"
        ))
    }

    func testComposeClauseUsesGeneratedDictation() {
        let decision = LocalCommandParser.parse(
            clause: "write a note apologising for the delay",
            installedApps: apps,
            aliases: AppMatcher.builtInAliases,
            frontmostApp: "Safari"
        )
        XCTAssertEqual(decision?.action, .dictate)
        XCTAssertTrue(decision?.composes == true)
        XCTAssertNil(decision?.text)
        XCTAssertEqual(decision?.query, "a note apologising for the delay")
    }
}
