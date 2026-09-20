import XCTest
@testable import JevVoice

final class HintStoreTests: XCTestCase {
    func testGoalKeyNormalizesAndRecordUpserts() {
        XCTAssertEqual(
            HintStore.goalKey("Open a new session, please"),
            "open new session"
        )

        let store = HintStore(url: temporaryURL())
        store.record(app: "Devin", goal: "Open a new session, please", role: "AXButton", label: "New Session")
        store.record(app: "Devin", goal: "Open a new session, please", role: "AXButton", label: "New Session")

        let hints = store.hints(app: "Devin", goal: "open new session")
        XCTAssertEqual(hints.count, 1)
        XCTAssertEqual(hints.first?.uses, 2)
    }

    func testHintsOrderAndSharedWords() {
        let store = HintStore(url: temporaryURL())
        store.record(app: "Devin", goal: "open new session", role: "AXButton", label: "New Session")
        store.record(app: "Devin", goal: "start a new session", role: "AXButton", label: "Start")
        store.record(app: "Devin", goal: "start a new session", role: "AXButton", label: "Start")
        store.record(app: "Devin", goal: "open settings", role: "AXButton", label: "Settings")

        let hints = store.hints(app: "Devin", goal: "please open a new session now")
        XCTAssertEqual(hints.map(\.label), ["New Session", "Start"])
    }

    func testCapEvictsLeastUsedEntryAndClearRemovesAll() {
        let store = HintStore(url: temporaryURL())
        store.record(app: "Devin", goal: "open new session", role: "AXButton", label: "Important")
        store.record(app: "Devin", goal: "open new session", role: "AXButton", label: "Important")
        for index in 0..<501 {
            store.record(
                app: "Devin",
                goal: "unique goal \(index)",
                role: "AXButton",
                label: "Button \(index)"
            )
        }
        store.save()

        XCTAssertEqual(store.count, 500)
        XCTAssertEqual(store.hints(app: "Devin", goal: "open new session").first?.label, "Important")

        store.clear()
        XCTAssertEqual(store.count, 0)
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("jev-hints-\(UUID().uuidString).json")
    }
}
