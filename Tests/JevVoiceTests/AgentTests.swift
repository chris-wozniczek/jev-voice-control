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

    @MainActor
    func testDeepSeekThinkingBodyAndReasoningContentRoundTrip() throws {
        let off = DeepSeekPlanner.body(messages: [], thinking: .off)
        XCTAssertEqual(off["thinking"]?["type"]?.stringValue, "disabled")
        let low = DeepSeekPlanner.body(messages: [], thinking: .low)
        XCTAssertEqual(low["thinking"]?["type"]?.stringValue, "enabled")
        XCTAssertEqual(low["reasoning_effort"]?.stringValue, "low")

        let data = Data("""
        {"choices":[{"message":{"role":"assistant","content":null,"reasoning_content":"brief reasoning","tool_calls":[]}}]}
        """.utf8)
        let turn = try DeepSeekPlanner.decodeTurn(data: data)
        XCTAssertEqual(turn.assistant.reasoningContent, "brief reasoning")
        XCTAssertEqual(turn.assistant.jsonValue()["reasoning_content"]?.stringValue, "brief reasoning")
    }

    func testDestructiveWordMatching() {
        XCTAssertTrue(AgentRisk.matchesDestructiveWord("Submit order"))
        XCTAssertTrue(AgentRisk.matchesDestructiveWord("Delete this message"))
        XCTAssertFalse(AgentRisk.matchesDestructiveWord("Open the settings"))
    }

    @MainActor
    func testOrderedVocabularyIncludesSiteNamesAndAliases() {
        let vocabulary = SpeechRecognizer.orderedVocabulary(
            extra: [],
            appNames: [],
            siteNames: ["X", "x.com"]
        )
        XCTAssertTrue(vocabulary.contains("X"))
        XCTAssertTrue(vocabulary.contains("x.com"))
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
                transcript: transcript, decisions: [], verdict: safe, agentAvailable: true, enabled: true
            ))
        }
        for transcript in [
            "open chrome now please",
            "type hello there please",
            "search cats in google",
        ] {
            let decision = Decision(clause: transcript, action: .dictate)
            XCTAssertFalse(VoiceController.shouldRoute(
                transcript: transcript, decisions: [decision], verdict: safe, agentAvailable: true, enabled: true
            ))
        }
    }

    @MainActor
    func testNoneDecisionsRouteToAgent() {
        for transcript in ["open a new session", "click new session", "start a new session"] {
            let decision = Decision(clause: transcript, action: .none, confidence: 0.4, model: "jev")
            XCTAssertTrue(VoiceController.shouldRoute(
                transcript: transcript, decisions: [decision], verdict: .run, agentAvailable: true, enabled: true
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
                agentAvailable: false,
                enabled: true
            ))
        }
    }

    @MainActor
    func testRoutingRequiresAgentAvailability() {
        XCTAssertFalse(VoiceController.shouldRoute(
            transcript: "open a new session",
            decisions: [Decision(clause: "open a new session", action: .none)],
            verdict: .run,
            agentAvailable: false,
            enabled: true
        ))
    }

    @MainActor
    func testUITaskDoesNotRouteToAgent() {
        let decision = Decision(
            clause: "start a new session",
            action: .uiTask,
            targetApp: "Devin",
            model: "local"
        )
        XCTAssertFalse(VoiceController.shouldRoute(
            transcript: "start a new session",
            decisions: [decision],
            verdict: .run,
            agentAvailable: true,
            enabled: true,
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
                agentAvailable: true,
                enabled: true,
                installedApps: apps,
                aliases: aliases
            ), clause)
        }
    }

    @MainActor
    func testUnresolvedOpenIntentDoesNotUseResidualRoutingHeuristic() {
        let decision = Decision(
            clause: "open a new session",
            action: .openApp,
            model: "local"
        )
        XCTAssertFalse(VoiceController.shouldRoute(
            transcript: "open a new session",
            decisions: [decision],
            verdict: .run,
            agentAvailable: true,
            enabled: true,
            installedApps: ["Devin"],
            aliases: AppMatcher.builtInAliases
        ))
        XCTAssertFalse(VoiceController.shouldRoute(
            transcript: "open a new session",
            decisions: [decision],
            verdict: .run,
            agentAvailable: false,
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
            agentAvailable: true,
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
    func testRankWindowsAllUntitledSkipsTinyHelper() {
        let windows = [
            CuaWindow(id: 1, title: "", frame: ["width": 1, "height": 1]),
            CuaWindow(id: 2, title: "", frame: ["width": 900, "height": 700]),
        ]
        XCTAssertEqual(
            AgentRunner.rankWindows(windows, preferring: nil, focusedFrame: nil).first,
            windows[1]
        )
    }

    @MainActor
    func testRankWindowsPrefersLastWindow() {
        let windows = [
            CuaWindow(id: 1, title: "First", frame: ["width": 800, "height": 600]),
            CuaWindow(id: 2, title: "Previously selected", frame: ["width": 900, "height": 700]),
        ]
        XCTAssertEqual(
            AgentRunner.rankWindows(windows, preferring: 2, focusedFrame: nil).first,
            windows[1]
        )
    }

    @MainActor
    func testRankWindowsMatchesFocusedFrame() {
        let windows = [
            CuaWindow(id: 1, title: "", frame: ["width": 1, "height": 1]),
            CuaWindow(id: 2, title: "", frame: ["x": 0, "y": 25, "width": 1200, "height": 800]),
            CuaWindow(id: 3, title: "", frame: ["width": 400, "height": 300]),
        ]
        XCTAssertEqual(
            AgentRunner.rankWindows(
                windows,
                preferring: nil,
                focusedFrame: CGRect(x: 0, y: 25, width: 1200, height: 800)
            ).first?.id,
            2
        )
    }

    @MainActor
    func testRankWindowsTitledBeforeUntitledAmongQualifying() {
        let windows = [
            CuaWindow(id: 1, title: "", frame: ["width": 800, "height": 600]),
            CuaWindow(id: 2, title: "Main", frame: ["width": 800, "height": 600]),
        ]
        XCTAssertEqual(
            AgentRunner.rankWindows(windows, preferring: nil, focusedFrame: nil).first,
            windows[1]
        )
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
    func testCDPIsPreferredForChromeOrThinAccessibilityTrees() {
        XCTAssertTrue(AgentRunner.shouldTryCDP(bundleId: "com.google.Chrome", interactiveCount: 20))
        XCTAssertTrue(AgentRunner.shouldTryCDP(bundleId: "com.example.Electron", interactiveCount: 2))
        XCTAssertFalse(AgentRunner.shouldTryCDP(bundleId: "com.example.App", interactiveCount: 3))
    }

    @MainActor
    func testRiskyCDPTokenUsesSnapshotLabel() {
        let snapshot = CuaSnapshot(
            snapshotId: "snapshot",
            treeMarkdown: "",
            elements: [
                CuaElement(token: "cdp:1", role: "AXButton", label: "Delete", value: nil),
            ],
            image: nil
        )
        AgentRunner.shared.setSnapshotForTesting(snapshot)
        XCTAssertTrue(AgentRunner.shared.isRisky(token: "cdp:1", key: nil))
        AgentRunner.shared.setSnapshotForTesting(nil)
    }

    @MainActor
    func testPreConfirmedAgentActionDoesNotRequestConfirmation() async throws {
        var confirmationCount = 0
        AgentRunner.shared.confirmationHandler = { _ in
            confirmationCount += 1
        }
        defer {
            AgentRunner.shared.confirmationHandler = nil
        }
        let call = DeepSeekToolCall(
            id: "test",
            name: "click",
            arguments: ["element_token": .string("cdp:1")]
        )
        do {
            _ = try await AgentRunner.shared.executeForTesting(
                call,
                context: AgentContext(preConfirmed: true)
            )
            XCTFail("Expected missing CDP observation error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Observe a Chrome page first"))
        }
        XCTAssertEqual(confirmationCount, 0)
    }

    @MainActor
    func testAppsAreCachedUntilForcedRefresh() async throws {
        var calls = 0
        AgentRunner.shared.setAppsProviderForTesting {
            calls += 1
            return [CuaApp(pid: 10, name: "Test App", bundleId: "com.example.test")]
        }
        defer {
            AgentRunner.shared.setAppsProviderForTesting(nil)
        }

        _ = try await AgentRunner.shared.apps()
        _ = try await AgentRunner.shared.apps()
        XCTAssertEqual(calls, 1)

        _ = try await AgentRunner.shared.apps(forceRefresh: true)
        XCTAssertEqual(calls, 2)
    }

    @MainActor
    func testAXPressFailureRetriesAfterActivate() {
        XCTAssertTrue(AgentRunner.shouldRetryAfterActivate(
            AgentError.api("AX action failed: AXUIElementPerformAction(AXPress) returned -25206")
        ))
        XCTAssertFalse(AgentRunner.shouldRetryAfterActivate(AgentError.api("timeout")))
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
