import XCTest
@testable import JevVoiceCore
@testable import JevVoice

final class CommandInterpreterTests: XCTestCase {
    func testPropagatesBrowserContextToLaterWebSearch() {
        let decisions = [
            Decision(clause: "open chrome", action: .openApp, targetApp: "Google Chrome"),
            Decision(clause: "search for banana", action: .webSearch),
        ]

        let propagated = CommandInterpreter.propagateContext(decisions)

        XCTAssertEqual(propagated[1].targetApp, "Google Chrome")
    }

    @MainActor
    func testActionlessSystemReroutesToFrontmostUITaskOnly() {
        let rerouted = VoiceController.rerouteActionlessSystems(
            [
                Decision(
                    clause: "open notifications",
                    action: .system,
                    systemAction: SystemAction.none,
                    confidence: 0.83
                ),
                Decision(
                    clause: "turn volume up",
                    action: .system,
                    systemAction: .volumeUp,
                    confidence: 0.9
                ),
                Decision(clause: "unclear", action: .none, confidence: 0.9),
            ],
            targetApp: "Google Chrome"
        )
        XCTAssertEqual(rerouted[0].action, Action.uiTask)
        XCTAssertEqual(rerouted[0].targetApp, "Google Chrome")
        XCTAssertEqual(rerouted[1].action, Action.system)
        XCTAssertEqual(rerouted[2].action, Action.none)
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

    func testComposesFlagFromCannedJevResponse() {
        XCTAssertTrue(
            CommandInterpreter.composes(
                from: .noul(0.9),
                action: .dictate
            )
        )
        XCTAssertFalse(
            CommandInterpreter.composes(
                from: .noul(0.9),
                action: .openApp
            )
        )
        XCTAssertFalse(
            CommandInterpreter.composes(
                from: .noul(0.4),
                action: .uiTask
            )
        )
    }

    func testSiteUITaskUsesDefaultBrowserAndHost() {
        let decisions = CommandInterpreter.localDecisions(
            clause: "open github",
            installedApps: [],
            aliases: [:],
            frontmostApp: nil
        )
        XCTAssertNil(decisions)
        let compose = CommandInterpreter.localDecisions(
            clause: "compose a post on X about cats",
            installedApps: [],
            aliases: [:],
            frontmostApp: nil
        )
        XCTAssertEqual(compose?.first?.siteHost, "x.com")
        XCTAssertEqual(compose?.first?.targetApp, "Google Chrome")
    }
}
