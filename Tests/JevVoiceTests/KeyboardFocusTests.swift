import XCTest
@testable import JevVoice

final class KeyboardFocusTests: XCTestCase {
    func testConfirmsTypedCollapsedCaseInsensitiveValue() {
        XCTAssertTrue(
            KeyboardFocus.confirmsTyped(
                value: "Hello   WORLD",
                expected: "hello world"
            )
        )
    }

    func testConfirmsShortExpectedTextByContainment() {
        XCTAssertTrue(KeyboardFocus.confirmsTyped(value: "abc", expected: "bc"))
        XCTAssertFalse(KeyboardFocus.confirmsTyped(value: "abc", expected: "z"))
    }

    func testMissingValueDoesNotConfirm() {
        XCTAssertFalse(KeyboardFocus.confirmsTyped(value: nil, expected: "hello"))
    }
}
