import XCTest
@testable import ClickyCore

final class GuideContractHardeningTests: XCTestCase {
    private let captureID = UUID()

    private func fields(_ kind: GuidePresentation.Kind) -> [String: JSONValue] {
        guard case .object(let properties) = GuideContract.schema["properties"] else { return [:] }
        var result = properties.mapValues { _ in JSONValue.null }
        result["kind"] = .string(kind.rawValue)
        result["text"] = .string("Fixture answer")
        return result
    }

    private func parse(_ fields: [String: JSONValue]) throws -> GuidePresentation {
        try GuidePresentation.parse(JSONEncoder().encode(JSONValue.object(fields)))
    }

    private func failure(_ fields: [String: JSONValue], contains expected: String,
                         file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try parse(fields), file: file, line: line) {
            XCTAssertTrue($0.localizedDescription.contains(expected), $0.localizedDescription, file: file, line: line)
            XCTAssertFalse($0.localizedDescription.contains("sensitive-fixture"), file: file, line: line)
        }
    }

    func testCircleAnnotationKeepsSuppliedCaptureAndImagePixels() throws {
        var value = fields(.annotation)
        value["captureID"] = .string(captureID.uuidString)
        value["target"] = .object(["x": .number(120), "y": .number(80), "width": .number(24), "height": .number(24)])
        value["mark"] = .string("circle"); value["label"] = .string("Control")
        let result = try parse(value)
        XCTAssertEqual(result.captureID, captureID)
        XCTAssertEqual(result.target?.x, 120)
        XCTAssertEqual(result.mark, .circle)
        XCTAssertNil(result.action); XCTAssertNil(result.matches)
    }

    func testBothVerdictsNeedSuppliedCaptureAndNonemptyEvidence() throws {
        for matches in [true, false] {
            var value = fields(.verification_result)
            value["captureID"] = .string(captureID.uuidString)
            value["matches"] = .bool(matches)
            value["outcomeState"] = .string(matches ? "confirmed" : "contradicted")
            value["evidence"] = .string(matches ? "Panel is visible" : "Panel is not visible")
            value["evidenceTarget"] = .object(["x": .number(10), "y": .number(20), "width": .number(100), "height": .number(200)])
            XCTAssertEqual(try parse(value).matches, matches)
            value["evidence"] = .string(" \n ")
            failure(value, contains: "missing_evidence at $.evidence")
            value["evidence"] = .string("Panel is not visible")
            value["captureID"] = .null
            failure(value, contains: "missing_field at $.captureID")
        }
    }

    func testUnknownOrMissingVerdictCannotBecomeSuccess() {
        var value = fields(.verification_result)
        value["captureID"] = .string(captureID.uuidString)
        value["evidence"] = .string("sensitive-fixture")
        failure(value, contains: "missing_field at $.matches")
        value["matches"] = .string("true sensitive-fixture")
        failure(value, contains: "wrong_type at $.matches")
        value["matches"] = .number(1)
        failure(value, contains: "wrong_type at $.matches")
    }

    func testSafeNestedAndSchemaDiagnosticsNeverEchoRejectedContent() {
        var value = fields(.annotation)
        value["captureID"] = .string("sensitive-fixture")
        failure(value, contains: "invalid_uuid at $.captureID")
        value["captureID"] = .string(captureID.uuidString)
        value["target"] = .object(["x": .number(0), "y": .number(0), "width": .string("sensitive-fixture"), "height": .number(1)])
        failure(value, contains: "wrong_type at $.target.width")
        value["target"] = .object(["x": .number(0), "y": .number(0), "width": .number(1), "height": .number(1), "sensitive-fixture": .null])
        failure(value, contains: "unexpected_field at $.target")
        value.removeValue(forKey: "target")
        failure(value, contains: "missing_field at $.target")
        value["target"] = .null; value["mark"] = .string("sensitive-fixture")
        failure(value, contains: "unknown_enum at $.mark")
    }

    func testMissingStepAndNumericFieldsIdentifyKnownPaths() {
        var value = fields(.guide_step)
        failure(value, contains: "missing_field at $.captureID")
        value["captureID"] = .string(captureID.uuidString)
        value["target"] = .object(["x": .number(0), "y": .number(0), "width": .number(1), "height": .number(1)])
        value["outcome"] = .object(["description": .string("Panel opens"), "axRole": .null, "axTitle": .null, "axValue": .null])
        value["action"] = .object(["kind": .string("key"), "keyCode": .number(70000), "modifiers": .number(0)])
        failure(value, contains: "invalid_number at $.action.keyCode")
        value["action"] = .object(["kind": .string("key"), "keyCode": .number(36), "modifiers": .null])
        failure(value, contains: "missing_field at $.action.modifiers")
    }

    func testValueEntryContractRequiresExplicitUserCommit() {
        XCTAssertTrue(GuideContract.prompt.contains("Value-entry steps use action.kind field_commit"))
        XCTAssertTrue(GuideContract.prompt.contains("A focus click alone is not completed value entry"))
        XCTAssertTrue(GuideContract.prompt.contains("Name that commit key in the instruction"))
        XCTAssertTrue(GuideContract.schema["properties"]["action"]["description"].string?.contains("field_commit") == true)
        let rectangle = GuideRect(CGRect(x: 1, y: 2, width: 10, height: 20))
        let step = GuidePresentation(kind: .guide_step, text: "Replace quantity with 12, then press Tab", captureID: captureID,
                                     target: rectangle, action: GuideAction(kind: .field_commit, keyCode: 48, modifiers: 0),
                                     outcome: GuideOutcome(description: "Quantity is committed as 12"), value: "12")
        XCTAssertNoThrow(try step.validate())
        var matcher = GuideInteractionMatcher(action: step.action!, target: rectangle.rect)
        XCTAssertFalse(matcher.mouse(button: 0, count: 1, point: CGPoint(x: 5, y: 5), timestamp: 1))
        XCTAssertTrue(matcher.key(code: 48, modifiers: 0, timestamp: 2, repeated: false))
    }
}
