import XCTest
@testable import JevVoice

final class CDPBridgeTests: XCTestCase {
    func testSelectTargetPrefersExactPageTitle() {
        let exact = target(id: "exact", title: "Devin")
        let suffix = target(id: "suffix", title: "Devin - Google Chrome")
        let worker = target(id: "extension", title: "Devin", type: "service_worker")

        XCTAssertEqual(
            CDPBridge.selectTarget(
                targets: [suffix, worker, exact],
                windowTitle: "Devin"
            ),
            exact
        )
    }

    func testSelectTargetAcceptsChromeTitleSuffix() {
        let target = target(id: "page", title: "Devin - Google Chrome")
        XCTAssertEqual(
            CDPBridge.selectTarget(targets: [target], windowTitle: "Devin"),
            target
        )
    }

    func testMapElementRoles() {
        XCTAssertEqual(map(["n": .number(1), "tag": .string("a")])?.role, "AXLink")
        XCTAssertEqual(map(["n": .number(2), "tag": .string("button")])?.role, "AXButton")
        XCTAssertEqual(
            map(["n": .number(3), "tag": .string("input"), "type": .string("text")])?.role,
            "AXTextField"
        )
        XCTAssertEqual(map(["n": .number(4), "tag": .string("textarea")])?.role, "AXTextArea")
        XCTAssertEqual(
            map(["n": .number(5), "tag": .string("div"), "contenteditable": .bool(true)])?.role,
            "AXTextArea"
        )
        XCTAssertEqual(
            map(["n": .number(6), "tag": .string("div"), "role": .string("tab")])?.role,
            "AXTab"
        )
        XCTAssertEqual(
            map(["n": .number(7), "tag": .string("input"), "type": .string("checkbox")])?.role,
            "AXCheckBox"
        )
    }

    private func target(
        id: String,
        title: String,
        type: String = "page"
    ) -> CDPTarget {
        CDPTarget(
            id: id,
            title: title,
            url: "https://example.com",
            type: type,
            webSocketDebuggerURL: URL(string: "ws://127.0.0.1/\(id)")!
        )
    }

    private func map(_ json: [String: JSONValue]) -> CuaElement? {
        CDPBridge.mapElement(json: json)
    }
}
