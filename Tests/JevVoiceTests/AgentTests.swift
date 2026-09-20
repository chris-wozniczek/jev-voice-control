import XCTest
@testable import JevVoice
@testable import JevVoiceCore

final class AgentTests: XCTestCase {
    func testJSONValueEncodesMCPRequest() throws {
        let request = JSONValue.object([
            "jsonrpc": .string("2.0"),
            "id": .number(3),
            "method": .string("tools/call"),
            "params": .object([
                "name": .string("get_window_state"),
                "arguments": .object(["pid": .number(12)]),
            ]),
        ])
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(decoded["method"]?.stringValue, "tools/call")
        XCTAssertEqual(decoded["params"]?["arguments"]?["pid"]?.intValue, 12)
    }

    @MainActor
    func testDeepSeekToolSchemaAndImageContentShape() throws {
        let observe = DeepSeekPlanner.tools.first {
            $0["function"]?["name"]?.stringValue == "observe"
        }
        XCTAssertNotNil(observe)
        let message = DeepSeekMessage(
            role: "tool",
            content: .array([
                .object(["type": .string("text"), "text": .string("tree")]),
                .object([
                    "type": .string("image_url"),
                    "image_url": .object([
                        "url": .string("data:image/png;base64,AA=="),
                        "detail": .string("low"),
                    ]),
                ]),
            ]),
            name: nil,
            toolCallID: "call_1",
            toolCalls: nil
        )
        XCTAssertEqual(
            message.jsonValue()["content"]?.arrayValue?[1]["image_url"]?["detail"]?.stringValue,
            "low"
        )
    }

    @MainActor
    func testDeepSeekToolCallsDecode() throws {
        let data = Data("""
        {"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_1","type":"function","function":{"name":"observe","arguments":"{\\"screenshot\\":true}"}}]}}]}
        """.utf8)
        let turn = try DeepSeekPlanner.decodeTurn(data: data)
        XCTAssertEqual(turn.toolCalls.first?.name, "observe")
        XCTAssertEqual(turn.toolCalls.first?.arguments["screenshot"]?.boolValue, true)
    }

    func testDestructiveWordMatching() {
        XCTAssertTrue(AgentRisk.matchesDestructiveWord("Submit order"))
        XCTAssertTrue(AgentRisk.matchesDestructiveWord("Delete this message"))
        XCTAssertFalse(AgentRisk.matchesDestructiveWord("Open the settings"))
    }

    @MainActor
    func testRoutingHeuristic() {
        let safe = ExecutionPolicy.Verdict.run
        for transcript in [
            "please open the session",
            "make chrome fill the screen",
            "could you inspect this window",
        ] {
            XCTAssertTrue(VoiceController.shouldRoute(
                transcript: transcript, decisions: [], verdict: safe, hasKey: true, enabled: true
            ))
        }
        for transcript in [
            "open chrome now please",
            "type hello there please",
            "search cats in google",
        ] {
            let decision = Decision(clause: transcript, action: .dictate)
            XCTAssertFalse(VoiceController.shouldRoute(
                transcript: transcript, decisions: [decision], verdict: safe, hasKey: true, enabled: true
            ))
        }
    }

    @MainActor
    func testNoneDecisionsRouteToAgent() {
        for transcript in ["open a new session", "click new session", "start a new session"] {
            let decision = Decision(clause: transcript, action: .none, confidence: 0.4, model: "jev")
            XCTAssertTrue(VoiceController.shouldRoute(
                transcript: transcript, decisions: [decision], verdict: .run, hasKey: true, enabled: true
            ), transcript)
        }
    }

    @MainActor
    func testRoutingRequiresKeyRegardlessOfTranscript() {
        for transcript in [
            "please open chrome now",
            "please inspect this window",
            "open chrome, search for cats",
        ] {
            XCTAssertFalse(VoiceController.shouldRoute(
                transcript: transcript,
                decisions: [],
                verdict: .run,
                hasKey: false,
                enabled: true
            ))
        }
    }

    @MainActor
    func testResidualOpenIntentRoutesOnlyWithKey() {
        let decision = Decision(
            clause: "open a new session in devin",
            action: .openApp,
            targetApp: "Devin",
            model: "local"
        )
        XCTAssertTrue(VoiceController.shouldRoute(
            transcript: "open a new session in devin",
            decisions: [decision],
            verdict: .run,
            hasKey: true,
            enabled: true,
            installedApps: ["Devin", "Google Chrome"],
            aliases: AppMatcher.builtInAliases
        ))
        XCTAssertFalse(VoiceController.shouldRoute(
            transcript: "open a new session in devin",
            decisions: [decision],
            verdict: .run,
            hasKey: false,
            enabled: true,
            installedApps: ["Devin", "Google Chrome"],
            aliases: AppMatcher.builtInAliases
        ))
    }

    @MainActor
    func testKnownAppCommandsStayLocalDespiteCommandVocabulary() {
        let apps = ["Devin", "Google Chrome"]
        let aliases = AppMatcher.builtInAliases
        let cases = [
            "open devin",
            "open devin desktop",
            "switch to chrome",
            "open chrome",
            "maximize chrome window",
        ]
        for clause in cases {
            let decision = LocalCommandParser.parse(
                clause: clause,
                installedApps: apps,
                aliases: aliases,
                frontmostApp: nil
            )
            XCTAssertNotNil(decision, clause)
            XCTAssertFalse(VoiceController.shouldRoute(
                transcript: clause,
                decisions: decision.map { [$0] } ?? [],
                verdict: .run,
                hasKey: true,
                enabled: true,
                installedApps: apps,
                aliases: aliases
            ), clause)
        }
    }

    @MainActor
    func testUnknownOpenIntentRoutesWithKeyButKeepsSuggestionsWithoutKey() {
        let decision = Decision(
            clause: "open a new session",
            action: .openApp,
            model: "local"
        )
        XCTAssertTrue(VoiceController.shouldRoute(
            transcript: "open a new session",
            decisions: [decision],
            verdict: .run,
            hasKey: true,
            enabled: true,
            installedApps: ["Devin"],
            aliases: AppMatcher.builtInAliases
        ))
        XCTAssertFalse(VoiceController.shouldRoute(
            transcript: "open a new session",
            decisions: [decision],
            verdict: .run,
            hasKey: false,
            enabled: true,
            installedApps: ["Devin"],
            aliases: AppMatcher.builtInAliases
        ))
    }

    @MainActor
    func testLocalOpenAndSearchClausesDoNotRoute() {
        let apps = ["Google Chrome", "Devin"]
        let aliases = AppMatcher.builtInAliases
        let decisions = [
            LocalCommandParser.parse(
                clause: "open chrome",
                installedApps: apps,
                aliases: aliases,
                frontmostApp: nil
            ),
            LocalCommandParser.parse(
                clause: "search for bananas",
                installedApps: apps,
                aliases: aliases,
                frontmostApp: nil
            ),
        ].compactMap { $0 }
        XCTAssertFalse(VoiceController.shouldRoute(
            transcript: "open chrome and search for bananas",
            decisions: decisions,
            verdict: .run,
            hasKey: true,
            enabled: true,
            installedApps: apps,
            aliases: aliases
        ))
    }

    @MainActor
    func testAgentPicksRealWindowOverTinyHelper() {
        let windows = [
            CuaWindow(id: 1, title: "", frame: ["width": 1, "height": 1]),
            CuaWindow(id: 2, title: "Main", frame: ["width": 800, "height": 600]),
        ]
        XCTAssertEqual(AgentRunner.pickWindow(windows, preferring: nil), windows[1])
    }

    @MainActor
    func testAgentFallsBackToFirstUntitledWindow() {
        let windows = [
            CuaWindow(id: 1, title: "", frame: ["width": 800, "height": 600]),
            CuaWindow(id: 2, title: "", frame: ["width": 900, "height": 700]),
        ]
        XCTAssertEqual(AgentRunner.pickWindow(windows, preferring: nil), windows[0])
    }

    @MainActor
    func testAgentPreservesLastWindowOverDriverOrder() {
        let windows = [
            CuaWindow(id: 1, title: "First", frame: ["width": 800, "height": 600]),
            CuaWindow(id: 2, title: "Previously selected", frame: ["width": 900, "height": 700]),
        ]
        XCTAssertEqual(AgentRunner.pickWindow(windows, preferring: 2), windows[1])
    }

    @MainActor
    func testAgentUsesFirstQualifyingWindowOverLargerLaterWindow() {
        let windows = [
            CuaWindow(id: 1, title: "First", frame: ["width": 300, "height": 200]),
            CuaWindow(id: 2, title: "Larger", frame: ["width": 900, "height": 700]),
        ]
        XCTAssertEqual(AgentRunner.pickWindow(windows, preferring: nil), windows[0])
    }

    @MainActor
    func testBudgetExhaustion() async {
        let planner = NeverDonePlanner()
        let outcome = await AgentRunner.shared.run(
            goal: "keep waiting",
            planner: planner
        )
        XCTAssertEqual(outcome, .failed("Ran out of steps"))
    }

    @MainActor
    func testDeepSeekSmokeWhenKeyPresent() async throws {
        guard let key = ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"], !key.isEmpty else {
            throw XCTSkip("DEEPSEEK_API_KEY is not set")
        }
        let planner = DeepSeekPlanner(apiKey: key)
        do {
            _ = try await planner.next(PlannerContext(messages: [
                DeepSeekMessage(
                    role: "user",
                    content: .string("Call fail with reason smoke test."),
                    name: nil,
                    toolCallID: nil,
                    toolCalls: nil
                ),
            ]))
        } catch {
            XCTFail("DeepSeek smoke request failed: \(error.localizedDescription)")
        }
    }
}

@MainActor
private final class NeverDonePlanner: ActionPlanner {
    private var index = 0

    func next(_ ctx: PlannerContext) async throws -> PlannerTurn {
        index += 1
        let call = DeepSeekToolCall(
            id: "call_\(index)",
            name: "wait",
            arguments: ["seconds": .number(0)]
        )
        return PlannerTurn(
            assistant: DeepSeekMessage(
                role: "assistant",
                content: nil,
                name: nil,
                toolCallID: nil,
                toolCalls: [call]
            ),
            toolCalls: [call]
        )
    }
}
