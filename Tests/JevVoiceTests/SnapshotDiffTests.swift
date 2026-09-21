import XCTest
@testable import JevVoice

final class SnapshotDiffTests: XCTestCase {
    func testSnapshotDiffReportsAddedAndRemovedLabels() {
        let old = CuaSnapshot(
            snapshotId: "old",
            treeMarkdown: "",
            elements: [
                CuaElement(token: "a", role: "AXButton", label: "Old", value: nil),
                CuaElement(token: "b", role: "AXButton", label: "Keep", value: nil),
            ],
            image: nil
        )
        let new = CuaSnapshot(
            snapshotId: "new",
            treeMarkdown: "",
            elements: [
                CuaElement(token: "c", role: "AXButton", label: "Keep", value: nil),
                CuaElement(token: "d", role: "AXButton", label: "New", value: nil),
            ],
            image: nil
        )
        let diff = SnapshotDiff.between(old: old, new: new)
        XCTAssertEqual(diff.added, ["New"])
        XCTAssertEqual(diff.removed, ["Old"])
    }
}
