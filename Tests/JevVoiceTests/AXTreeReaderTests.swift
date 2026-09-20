import CoreGraphics
import XCTest
@testable import JevVoice

private struct FakeNode: AXNode {
    let role: String
    let subrole: String?
    let title: String?
    let axDescription: String?
    let stringValue: String?
    let placeholder: String?
    let frame: CGRect?
    let actionNames: [String]
    let children: [FakeNode]

    init(
        role: String,
        title: String? = nil,
        axDescription: String? = nil,
        stringValue: String? = nil,
        placeholder: String? = nil,
        frame: CGRect? = CGRect(x: 0, y: 0, width: 10, height: 10),
        actionNames: [String] = [],
        children: [FakeNode] = []
    ) {
        self.role = role
        subrole = nil
        self.title = title
        self.axDescription = axDescription
        self.stringValue = stringValue
        self.placeholder = placeholder
        self.frame = frame
        self.actionNames = actionNames
        self.children = children
    }
}

final class AXTreeReaderTests: XCTestCase {
    func testInteractiveAndLabelledNodesAreEmitted() throws {
        let root = FakeNode(role: "AXGroup", children: [
            FakeNode(role: "AXButton", title: "New session"),
            FakeNode(role: "AXButton", title: "Continue"),
            FakeNode(role: "AXButton", title: "Settings"),
            FakeNode(role: "AXStaticText", title: "Welcome"),
            FakeNode(role: "AXGroup"),
        ])
        let result = try XCTUnwrap(AXTreeReader.walk(
            root,
            deadline: Date().addingTimeInterval(1)
        ))
        XCTAssertEqual(result.map(\.label), ["New session", "Continue", "Settings", "Welcome"])
    }

    func testUnlabelledGroupsAreSkipped() throws {
        let root = FakeNode(role: "AXGroup", children: [
            FakeNode(role: "AXButton", title: "One"),
            FakeNode(role: "AXButton", title: "Two"),
            FakeNode(role: "AXButton", title: "Three"),
            FakeNode(role: "AXGroup"),
        ])
        let result = try XCTUnwrap(AXTreeReader.walk(
            root,
            deadline: Date().addingTimeInterval(1)
        ))
        XCTAssertFalse(result.contains { $0.role == "AXGroup" })
    }

    func testEmptyTitleTextFieldUsesPlaceholder() throws {
        let root = FakeNode(role: "AXGroup", children: [
            FakeNode(role: "AXTextField", placeholder: "Search"),
            FakeNode(role: "AXButton", title: "One"),
            FakeNode(role: "AXButton", title: "Two"),
        ])
        let result = try XCTUnwrap(AXTreeReader.walk(
            root,
            deadline: Date().addingTimeInterval(1)
        ))
        XCTAssertEqual(result.first?.label, "Search")
    }

    func testEmptyLabelTextInputsUseRoleLabels() throws {
        let root = FakeNode(role: "AXGroup", children: [
            FakeNode(role: "AXTextField"),
            FakeNode(role: "AXTextArea"),
            FakeNode(role: "AXSearchField"),
        ])
        let result = try XCTUnwrap(AXTreeReader.walk(
            root,
            deadline: Date().addingTimeInterval(1)
        ))
        XCTAssertEqual(result.map { $0.label }, ["text field", "text area", "search field"])
    }

    func testLabelPrecedence() throws {
        let root = FakeNode(role: "AXGroup", children: [
            FakeNode(
                role: "AXButton",
                title: "Title",
                axDescription: "Description",
                stringValue: "Value",
                placeholder: "Placeholder"
            ),
            FakeNode(
                role: "AXButton",
                axDescription: "Description",
                stringValue: "Value",
                placeholder: "Placeholder"
            ),
            FakeNode(
                role: "AXButton",
                stringValue: "Value",
                placeholder: "Placeholder"
            ),
            FakeNode(role: "AXStaticText", stringValue: "Value"),
        ])
        let result = try XCTUnwrap(AXTreeReader.walk(
            root,
            deadline: Date().addingTimeInterval(1)
        ))
        XCTAssertEqual(result.map { $0.label }, ["Title", "Description", "Placeholder", "Value"])
    }

    func testFewerThanThreeInteractiveNodesReturnsNil() {
        let root = FakeNode(role: "AXGroup", children: [
            FakeNode(role: "AXButton", title: "One"),
            FakeNode(role: "AXButton", title: "Two"),
        ])
        XCTAssertNil(AXTreeReader.walk(root, deadline: Date().addingTimeInterval(1)))
    }

    func testThreeInteractiveNodesReturnNonNil() {
        let root = FakeNode(role: "AXGroup", children: [
            FakeNode(role: "AXButton", title: "One"),
            FakeNode(role: "AXButton", title: "Two"),
            FakeNode(role: "AXButton", title: "Three"),
        ])
        XCTAssertNotNil(AXTreeReader.walk(root, deadline: Date().addingTimeInterval(1)))
    }

    func testMaxElementsCapsLargeTree() throws {
        let buttons = (0..<1000).map {
            FakeNode(
                role: "AXButton",
                title: "Button \($0)",
                frame: CGRect(x: CGFloat($0), y: 0, width: 10, height: 10)
            )
        }
        let result = try XCTUnwrap(AXTreeReader.walk(
            FakeNode(role: "AXGroup", children: buttons),
            maxElements: 600,
            deadline: Date().addingTimeInterval(1)
        ))
        XCTAssertLessThanOrEqual(result.count, 600)
        XCTAssertEqual(result.count, 600)
    }

    func testPastDeadlineReturnsNil() {
        let root = FakeNode(role: "AXGroup", children: [
            FakeNode(role: "AXButton", title: "One"),
            FakeNode(role: "AXButton", title: "Two"),
            FakeNode(role: "AXButton", title: "Three"),
        ])
        XCTAssertNil(AXTreeReader.walk(root, deadline: Date().addingTimeInterval(-1)))
    }

    func testDuplicateEntriesAreRemoved() throws {
        let button = FakeNode(role: "AXButton", title: "Same")
        let root = FakeNode(role: "AXGroup", children: [
            button, button,
            FakeNode(role: "AXButton", title: "Other"),
            FakeNode(role: "AXButton", title: "Third"),
        ])
        let result = try XCTUnwrap(AXTreeReader.walk(root, deadline: Date().addingTimeInterval(1)))
        XCTAssertEqual(result.count, 3)
    }

    func testSnapshotTokensAndMarkdownAreSequential() throws {
        let root = FakeNode(role: "AXGroup", children: [
            FakeNode(role: "AXButton", title: "New session"),
            FakeNode(role: "AXButton", title: "Settings"),
            FakeNode(role: "AXButton", title: "Docs"),
        ])
        let result = try XCTUnwrap(AXTreeReader.snapshot(root))
        XCTAssertEqual(result.snapshot.elements.map(\.token), ["ax:1", "ax:2", "ax:3"])
        XCTAssertTrue(result.snapshot.treeMarkdown.contains("[ax:1] AXButton New session"))
    }

    @MainActor
    func testUnknownAXTokenProducesStaleElementError() async {
        let call = DeepSeekToolCall(
            id: "test",
            name: "click",
            arguments: ["element_token": .string("ax:999")]
        )
        do {
            _ = try await AgentRunner.shared.executeForTesting(call)
            XCTFail("Expected stale element error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("element is stale"))
        }
    }
}
