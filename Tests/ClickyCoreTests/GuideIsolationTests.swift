import XCTest
@testable import ClickyCore

final class GuideIsolationTests: XCTestCase {
    private var cleanSettings: JSONValue {
        .object(["effective": .object(["autoMemoryEnabled": .bool(false), "disableAllHooks": .bool(true),
                                      "claudeMdExcludes": .array([.string("**")])]),
                 "sources": .array([.object(["source": .string("flagSettings"), "settings": .object([:])])])])
    }

    func testEffectivePolicyRejectsHooksCustomSourcesAndMissingDiagnostics() throws {
        XCTAssertNoThrow(try GuideClaudePolicy.audit(cleanSettings))
        XCTAssertThrowsError(try GuideClaudePolicy.audit(.object([:])))
        XCTAssertThrowsError(try GuideClaudePolicy.auditManaged(.object(["hooks": .object(["SessionStart": .array([.object([:])])])])))
        XCTAssertThrowsError(try GuideClaudePolicy.auditManaged(.object(["policyHelper": .string("inherited command")])))
        guard case .object(var value) = cleanSettings else { return XCTFail() }
        value["sources"] = .array([.object(["source": .string("userSettings"), "settings": .object([:])])])
        XCTAssertThrowsError(try GuideClaudePolicy.audit(.object(value)))
    }

    func testDetailRequestsMustReferenceEvidenceAndKeysAreBounded() {
        let crop = GuideRect(CGRect(x: 1, y: 2, width: 10, height: 20))
        XCTAssertThrowsError(try GuidePresentation(kind: .context_request, text: "Detail", crop: crop).validate())
        XCTAssertNoThrow(try GuidePresentation(kind: .context_request, text: "Detail", captureID: UUID(), crop: crop).validate())
        let invalidKey = GuidePresentation(kind: .guide_step, text: "Commit", captureID: UUID(), target: crop,
                                          action: GuideAction(kind: .key, keyCode: 255, modifiers: 0), outcome: GuideOutcome(description: "Committed"))
        XCTAssertThrowsError(try invalidKey.validate())
    }

    func testManualFinishAndPreviewRemainUnverified() throws {
        var demo = GuidePreviewFixture(); demo.pause(); demo.next()
        XCTAssertEqual(demo.index, 0)
        demo.resume(); demo.next(); demo.next(); demo.next(); demo.next()
        XCTAssertTrue(demo.completed); XCTAssertEqual(demo.index, 3)
        var state = GuideTaskState(goal: "Manual task"); state.finishManually()
        XCTAssertEqual(state.phase, .completed)
        XCTAssertFalse(state.finish(matches: true, captureID: UUID()))
    }
    func testSideQuestionsCannotAdvanceAndHostRequestsAreStructured() throws {
        XCTAssertFalse(GuideRequestPurpose.sideQuestion.permits(.guide_step))
        XCTAssertFalse(GuideRequestPurpose.sideQuestion.permits(.task_completed))
        XCTAssertTrue(GuideRequestPurpose.sideQuestion.permits(.task_proposal))
        XCTAssertTrue(GuideRequestPurpose.verification.permits(.verification_result))
        XCTAssertFalse(GuideRequestPurpose.verification.permits(.explanation))
        let request = GuideAgentTurn(message: "Related question", purpose: .sideQuestion, taskContext: GuideHostTaskContext(GuideTaskState(goal: "Keep goal")))
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(request.text.utf8))
        XCTAssertEqual(value["purpose"].string, "sideQuestion")
        XCTAssertEqual(value["task"]["goal"].string, "Keep goal")
    }
    func testVariantsRejectInapplicableActionsAndVerdicts() {
        XCTAssertThrowsError(try GuidePresentation(kind: .explanation, text: "Answer", action: GuideAction(kind: .click)).validate())
        XCTAssertThrowsError(try GuidePresentation(kind: .clarification, text: "Which field?", matches: true).validate())
        XCTAssertThrowsError(try GuidePresentation(kind: .context_request, text: "Overview", proposedGoal: "Replace").validate())
    }
}
