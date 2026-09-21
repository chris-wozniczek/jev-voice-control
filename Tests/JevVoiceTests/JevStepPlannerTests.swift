import XCTest
@testable import JevVoice
@testable import JevVoiceCore

final class JevStepPlannerTests: XCTestCase {
    func testRerankableRequiresRealShortControl() {
        XCTAssertFalse(
            JevStepPlanner.isRerankable(
                role: "AXRow",
                label: "Wire Agnes 4/6-bit and Bonsai models to OMLX"
            )
        )
        XCTAssertTrue(JevStepPlanner.isRerankable(role: "AXButton", label: "Model"))
        XCTAssertFalse(
            JevStepPlanner.isRerankable(
                role: "AXButton",
                label: "One two three four five six seven"
            )
        )
    }

    @MainActor
    func testNilSnapshotObservesTargetApp() async throws {
        let fake = FakeJev()
        let planner = JevStepPlanner(client: fake, canEscalate: false)
        let turn = try await planner.next(PlannerContext(goal: "open a new session", targetApp: "Devin"))
        XCTAssertEqual(turn.toolCalls.first?.name, "observe")
        XCTAssertEqual(turn.toolCalls.first?.arguments["app"]?.stringValue, "Devin")
        XCTAssertEqual(turn.toolCalls.first?.arguments["screenshot"]?.boolValue, false)
        XCTAssertTrue(fake.states.isEmpty)
    }

    @MainActor
    func testChoosesVisibleElementAndBuildsCriteria() async throws {
        let fake = FakeJev(answer: .choice(choice: "e1", confidence: 0.9, probabilities: ["e1": 0.9]), goalReached: 0.1)
        let planner = JevStepPlanner(client: fake, canEscalate: false)
        let snapshot = snapshot([
            CuaElement(token: "tok-new", role: "AXButton", label: "New Session", value: nil),
            CuaElement(token: "tok-settings", role: "AXButton", label: "Settings", value: nil),
            CuaElement(token: "tok-docs", role: "AXLink", label: "Docs", value: nil),
            CuaElement(token: "tok-input", role: "AXTextArea", label: "", value: nil),
        ])
        let turn = try await planner.next(PlannerContext(
            goal: "open a new session",
            targetApp: "Devin",
            windowTitle: "Devin",
            snapshot: snapshot
        ))
        XCTAssertEqual(turn.toolCalls.first?.name, "click")
        XCTAssertEqual(turn.toolCalls.first?.arguments["element_token"]?.stringValue, "tok-new")
        let state = try XCTUnwrap(fake.states.first?.objectValue)
        XCTAssertLessThanOrEqual(state["elements"]?.arrayValue?.count ?? 0, 200)
        XCTAssertFalse(state["elements"]?.arrayValue?.first?["role"]?.stringValue?.contains("AX") ?? true)
        let criteria = try XCTUnwrap(fake.questions["next_action"]?.choiceCriteria)
        XCTAssertEqual(criteria.count, 9)
        XCTAssertNotNil(criteria["e1"] as Any?)
        XCTAssertNotNil(criteria["press_return"] as Any?)
        XCTAssertNotNil(criteria["done"] as Any?)
    }

    @MainActor
    func testHintsAddWorkedBeforeContextAndCriteria() async throws {
        let fake = FakeJev(answer: .choice(choice: "e1", confidence: 0.9, probabilities: ["e1": 0.9]))
        let hints = HintStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("jev-planner-hints-\(UUID().uuidString).json"))
        hints.record(app: "Devin", goal: "open a new session", role: "AXButton", label: "New Session")
        let planner = JevStepPlanner(client: fake, canEscalate: false, hints: hints)
        _ = try await planner.next(PlannerContext(
            goal: "open a new session",
            targetApp: "Devin",
            snapshot: snapshot([
                CuaElement(token: "tok-new", role: "AXButton", label: "New Session", value: nil),
            ])
        ))

        let state = try XCTUnwrap(fake.states.first?.objectValue)
        XCTAssertEqual(
            state["worked_before"]?.arrayValue?.first?.stringValue,
            "click button \"New Session\""
        )
        let criteria = try XCTUnwrap(fake.questions["next_action"]?.choiceCriteria)
        let e1Criteria = try XCTUnwrap(criteria["e1"] ?? nil)
        XCTAssertTrue(e1Criteria.contains("worked before"))
    }

    @MainActor
    func testUnmatchedHintDoesNotAddCriteriaOrToken() async throws {
        let fake = FakeJev(answer: .choice(choice: "e9", confidence: 0.9, probabilities: ["e9": 0.9]))
        let hints = HintStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("jev-planner-hints-\(UUID().uuidString).json"))
        hints.record(app: "Devin", goal: "open a new session", role: "AXButton", label: "Missing")
        let planner = JevStepPlanner(client: fake, canEscalate: false, hints: hints)
        let turn = try await planner.next(PlannerContext(
            goal: "open a new session",
            targetApp: "Devin",
            snapshot: snapshot([
                CuaElement(token: "tok-new", role: "AXButton", label: "New Session", value: nil),
            ])
        ))

        let criteria = try XCTUnwrap(fake.questions["next_action"]?.choiceCriteria)
        XCTAssertFalse(criteria.values.compactMap { $0 }.contains { $0.contains("worked before") })
        XCTAssertEqual(turn.toolCalls.first?.name, "fail")
    }

    @MainActor
    func testClickedHintIsSkippedForThisRun() async throws {
        let fake = FakeJev(answer: .choice(choice: "e1", confidence: 0.9, probabilities: ["e1": 0.9]))
        let hints = HintStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("jev-planner-hints-\(UUID().uuidString).json"))
        hints.record(app: "Devin", goal: "open a new session", role: "AXButton", label: "New Session")
        let planner = JevStepPlanner(client: fake, canEscalate: false, hints: hints)
        _ = try await planner.next(PlannerContext(
            goal: "open a new session",
            targetApp: "Devin",
            snapshot: snapshot([
                CuaElement(token: "tok-new", role: "AXButton", label: "New Session", value: nil),
            ]),
            history: [
                PlannerStepRecord(
                    tool: "click",
                    argsSummary: "element_token=tok-new",
                    resultText: "Clicked",
                    succeeded: true,
                    elementRole: "AXButton",
                    elementLabel: "New Session"
                ),
            ]
        ))

        let state = try XCTUnwrap(fake.states.first?.objectValue)
        XCTAssertEqual(state["worked_before"]?.arrayValue?.count, 0)
        let criteria = try XCTUnwrap(fake.questions["next_action"]?.choiceCriteria)
        let e1Criteria = try XCTUnwrap(criteria["e1"] ?? nil)
        XCTAssertFalse(e1Criteria.contains("worked before"))
    }

    @MainActor
    func testGoalReachedAfterMutationReturnsDone() async throws {
        let fake = FakeJev(answer: .choice(choice: "done", confidence: 0.9, probabilities: ["done": 0.9]), goalReached: 0.85)
        let planner = JevStepPlanner(client: fake, canEscalate: false)
        let turn = try await planner.next(PlannerContext(
            goal: "open a new session",
            targetApp: "Devin",
            snapshot: snapshot([
                CuaElement(token: "tok-new", role: "AXButton", label: "New Session", value: nil),
            ]),
            history: [PlannerStepRecord(tool: "click", argsSummary: "element_token=tok", resultText: "Clicked", succeeded: true)],
            stepIndex: 1
        ))
        XCTAssertEqual(turn.toolCalls.first?.name, "done")
        XCTAssertEqual(turn.toolCalls.first?.arguments["summary"]?.stringValue, "Done: open a new session")
    }

    @MainActor
    func testGeneratedTextIsTypedVerbatim() async throws {
        let fake = FakeJev(
            answer: .choice(choice: "e1", confidence: 0.9, probabilities: ["e1": 0.9]),
            goalReached: 0.1
        )
        let planner = JevStepPlanner(client: fake, canEscalate: false)
        let turn = try await planner.next(PlannerContext(
            goal: "reply saying I'll be late",
            generatedText: "I’m sorry, I’ll be late today.",
            snapshot: snapshot([
                CuaElement(token: "tok-input", role: "AXTextField", label: "Message", value: nil),
            ])
        ))
        XCTAssertEqual(turn.toolCalls.first?.name, "type_text")
        XCTAssertEqual(
            turn.toolCalls.first?.arguments["text"]?.stringValue,
            "I’m sorry, I’ll be late today."
        )
        let state = try XCTUnwrap(fake.states.first?.objectValue)
        XCTAssertEqual(state["text_to_type"]?.stringValue, "I’m sorry, I’ll be late today.")
        XCTAssertEqual(state["text_is_generated"]?.boolValue, true)
    }

    @MainActor
    func testGoalReachedAfterMutationReturnsDoneDespiteLowActionConfidence() async throws {
        let fake = FakeJev(answer: .choice(choice: "stuck", confidence: 0.1, probabilities: ["stuck": 0.9]), goalReached: 0.9)
        let planner = JevStepPlanner(client: fake, canEscalate: false)
        let turn = try await planner.next(PlannerContext(
            goal: "open a new session",
            targetApp: "Devin",
            snapshot: snapshot([
                CuaElement(token: "tok-new", role: "AXButton", label: "New Session", value: nil),
            ]),
            history: [PlannerStepRecord(tool: "click", argsSummary: "element_token=tok", resultText: "Clicked", succeeded: true)],
            stepIndex: 1
        ))
        XCTAssertEqual(turn.toolCalls.first?.name, "done")
        XCTAssertEqual(turn.toolCalls.first?.arguments["summary"]?.stringValue, "Done: open a new session")
    }

    @MainActor
    func testTypedGoalCannotReturnDoneWhenFreshValueIsMissing() async throws {
        let fake = FakeJev(
            answer: .choice(choice: "done", confidence: 0.9, probabilities: ["done": 0.9]),
            goalReached: 0.9
        )
        let planner = JevStepPlanner(client: fake, canEscalate: false)
        let turn = try await planner.next(PlannerContext(
            goal: #"type "hello world""#,
            snapshot: snapshot([
                CuaElement(token: "tok-input", role: "AXTextField", label: "Message", value: ""),
            ]),
            typedTextVisible: false,
            history: [
                PlannerStepRecord(
                    tool: "type_text",
                    argsSummary: "text=hello world",
                    resultText: "Typed hello world but the field did not show it",
                    succeeded: true
                ),
            ],
            stepIndex: 1
        ))
        XCTAssertEqual(turn.toolCalls.first?.name, "fail")
    }

    @MainActor
    func testGoalOverlapRanksMatchingControlAndReranksLowConfidenceChoice() async throws {
        let fake = FakeJev(
            answer: .choice(
                choice: "e2",
                confidence: 0.45,
                probabilities: ["e1": 0.6, "e2": 0.8]
            )
        )
        let planner = JevStepPlanner(client: fake, canEscalate: false)
        let turn = try await planner.next(PlannerContext(
            goal: "change the model",
            snapshot: snapshot([
                CuaElement(token: "tok-settings", role: "AXButton", label: "Settings", value: nil),
                CuaElement(token: "tok-model", role: "AXPopUpButton", label: "Model: Claude", value: nil),
                CuaElement(token: "tok-new", role: "AXButton", label: "New session", value: nil),
            ])
        ))
        XCTAssertEqual(turn.toolCalls.first?.name, "click")
        XCTAssertEqual(turn.toolCalls.first?.arguments["element_token"]?.stringValue, "tok-model")
        let state = try XCTUnwrap(fake.states.first?.objectValue)
        XCTAssertEqual(state["elements"]?.arrayValue?.first?["label"]?.stringValue, "Model: Claude")
        XCTAssertEqual(state["elements"]?.arrayValue?.first?["matches_request"]?.boolValue, true)
        let criteria = try XCTUnwrap(fake.questions["next_action"]?.choiceCriteria)
        XCTAssertTrue(criteria["e1"]??.contains("label matches the request") == true)
    }

    @MainActor
    func testWrongSurfaceRuleEscapesAndExcludesClickedLabel() async throws {
        let fake = FakeJev(
            answer: .choice(choice: "e1", confidence: 0.9, probabilities: ["e1": 0.9])
        )
        let planner = JevStepPlanner(client: fake, canEscalate: false)
        let first = try await planner.next(PlannerContext(
            goal: "change the model",
            windowTitle: "Settings",
            previousWindowTitle: "Devin",
            snapshot: snapshot([
                CuaElement(token: "tok-settings", role: "AXButton", label: "Settings", value: nil),
                CuaElement(token: "tok-model", role: "AXPopUpButton", label: "Model: Claude", value: nil),
            ]),
            history: [
                PlannerStepRecord(
                    tool: "click",
                    argsSummary: "element_token=tok-settings",
                    resultText: "Clicked",
                    succeeded: true,
                    elementRole: "AXButton",
                    elementLabel: "Settings"
                ),
            ],
            stepIndex: 1
        ))
        XCTAssertEqual(first.toolCalls.first?.name, "press_key")
        XCTAssertEqual(first.toolCalls.first?.arguments["key"]?.stringValue, "escape")

        let second = try await planner.next(PlannerContext(
            goal: "change the model",
            windowTitle: "Devin",
            previousWindowTitle: "Settings",
            snapshot: snapshot([
                CuaElement(token: "tok-settings", role: "AXButton", label: "Settings", value: nil),
                CuaElement(token: "tok-model", role: "AXPopUpButton", label: "Model: Claude", value: nil),
            ]),
            history: [
                PlannerStepRecord(
                    tool: "click",
                    argsSummary: "element_token=tok-settings",
                    resultText: "Clicked",
                    succeeded: true,
                    elementRole: "AXButton",
                    elementLabel: "Settings"
                ),
                PlannerStepRecord(
                    tool: "press_key",
                    argsSummary: "key=escape",
                    resultText: "Pressed escape",
                    succeeded: true
                ),
            ],
            stepIndex: 2
        ))
        XCTAssertEqual(second.toolCalls.first?.arguments["element_token"]?.stringValue, "tok-model")
    }

    @MainActor
    func testWrongSurfaceNoulEscapesAndRecoveryCapIsTwo() async throws {
        let fake = FakeJev(
            answer: .choice(choice: "e1", confidence: 0.9, probabilities: ["e1": 0.9]),
            wrongSurface: 0.9
        )
        let planner = JevStepPlanner(client: fake, canEscalate: false)
        let baseHistory = [
            PlannerStepRecord(
                tool: "click",
                argsSummary: "element_token=tok-settings",
                resultText: "Clicked",
                succeeded: true,
                elementRole: "AXButton",
                elementLabel: "Settings"
            ),
        ]
        let first = try await planner.next(PlannerContext(
            goal: "change the model",
            windowTitle: "Settings",
            previousWindowTitle: "Devin",
            snapshot: snapshot([
                CuaElement(token: "tok-settings", role: "AXButton", label: "Settings", value: nil),
                CuaElement(token: "tok-model", role: "AXPopUpButton", label: "Model: Claude", value: nil),
            ]),
            history: baseHistory,
            stepIndex: 1
        ))
        XCTAssertEqual(first.toolCalls.first?.arguments["key"]?.stringValue, "escape")

        let second = try await planner.next(PlannerContext(
            goal: "change the model",
            windowTitle: "Settings",
            snapshot: snapshot([
                CuaElement(token: "tok-settings", role: "AXButton", label: "Settings", value: nil),
                CuaElement(token: "tok-model", role: "AXPopUpButton", label: "Model: Claude", value: nil),
            ]),
            history: baseHistory + [
                PlannerStepRecord(
                    tool: "press_key",
                    argsSummary: "key=escape",
                    resultText: "Pressed escape",
                    succeeded: true
                ),
            ],
            stepIndex: 2
        ))
        XCTAssertEqual(second.toolCalls.first?.arguments["key"]?.stringValue, "w")
        XCTAssertEqual(second.toolCalls.first?.arguments["modifiers"]?.arrayValue?.first?.stringValue, "command")

        let third = try await planner.next(PlannerContext(
            goal: "change the model",
            windowTitle: "Settings",
            snapshot: snapshot([
                CuaElement(token: "tok-settings", role: "AXButton", label: "Settings", value: nil),
                CuaElement(token: "tok-model", role: "AXPopUpButton", label: "Model: Claude", value: nil),
            ]),
            history: baseHistory + [
                PlannerStepRecord(
                    tool: "press_key",
                    argsSummary: "key=escape",
                    resultText: "Pressed escape",
                    succeeded: true
                ),
                PlannerStepRecord(
                    tool: "press_key",
                    argsSummary: "key=w modifiers=command",
                    resultText: "Pressed command-w",
                    succeeded: true
                ),
            ],
            stepIndex: 3
        ))
        XCTAssertEqual(third.toolCalls.first?.name, "click")
    }

    @MainActor
    func testElectronLikeSnapshotWithUnobservableValueCanReturnDone() async throws {
        let fake = FakeJev(
            answer: .choice(choice: "done", confidence: 0.9, probabilities: ["done": 0.9]),
            goalReached: 0.9
        )
        let planner = JevStepPlanner(client: fake, canEscalate: false)
        let turn = try await planner.next(PlannerContext(
            goal: #"type "hello world""#,
            snapshot: snapshot([
                CuaElement(token: "tok-web", role: "AXWebArea", label: "Message", value: nil),
            ]),
            history: [
                PlannerStepRecord(
                    tool: "type_text",
                    argsSummary: "text=hello world",
                    resultText: "Typed hello world (unverified)",
                    succeeded: true
                ),
            ],
            stepIndex: 1
        ))
        XCTAssertEqual(turn.toolCalls.first?.name, "done")
    }

    @MainActor
    func testDoneWithLowGoalConfidenceChoosesAlternative() async throws {
        let fake = FakeJev(
            answer: .choice(choice: "done", confidence: 0.9, probabilities: ["done": 0.9, "e1": 0.6]),
            goalReached: 0.2
        )
        let planner = JevStepPlanner(client: fake, canEscalate: false)
        let turn = try await planner.next(PlannerContext(
            goal: "open a new session",
            snapshot: snapshot([
                CuaElement(token: "tok-new", role: "AXButton", label: "New Session", value: nil),
            ])
        ))
        XCTAssertEqual(turn.toolCalls.first?.name, "click")
    }

    @MainActor
    func testTextAreaUsesExtractedText() async throws {
        let fake = FakeJev(answer: .choice(choice: "e1", confidence: 0.9, probabilities: ["e1": 0.9]), goalReached: 0.1)
        let planner = JevStepPlanner(client: fake, canEscalate: false)
        let turn = try await planner.next(PlannerContext(
            goal: "ask it to analyze the login bug",
            snapshot: snapshot([
                CuaElement(token: "tok-input", role: "AXTextArea", label: "Message", value: nil),
            ])
        ))
        XCTAssertEqual(turn.toolCalls.first?.name, "type_text")
        XCTAssertEqual(turn.toolCalls.first?.arguments["text"]?.stringValue, "analyze the login bug")
        XCTAssertEqual(turn.toolCalls.first?.arguments["element_token"]?.stringValue, "tok-input")
    }

    @MainActor
    func testMissingTextFailsOrEscalates() async throws {
        let fake = FakeJev(
            answer: .choice(choice: "e1", confidence: 0.9, probabilities: ["e1": 0.9]),
            goalReached: 0.1
        )
        let noEscalation = JevStepPlanner(client: fake, canEscalate: false)
        let context = PlannerContext(
            goal: "open a new session",
            snapshot: snapshot([
                CuaElement(token: "tok-input", role: "AXTextArea", label: "Message", value: nil),
            ])
        )
        let failed = try await noEscalation.next(context)
        XCTAssertEqual(failed.toolCalls.first?.name, "fail")
        XCTAssertTrue(failed.toolCalls.first?.arguments["reason"]?.stringValue?.contains("Tell me what to type") == true)

        let escalation = JevStepPlanner(client: fake, canEscalate: true)
        let escalated = try await escalation.next(context)
        XCTAssertEqual(
            escalated.escalation,
            PlannerEscalation.toDeepSeek(reason: "Jev needs text that was not in the request")
        )
    }

    @MainActor
    func testLowConfidenceFailsOrEscalates() async throws {
        let fake = FakeJev(answer: .choice(choice: "e1", confidence: 0.2, probabilities: ["e1": 0.2]), goalReached: 0)
        let planner = JevStepPlanner(client: fake, canEscalate: false)
        let turn = try await planner.next(PlannerContext(
            goal: "open a new session",
            targetApp: "Devin",
            snapshot: snapshot([
                CuaElement(token: "tok-new", role: "AXButton", label: "New Session", value: nil),
            ])
        ))
        XCTAssertEqual(turn.toolCalls.first?.name, "fail")
    }

    @MainActor
    func testLowConfidenceNonElementChoiceDefersThenSticks() async throws {
        let fake = FakeJev(
            answer: .choice(
                choice: "press_escape",
                confidence: 0.4,
                probabilities: ["press_escape": 0.4]
            )
        )
        let planner = JevStepPlanner(client: fake, canEscalate: false)
        let context = PlannerContext(
            goal: "close the menu",
            targetApp: "Devin",
            snapshot: snapshot([
                CuaElement(token: "tok", role: "AXButton", label: "Menu", value: nil),
            ])
        )

        let deferred = try await planner.next(context)
        XCTAssertEqual(deferred.toolCalls.first?.name, "observe")
        XCTAssertEqual(deferred.toolCalls.first?.arguments["screenshot"]?.boolValue, false)
        XCTAssertEqual(deferred.toolCalls.first?.arguments["app"]?.stringValue, "Devin")

        let stuck = try await planner.next(context)
        XCTAssertEqual(stuck.toolCalls.first?.name, "fail")
    }

    @MainActor
    func testNoControlsFailsOrEscalates() async throws {
        let fake = FakeJev()
        let planner = JevStepPlanner(client: fake, canEscalate: false)
        let turn = try await planner.next(PlannerContext(
            goal: "open a new session",
            targetApp: "Devin",
            snapshot: snapshot([])
        ))
        XCTAssertEqual(turn.toolCalls.first?.name, "fail")

        let escalation = JevStepPlanner(client: fake, canEscalate: true)
        let escalated = try await escalation.next(PlannerContext(
            goal: "open a new session",
            targetApp: "Devin",
            snapshot: snapshot([])
        ))
        XCTAssertEqual(
            escalated.escalation,
            PlannerEscalation.toDeepSeek(reason: "no accessible controls")
        )
    }

    @MainActor
    func testRepeatedChoiceWithUnchangedSnapshotGetsStuck() async throws {
        let fake = FakeJev(answer: .choice(choice: "e1", confidence: 0.9, probabilities: ["e1": 0.9]), goalReached: 0.1)
        let planner = JevStepPlanner(client: fake, canEscalate: false)
        let context = PlannerContext(
            goal: "open a new session",
            snapshot: snapshot([
                CuaElement(token: "tok-new", role: "AXButton", label: "New Session", value: nil),
            ])
        )
        _ = try await planner.next(context)
        let repeated = try await planner.next(context)
        XCTAssertEqual(repeated.toolCalls.first?.name, "fail")
    }

    @MainActor
    func testCascadeUsesJevThenDeepSeekAfterEscalation() async throws {
        let jev = StubPlanner(turn: PlannerTurn(
            assistant: DeepSeekMessage(role: "assistant", content: nil, name: nil, toolCallID: nil, toolCalls: nil),
            toolCalls: [],
            escalation: .toDeepSeek(reason: "stuck")
        ))
        let deepSeek = StubPlanner(turn: PlannerTurn(
            assistant: DeepSeekMessage(role: "assistant", content: nil, name: nil, toolCallID: nil, toolCalls: nil),
            toolCalls: [DeepSeekToolCall(id: "deep-1", name: "fail", arguments: ["reason": .string("fallback")])]
        ))
        let cascade = CascadePlanner(jev: jev, deepSeek: deepSeek)
        let first = try await cascade.next(PlannerContext())
        XCTAssertEqual(first.toolCalls.first?.id, "deep-1")
        let second = try await cascade.next(PlannerContext())
        XCTAssertEqual(second.toolCalls.first?.id, "deep-1")
        XCTAssertEqual(jev.calls, 1)
        XCTAssertEqual(deepSeek.calls, 2)
    }

    private func snapshot(_ elements: [CuaElement]) -> CuaSnapshot {
        CuaSnapshot(snapshotId: "snapshot", treeMarkdown: "", elements: elements, image: nil)
    }
}

private final class FakeJev: JevAnswering {
    let answer: Answer
    let goalReached: Double
    let wrongSurface: Double
    var states: [JSONValue] = []
    var questions: [String: Question] = [:]

    init(
        answer: Answer = .choice(choice: "stuck", confidence: 0.9, probabilities: ["stuck": 0.9]),
        goalReached: Double = 0,
        wrongSurface: Double = 0
    ) {
        self.answer = answer
        self.goalReached = goalReached
        self.wrongSurface = wrongSurface
    }

    func systemOne(
        state: JSONValue,
        questions: [String: Question]
    ) async throws -> (SystemOneResponse, Double) {
        states.append(state)
        self.questions = questions
        let response = SystemOneResponse(
            model: "jev",
            answers: [
                "next_action": answer,
                "goal_reached": .noul(goalReached),
                "wrong_surface": .noul(wrongSurface),
                "needs_text": .noul(0.8),
            ],
            usage: nil
        )
        return (response, 12)
    }
}

private final class StubPlanner: ActionPlanner {
    let turn: PlannerTurn
    private(set) var calls = 0

    init(turn: PlannerTurn) {
        self.turn = turn
    }

    func next(_ ctx: PlannerContext) async throws -> PlannerTurn {
        calls += 1
        return turn
    }
}

private extension Question {
    var choiceCriteria: [String: String?]? {
        guard case .choice(_, let criteria) = self else { return nil }
        return criteria
    }
}
