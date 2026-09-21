import XCTest
@testable import JevVoice

final class AXMenuBarTests: XCTestCase {
    func testModifierMasksMatchRequestedModifiers() {
        XCTAssertTrue(AXMenuBar.modifiersMatch(mask: 0, modifiers: ["command"]))
        XCTAssertTrue(AXMenuBar.modifiersMatch(mask: 1, modifiers: ["command", "shift"]))
        XCTAssertTrue(AXMenuBar.modifiersMatch(mask: 6, modifiers: ["command", "option", "control"]))
        XCTAssertTrue(AXMenuBar.modifiersMatch(mask: 8, modifiers: []))
        XCTAssertTrue(AXMenuBar.modifiersMatch(mask: 9, modifiers: ["shift"]))
        XCTAssertFalse(AXMenuBar.modifiersMatch(mask: 1, modifiers: ["command"]))
        XCTAssertFalse(AXMenuBar.modifiersMatch(mask: 0, modifiers: []))
    }
}
