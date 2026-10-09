import XCTest
@testable import ClickyCore

final class GuideEvidenceTargetTests: XCTestCase {
    private let identifier = UUID()
    private let region = GuideRect(CGRect(x: 120, y: 80, width: 300, height: 200))

    private func fields(_ kind: GuidePresentation.Kind, matches: Bool = true) throws -> [String: JSONValue] {
        var fields: [String: JSONValue] = ["kind": .string(kind.rawValue), "text": .string("Fixture observation"),
         "captureID": .string(identifier.uuidString), "matches": .bool(matches), "evidence": .string("Relevant panel observation"),
         "evidenceTarget": try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(region))]
        if kind == .verification_result { fields["outcomeState"] = .string(matches ? "confirmed" : "contradicted") }
        return fields
    }

    private func parse(_ fields: [String: JSONValue], kind: GuidePresentation.Kind) throws -> GuidePresentation {
        let payload = JSONValue.object(["presentation": .object(fields)])
        return try GuidePresentation.parseResponse(JSONEncoder().encode(payload),
                                                  purpose: kind == .verification_result ? .verification : .continuation)
    }

    func testBothVerdictKindsAndBothBooleansPreserveIndependentEvidenceBounds() throws {
        for kind in [GuidePresentation.Kind.verification_result, .task_completed] {
            for matches in [true, false] {
                let parsed = try parse(fields(kind, matches: matches), kind: kind)
                XCTAssertEqual(parsed.captureID, identifier); XCTAssertEqual(parsed.matches, matches)
                XCTAssertEqual(parsed.evidenceTarget, region)
                XCTAssertEqual(parsed.normalized().evidenceTarget, region)
                XCTAssertNil(parsed.target); XCTAssertNil(parsed.action)
                XCTAssertNoThrow(try parsed.validate())
            }
            let schema = GuideContract.variantSchema(for: kind)
            XCTAssertTrue(schema["required"].array.contains(.string("evidenceTarget")))
            XCTAssertEqual(schema["properties"]["evidenceTarget"]["type"], .string("object"))
            XCTAssertTrue(schema["properties"]["evidenceTarget"]["anyOf"].array.isEmpty)
        }
    }

    func testMissingNullAndDegenerateEvidenceRegionsCannotValidate() throws {
        for kind in [GuidePresentation.Kind.verification_result, .task_completed] {
            var missing = try fields(kind); missing.removeValue(forKey: "evidenceTarget")
            XCTAssertThrowsError(try parse(missing, kind: kind)) {
                XCTAssertTrue($0.localizedDescription.contains("missing_field at $.evidenceTarget"))
            }
            var null = try fields(kind); null["evidenceTarget"] = .null
            XCTAssertThrowsError(try parse(null, kind: kind)) {
                XCTAssertTrue($0.localizedDescription.contains("wrong_type at $.evidenceTarget"))
            }
            for size in [0.0, -1.0] {
                for field in ["width", "height"] {
                    var invalid = try fields(kind)
                    var rectangle: [String: JSONValue] = ["x": .number(120), "y": .number(80), "width": .number(300), "height": .number(200)]
                    rectangle[field] = .number(size); invalid["evidenceTarget"] = .object(rectangle)
                    XCTAssertThrowsError(try parse(invalid, kind: kind)) {
                        XCTAssertTrue($0.localizedDescription.contains("invalid_rect at $.evidenceTarget"))
                    }
                }
            }
        }
        let nonfinite = GuideRect(CGRect(x: Double.infinity, y: 80, width: 300, height: 200))
        XCTAssertThrowsError(try GuidePresentation(kind: .verification_result, text: "Fixture", captureID: identifier,
                                                 matches: true, evidence: "Panel", evidenceTarget: nonfinite).validate())
    }

    func testEvidenceRegionIsForbiddenOnOtherKindsAndNeverBecomesActionTarget() throws {
        for kind in [GuidePresentation.Kind.context_request, .guide_step, .annotation, .explanation, .clarification, .task_proposal] {
            let value = GuidePresentation(kind: kind, text: "Fixture", evidenceTarget: region)
            XCTAssertThrowsError(try value.validate()) {
                XCTAssertTrue($0.localizedDescription.contains("forbidden_field at $.evidenceTarget"))
            }
            var wire = try fields(kind)
            wire.removeValue(forKey: "captureID"); wire.removeValue(forKey: "matches"); wire.removeValue(forKey: "evidence")
            XCTAssertFalse(GuideSchemaValidation.validate(.object(wire), schema: GuideContract.variantSchema(for: kind)))
        }
        guard case .object(let properties) = GuideContract.schema["properties"] else { return XCTFail("Missing schema") }
        var prose = properties.mapValues { _ in JSONValue.null }
        prose["kind"] = .string("explanation"); prose["text"] = .string("Fixture")
        prose["evidenceTarget"] = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(region))
        XCTAssertThrowsError(try GuidePresentation.parse(JSONEncoder().encode(JSONValue.object(prose)))) {
            XCTAssertTrue($0.localizedDescription.contains("forbidden_field at $.evidenceTarget"))
        }
    }

    func testHostContractNamesRelevantFalseRegionAndWholeGoalEvidence() throws {
        let request = GuideHostRequest(purpose: .verification, text: "Check", task: nil, capture: nil)
        let encoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(encoded["protocolVersion"], .string("clicky-guide-8"))
        XCTAssertTrue(request.responseContract.contains("evidenceTarget must bound ALL relevant visible outcome evidence"))
        XCTAssertTrue(request.responseContract.contains("relevant absence/uncertainty for false"))
        XCTAssertTrue(request.responseContract.contains("Never copy the original action target"))
        XCTAssertTrue(GuideContract.responseContract(for: .continuation).contains("ALL visible evidence establishing the whole goal"))
        XCTAssertTrue(GuideContract.prompt.contains("evidenceTarget is forbidden on every other kind"))
    }
}
