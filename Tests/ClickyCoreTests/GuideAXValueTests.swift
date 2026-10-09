import XCTest
@testable import ClickyCore

final class GuideAXValueTests: XCTestCase {
    func testStringsCompareExactly() {
        XCTAssertEqual(GuideAXValue.matches(expected: "12", string: "12", number: nil), true)
        XCTAssertEqual(GuideAXValue.matches(expected: "12", string: "12 ", number: nil), false)
    }

    func testBooleanControlsUseTypedState() {
        XCTAssertEqual(GuideAXValue.matches(expected: "on", string: nil, number: 1), true)
        XCTAssertEqual(GuideAXValue.matches(expected: "Checked", string: nil, number: 0), false)
        XCTAssertEqual(GuideAXValue.matches(expected: "off", string: nil, number: 0), true)
    }

    func testNumericControlsCompareNumbers() {
        XCTAssertEqual(GuideAXValue.matches(expected: "14", string: nil, number: 14), true)
        XCTAssertEqual(GuideAXValue.matches(expected: "14", string: nil, number: 13), false)
    }

    func testUnknownOrMissingValuesStayUndecidable() {
        XCTAssertNil(GuideAXValue.matches(expected: "dark", string: nil, number: 1))
        XCTAssertNil(GuideAXValue.matches(expected: "on", string: nil, number: nil))
        XCTAssertNil(GuideAXValue.matches(expected: "on", string: nil, number: .nan))
    }
}
