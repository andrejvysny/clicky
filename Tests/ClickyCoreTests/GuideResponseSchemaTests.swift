import XCTest
@testable import ClickyCore

final class GuideResponseSchemaTests: XCTestCase {
    private let identifier = UUID().uuidString

    private func step() -> [String: JSONValue] {
        ["kind": .string("guide_step"), "text": .string("Open panel"), "captureID": .string(identifier),
         "target": .object(["x": .number(0), "y": .number(0), "width": .number(10), "height": .number(20)]),
         "action": .object(["kind": .string("click"), "keyCode": .null, "modifiers": .null]),
         "outcome": .object(["description": .string("Panel is visible"), "axRole": .null, "axTitle": .null, "axValue": .null]),
         "mark": .null, "label": .null, "detail": .null, "value": .null, "ghost": .null,
         "milestone": .string("Open panel"), "plan": .array([.string("Open panel")]), "goalChecks": .array([.string("Panel is visible")]), "warning": .null]
    }

    private func data(_ fields: [String: JSONValue]) throws -> Data {
        try JSONEncoder().encode(JSONValue.object(["presentation": .object(fields)]))
    }

    private func assertFailure(_ fields: [String: JSONValue], _ path: String,
                               purpose: GuideRequestPurpose = .planning, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try GuidePresentation.parseResponse(data(fields), purpose: purpose), file: file, line: line) {
            XCTAssertTrue($0.localizedDescription.contains(path), $0.localizedDescription, file: file, line: line)
            XCTAssertFalse($0.localizedDescription.contains("private-fixture"), file: file, line: line)
        }
    }

    func testStepVariantCannotOmitOrNullItsSemanticFields() throws {
        XCTAssertEqual(try GuidePresentation.parseResponse(data(step()), purpose: .planning).outcome?.description, "Panel is visible")
        for field in ["captureID", "target", "action", "outcome", "milestone", "plan", "goalChecks"] {
            var missing = step(); missing.removeValue(forKey: field)
            assertFailure(missing, "missing_field at $." + field)
            let wrapper = JSONValue.object(["presentation": .object(missing)])
            XCTAssertEqual(GuideSchemaValidation.issue(wrapper, schema: GuideContract.responseSchema)?.path, "$.presentation." + field)
            var null = step(); null[field] = .null
            assertFailure(null, "wrong_type at $." + field)
            XCTAssertFalse(GuideSchemaValidation.validate(.object(["presentation": .object(null)]), schema: GuideContract.responseSchema))
        }
        var empty = step()
        empty["outcome"] = .object(["description": .string(" \n "), "axRole": .null, "axTitle": .null, "axValue": .null])
        assertFailure(empty, "empty_text at $.outcome.description")
    }

    func testExplicitFalseVerdictValidButUnknownOrUnsupportedEvidenceNeverSucceeds() throws {
        let fields: [String: JSONValue] = ["kind": .string("verification_result"), "text": .string("Panel absent"),
            "captureID": .string(identifier), "matches": .bool(false), "evidence": .string("Panel is not visible"),
            "evidenceTarget": .object(["x": .number(10), "y": .number(20), "width": .number(100), "height": .number(200)]),
            "outcomeState": .string("unknown")]
        XCTAssertEqual(try GuidePresentation.parseResponse(data(fields), purpose: .verification).matches, false)
        for field in ["captureID", "matches", "evidence", "evidenceTarget", "outcomeState"] {
            var missing = fields; missing.removeValue(forKey: field)
            assertFailure(missing, "missing_field at $." + field, purpose: .verification)
            var null = fields; null[field] = .null
            assertFailure(null, "wrong_type at $." + field, purpose: .verification)
        }
        var invalid = fields; invalid["captureID"] = .string("private-fixture")
        assertFailure(invalid, "invalid_uuid at $.captureID", purpose: .verification)
        invalid = fields; invalid["matches"] = .string("private-fixture")
        assertFailure(invalid, "wrong_type at $.matches", purpose: .verification)
        invalid = fields; invalid["evidence"] = .string(" \n")
        assertFailure(invalid, "empty_text at $.evidence", purpose: .verification)
        invalid = fields; invalid["outcome"] = .null
        assertFailure(invalid, "unexpected_field", purpose: .verification)
    }

    func testActionVariantsRequireCommitKeysAndForbidKeysOnClicks() throws {
        var fields = step()
        fields["action"] = .object(["kind": .string("field_commit"), "keyCode": .number(48), "modifiers": .number(0)])
        XCTAssertEqual(try GuidePresentation.parseResponse(data(fields), purpose: .planning).action?.kind, .field_commit)
        fields["action"] = .object(["kind": .string("field_commit"), "keyCode": .number(48), "modifiers": .null])
        assertFailure(fields, "wrong_type at $.action.modifiers")
        fields["action"] = .object(["kind": .string("click"), "keyCode": .number(48), "modifiers": .null])
        assertFailure(fields, "wrong_type at $.action.keyCode")
    }

    func testCompactWrapperRejectsFlatOrExtraOutputWithoutLoggingContents() throws {
        XCTAssertThrowsError(try GuidePresentation.parseResponse(JSONEncoder().encode(JSONValue.object(step())), purpose: .planning)) {
            XCTAssertTrue($0.localizedDescription.contains("missing_field at $.presentation"))
        }
        let extra = JSONValue.object(["presentation": .object(step()), "private-fixture": .string("private-fixture")])
        XCTAssertThrowsError(try GuidePresentation.parseResponse(JSONEncoder().encode(extra), purpose: .planning)) {
            XCTAssertTrue($0.localizedDescription.contains("unexpected_field at $"))
            XCTAssertFalse($0.localizedDescription.contains("private-fixture"))
        }
        var fields = step(); fields["kind"] = .string("private-fixture")
        assertFailure(fields, "unknown_enum at $.kind")
    }

    func testSchemaFitsDocumentedUnionLimitsAndEveryPurposeRestrictsItsVariants() {
        let schema = GuideContract.responseSchema
        XCTAssertEqual(schema["type"], .string("object")); XCTAssertEqual(schema["anyOf"], .null)
        XCTAssertEqual(schema["required"], .array([.string("presentation")]))
        XCTAssertEqual(schema["additionalProperties"], .bool(false))
        XCTAssertEqual(unionCount(schema), 14)
        for purpose in [GuideRequestPurpose.planning, .verification, .sideQuestion, .continuation, .recovery, .oneOffContext] {
            let variants = GuideContract.responseSchema(for: purpose)["properties"]["presentation"]["anyOf"].array
            XCTAssertEqual(variants.map { $0["properties"]["kind"]["enum"].array.first! },
                           GuideContract.allowedKinds(for: purpose).map { .string($0.rawValue) })
            for variant in variants {
                guard case .object(let properties) = variant["properties"] else { return XCTFail("Missing variant") }
                XCTAssertEqual(Set(variant["required"].array.compactMap(\.string)), Set(properties.keys))
                XCTAssertEqual(variant["additionalProperties"], .bool(false))
            }
        }
    }

    private func unionCount(_ value: JSONValue) -> Int {
        switch value {
        case .object(let fields):
            return (fields["anyOf"] != nil || fields["type"]?.array.isEmpty == false ? 1 : 0)
                + fields.values.map(unionCount).reduce(0, +)
        case .array(let values): return values.map(unionCount).reduce(0, +)
        default: return 0
        }
    }
}
