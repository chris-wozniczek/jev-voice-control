import XCTest
@testable import JevVoiceCore

final class CommandInterpreterTests: XCTestCase {
    func testPropagatesBrowserContextToLaterWebSearch() {
        let decisions = [
            Decision(clause: "open chrome", action: .openApp, targetApp: "Google Chrome"),
            Decision(clause: "search for banana", action: .webSearch),
        ]

        let propagated = CommandInterpreter.propagateContext(decisions)

        XCTAssertEqual(propagated[1].targetApp, "Google Chrome")
    }

    func testDoesNotPropagateNonBrowserContext() {
        let decisions = [
            Decision(clause: "open notes", action: .openApp, targetApp: "Notes"),
            Decision(clause: "search for banana", action: .webSearch),
        ]

        let propagated = CommandInterpreter.propagateContext(decisions)

        XCTAssertNil(propagated[1].targetApp)
    }

    func testMixedLocalAndUITaskKeepsTheOpenedAppAsTarget() {
        let clauses = ClauseSplitter.split("open devin and start a new session")
        XCTAssertEqual(clauses, ["open devin", "start a new session"])

        let local = CommandInterpreter.localDecisions(
            clause: clauses[0],
            installedApps: ["Devin"],
            aliases: AppMatcher.builtInAliases,
            frontmostApp: nil
        )
        XCTAssertEqual(local?.first?.action, .openApp)
        XCTAssertEqual(local?.first?.targetApp, "Devin")

        let decisions = CommandInterpreter.propagateContext(
            (local ?? []) + [
                Decision(clause: clauses[1], action: .uiTask, confidence: 0.85)
            ]
        )
        XCTAssertEqual(decisions.count, 2)
        XCTAssertEqual(decisions[0].action, .openApp)
        XCTAssertEqual(decisions[0].clause, "open devin")
        XCTAssertEqual(decisions[0].targetApp, "Devin")
        XCTAssertEqual(decisions[1].action, .uiTask)
        XCTAssertEqual(decisions[1].clause, "start a new session")
        XCTAssertEqual(decisions[1].targetApp, "Devin")
    }

    func testKnownAppResidualsDoNotCreateUITaskForAppOnlyCommands() {
        let google = CommandInterpreter.localDecisions(
            clause: "open google chrome",
            installedApps: ["Google Chrome"],
            aliases: [:],
            frontmostApp: nil
        )
        XCTAssertEqual(google?.count, 1)
        XCTAssertEqual(google?.first?.action, .openApp)

        let cmux = CommandInterpreter.localDecisions(
            clause: "open see mux",
            installedApps: ["cmux"],
            aliases: AppMatcher.builtInAliases,
            frontmostApp: nil
        )
        XCTAssertEqual(cmux?.count, 1)
        XCTAssertEqual(cmux?.first?.action, .openApp)
    }

    func testPropagatesOpenedAppToUITask() {
        let decisions = [
            Decision(clause: "open devin", action: .openApp, targetApp: "Devin"),
            Decision(clause: "start a new session", action: .uiTask),
        ]

        XCTAssertEqual(CommandInterpreter.propagateContext(decisions)[1].targetApp, "Devin")
    }
}
