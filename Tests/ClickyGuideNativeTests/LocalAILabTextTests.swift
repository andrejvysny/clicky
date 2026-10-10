import XCTest
@testable import ClickyGuideNative

final class LocalAILabTextTests: XCTestCase {
    func testWordDiffMarksRemovedAndAddedWords() throws {
        let segments = try XCTUnwrap(LabWordDiff.diff("um so I think we should go", "So I think we should go."))
        XCTAssertEqual(segments.filter { $0.kind == .removed }.map(\.text), ["um", "so", "go"])
        XCTAssertEqual(segments.filter { $0.kind == .added }.map(\.text), ["So", "go."])
        XCTAssertEqual(segments.filter { $0.kind == .same }.map(\.text), ["I", "think", "we", "should"])
    }

    func testWordDiffOfIdenticalAndEmptyText() {
        XCTAssertEqual(LabWordDiff.diff("a b", "a b")?.allSatisfy { $0.kind == .same }, true)
        XCTAssertEqual(LabWordDiff.diff("", "")?.isEmpty, true)
        XCTAssertEqual(LabWordDiff.diff("", "x")?.map(\.kind), [.added])
        let long = Array(repeating: "w", count: LabWordDiff.maximumWords + 1).joined(separator: " ")
        XCTAssertNil(LabWordDiff.diff(long, "w"), "over the cap there is no diff")
    }

    func testJSONObjectIsFoundInFencesAndProseAndStringsWithBraces() throws {
        let fenced = "Sure:\n```json\n{\"label\": \"OK {button}\", \"x\": 1}\n```\nthanks"
        let data = try XCTUnwrap(LabJSON.firstObject(in: fenced))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "{\"label\": \"OK {button}\", \"x\": 1}")
        XCTAssertNil(LabJSON.firstObject(in: "no json"))
        XCTAssertNil(LabJSON.firstObject(in: "{\"a\": 1"))
    }

    func testGroundedTargetParsingChecksBounds() {
        let good = "{\"label\":\"Save\",\"x\":10,\"y\":20,\"width\":100,\"height\":40}"
        XCTAssertEqual(LabGroundedTarget.parse(good, imageWidth: 800, imageHeight: 600)?.label, "Save")
        XCTAssertNil(LabGroundedTarget.parse(good, imageWidth: 50, imageHeight: 600))
        XCTAssertNil(LabGroundedTarget.parse("{\"label\":\"x\",\"x\":-1,\"y\":0,\"width\":5,\"height\":5}", imageWidth: 800, imageHeight: 600))
        XCTAssertNil(LabGroundedTarget.parse("{\"label\":\"x\"}", imageWidth: 800, imageHeight: 600))
    }
}
