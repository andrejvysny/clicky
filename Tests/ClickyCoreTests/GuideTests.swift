import XCTest
@testable import ClickyCore

final class GuideTests: XCTestCase {
    private let target = WindowCaptureTarget(processIdentifier: 5, windowIdentifier: 7, applicationIdentifier: "fixture", applicationName: "Fixture")
    private func image() throws -> PNGImageAttachment {
        let bytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLttAAAAABJRU5ErkJggg==")!
        return try PNGImageAttachment(data: bytes, context: ScreenContextIdentity(applicationIdentifier: "fixture", windowIdentifier: 7, displayIdentifier: 2, capturedAt: Date()),
                                      capturedRegion: CGRect(x: -200, y: 30, width: 100, height: 50))
    }
    private func capture(_ state: inout GuideTaskState) throws -> GuideCaptureContext {
        let lease = try state.beginCapture()
        let context = try GuideCaptureContext(image: image(), target: target, task: state)
        XCTAssertTrue(state.accept(context, lease: lease))
        return context
    }
    private func step(_ context: GuideCaptureContext) -> GuidePresentation {
        GuidePresentation(kind: .guide_step, text: "Click the control", captureID: context.captureID,
                          target: GuideRect(CGRect(x: 0, y: 0, width: 1, height: 1)),
                          action: GuideAction(kind: .double_click), outcome: GuideOutcome(description: "Panel opens"))
    }
    func testGrantCancellationAndStaleCapture() throws {
        var state = GuideTaskState(goal: "Open panel")
        XCTAssertThrowsError(try state.beginCapture())
        state.authorize(target)
        let lease = try state.beginCapture()
        let context = try GuideCaptureContext(image: image(), target: target, task: state)
        state.pause()
        XCTAssertFalse(state.accept(context, lease: lease))
        state.resume()
        XCTAssertFalse(state.isCurrent(context))
        let fresh = try capture(&state)
        XCTAssertEqual(fresh.screenRect(GuideRect(CGRect(x: 0, y: 0, width: 1, height: 1))), CGRect(x: -200, y: 30, width: 100, height: 50))
        XCTAssertNil(fresh.screenRect(GuideRect(CGRect(x: 1, y: 0, width: 1, height: 1))))
    }
    func testOutcomeRecheckAndManualProvenance() throws {
        var state = GuideTaskState(goal: "Open panel"); state.authorize(target)
        let context = try capture(&state); try state.show(step(context))
        XCTAssertTrue(state.beginVerification())
        XCTAssertFalse(state.checked(matches: true, context: context))
        let firstCheck = try capture(&state)
        XCTAssertFalse(state.checked(matches: false, context: firstCheck))
        XCTAssertEqual(state.phase, .verifying)
        XCTAssertFalse(state.checked(matches: false, context: firstCheck))
        XCTAssertEqual(state.verificationChecks, 1)
        let secondCheck = try capture(&state)
        XCTAssertFalse(state.checked(matches: false, context: secondCheck))
        XCTAssertEqual(state.phase, .uncertain)
        state.manualNext()
        XCTAssertEqual(state.milestones.first?.completion, .manuallyAcknowledged)
        XCTAssertFalse(state.finish(matches: true, captureID: context.captureID))
    }
    func testAlternativeRouteAndFreshFinalCompletion() throws {
        var state = GuideTaskState(goal: "Open panel"); state.authorize(target)
        let context = try capture(&state); try state.show(step(context))
        // No prescribed event required: independently verified outcome is sufficient.
        XCTAssertTrue(state.beginVerification())
        let verification = try capture(&state)
        XCTAssertTrue(state.checked(matches: true, context: verification))
        XCTAssertEqual(state.milestones.first?.completion, .verified)
        let unverified = try capture(&state)
        XCTAssertFalse(state.finish(matches: true, captureID: unverified.captureID), "completion needs goal verification")
        XCTAssertTrue(state.beginGoalVerification())
        let final = try capture(&state)
        XCTAssertTrue(state.finish(matches: true, captureID: final.captureID))
    }
    func testContextRequestsBoundedAndInvalidationRejectsTargets() throws {
        var state = GuideTaskState(goal: "Open panel"); state.authorize(target)
        try state.requestContext(); try state.requestContext()
        XCTAssertThrowsError(try state.requestContext())
        state.beginRequest(); try state.requestContext()
        let context = try capture(&state); state.changed()
        XCTAssertThrowsError(try state.show(step(context)))
        state.cancel(); XCTAssertThrowsError(try state.beginCapture())
    }
    func testDoubleClickEventTimeAndExpectedKeys() {
        var mouse = GuideInteractionMatcher(action: GuideAction(kind: .double_click), target: CGRect(x: 10, y: 20, width: 30, height: 40))
        XCTAssertFalse(mouse.mouse(button: 0, count: 1, point: CGPoint(x: 20, y: 30), timestamp: 1))
        XCTAssertTrue(mouse.mouse(button: 0, count: 2, point: CGPoint(x: 20, y: 30), timestamp: 1.2))
        XCTAssertFalse(mouse.mouse(button: 0, count: 2, point: CGPoint(x: 20, y: 30), timestamp: 1.2))
        var key = GuideInteractionMatcher(action: GuideAction(kind: .key, keyCode: 36, modifiers: 0), target: .zero)
        XCTAssertFalse(key.key(code: 36, modifiers: 0, timestamp: 2, repeated: true))
        XCTAssertFalse(key.key(code: 36, modifiers: 1, timestamp: 2, repeated: false))
        XCTAssertTrue(key.key(code: 36, modifiers: 0, timestamp: 2, repeated: false))
    }
    func testPresentationSchemaRejectsRawUnknownNestedAndMissingFields() throws {
        var fields: [String: JSONValue] = ["kind": .string("explanation"), "text": .string("Answer")]
        for key in ["captureID", "target", "crop", "action", "outcome", "matches", "evidence", "evidenceTarget", "proposedGoal",
                    "mark", "label", "detail", "value", "ghost", "milestone", "plan", "goalChecks",
                    "outcomeState", "warning"] { fields[key] = .null }
        XCTAssertEqual(try GuidePresentation.parse(JSONEncoder().encode(JSONValue.object(fields))).text, "Answer")
        fields["target"] = .object(["x": .number(0), "y": .number(0), "width": .number(1), "height": .number(1), "command": .string("forbidden")])
        XCTAssertThrowsError(try GuidePresentation.parse(JSONEncoder().encode(JSONValue.object(fields))))
        XCTAssertThrowsError(try GuidePresentation.parse(Data("not JSON".utf8)))
        XCTAssertThrowsError(try GuidePresentation.parse(Data("{\"kind\":\"explanation\",\"text\":\"missing fields\"}".utf8)))
    }
}
