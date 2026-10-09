import XCTest
@testable import ClickyCore

final class GuidePlanContractTests: XCTestCase {
    func testGoalChecksFreezeAndCannotBeNarrowedByALaterRoute() {
        var plan = GuidePlan()
        plan.adopt(milestone: "Open Settings", route: ["Open Settings", "Enable Dark Mode", "Set size 14"],
                   goalChecks: ["Dark Mode is on", "Font size is 14"])
        plan.adopt(milestone: "Enable Dark Mode", route: ["Enable Dark Mode"], goalChecks: ["Dark Mode is on"])
        XCTAssertEqual(plan.goalChecks, ["Dark Mode is on", "Font size is 14"])
    }

    func testRouteRevisionKeepsIdentitiesAndSupersedesDroppedMilestones() {
        var plan = GuidePlan()
        XCTAssertTrue(plan.adopt(milestone: "Open Settings", route: ["Open Settings", "Open Appearance", "Apply"], goalChecks: nil))
        let apply = plan.items.first { $0.intent == "Apply" }?.id
        let revision = plan.revision
        XCTAssertFalse(plan.adopt(milestone: "Open Settings", route: ["Open Settings", "Open Appearance", "Apply"], goalChecks: nil))
        XCTAssertEqual(plan.revision, revision, "an unchanged route is not a new revision")
        plan.completeCurrent()
        XCTAssertEqual(plan.current?.intent, "Open Appearance")
        XCTAssertTrue(plan.adopt(milestone: "Search Appearance", route: ["Search Appearance", "apply"], goalChecks: nil))
        XCTAssertEqual(plan.items.map(\.status), [.done, .superseded, .current, .upcoming])
        XCTAssertEqual(plan.items.last?.id, apply, "case-insensitive intent keeps its identity")
        XCTAssertEqual(plan.completedCount, 1)
    }

    func testMilestoneIsAlwaysCurrentEvenWhenRouteOmitsIt() {
        var plan = GuidePlan()
        plan.adopt(milestone: "Double-click Reports", route: ["Open Q3"], goalChecks: nil)
        XCTAssertEqual(plan.items.map(\.intent), ["Double-click Reports", "Open Q3"])
        XCTAssertEqual(plan.current?.intent, "Double-click Reports")
    }

    func testTemporaryInterruptionsNeverClearADeliberatePause() {
        var state = GuideTaskState(goal: "Fixture")
        state.pause(.composer)
        state.pause(.explicitPause)
        XCTAssertFalse(state.clearTemporaryInterruption(.composer))
        XCTAssertFalse(state.clearTemporaryInterruption(.explicitPause), "only temporary reasons clear implicitly")
        XCTAssertEqual(state.phase, .paused)
        state.resume()
        XCTAssertTrue(state.interruptions.isEmpty)
    }

    func testOnlyTemporaryReasonsClearToAutomaticResume() {
        var state = GuideTaskState(goal: "Fixture")
        state.pause(.composer); state.pause(.appSwitch)
        XCTAssertFalse(state.clearTemporaryInterruption(.composer))
        XCTAssertTrue(state.clearTemporaryInterruption(.appSwitch))
    }

    func testPositiveVerdictMustBeConfirmedAndConfirmedMustBePositive() {
        let rect = GuideRect(CGRect(x: 0, y: 0, width: 4, height: 4))
        func verdict(_ matches: Bool, _ state: GuidePresentation.OutcomeState?) -> GuidePresentation {
            GuidePresentation(kind: .verification_result, text: "Fixture", captureID: UUID(), matches: matches,
                              evidence: "Panel", evidenceTarget: rect, outcomeState: state)
        }
        XCTAssertNoThrow(try verdict(true, .confirmed).validate())
        XCTAssertNoThrow(try verdict(false, .pending).validate())
        XCTAssertThrowsError(try verdict(true, .pending).validate())
        XCTAssertThrowsError(try verdict(true, nil).validate())
        XCTAssertThrowsError(try verdict(false, .confirmed).validate())
    }

    func testStepVariantRequiresSemanticFieldsAndVerificationRequiresOutcomeState() {
        let step = GuideContract.variantSchema(for: .guide_step)
        for field in ["milestone", "plan", "goalChecks"] {
            XCTAssertTrue(step["required"].array.contains(.string(field)), field)
            XCTAssertEqual(step["properties"][field]["type"].array, [], "\(field) is not nullable on a step")
        }
        XCTAssertNil(step["properties"]["estimatedSteps"].string)
        let verdict = GuideContract.variantSchema(for: .verification_result)
        XCTAssertEqual(verdict["properties"]["outcomeState"]["type"], .string("string"))
        XCTAssertEqual(GuideContract.variantSchema(for: .task_completed)["properties"]["outcomeState"], .null)
    }

    func testHostContextCarriesStoredGoalChecksAndPlan() throws {
        var state = GuideTaskState(goal: "Fixture")
        state.authorize(WindowCaptureTarget(processIdentifier: 1, windowIdentifier: 2, applicationIdentifier: "a", applicationName: "A"))
        let context = GuideHostTaskContext(state)
        XCTAssertEqual(context.goalChecks, [])
        let encoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(context))
        XCTAssertEqual(encoded["planRevision"], .number(0))
        XCTAssertEqual(GuideContract.promptVersion, "clicky-guide-8")
    }
}

final class GuideHistoryTests: XCTestCase {
    private let target = WindowCaptureTarget(processIdentifier: 5, windowIdentifier: 7, applicationIdentifier: "fixture", applicationName: "Fixture")

    func testHistoryCursorWalksBackAndForwardWithoutTouchingTheLedger() {
        var state = GuideTaskState(goal: "Fixture")
        XCTAssertFalse(state.browseBack(), "nothing to show before any milestone")
        state.authorize(target)
        for name in ["A", "B"] { state.recordFixtureMilestone(name) }
        XCTAssertTrue(state.browseBack()); XCTAssertEqual(state.historyItem?.instruction, "B")
        XCTAssertTrue(state.browseBack()); XCTAssertEqual(state.historyItem?.instruction, "A")
        XCTAssertTrue(state.browseBack()); XCTAssertEqual(state.historyIndex, 0, "cursor stays in bounds")
        XCTAssertFalse(state.browseForward()); XCTAssertEqual(state.historyItem?.instruction, "B")
        XCTAssertTrue(state.browseForward(), "forward past the last item returns to the active step")
        XCTAssertNil(state.historyIndex)
        XCTAssertEqual(state.milestones.map(\.instruction), ["A", "B"])
    }
}

private extension GuideTaskState {
    /// Records a manual milestone through the public path, as a user pressing Next would.
    mutating func recordFixtureMilestone(_ text: String) {
        let bytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLttAAAAABJRU5ErkJggg==")!
        let target = WindowCaptureTarget(processIdentifier: 5, windowIdentifier: 7, applicationIdentifier: "fixture", applicationName: "Fixture")
        let image = try! PNGImageAttachment(data: bytes, context: ScreenContextIdentity(applicationIdentifier: "fixture", windowIdentifier: 7,
                                                                                         displayIdentifier: 1, capturedAt: Date()),
                                            capturedRegion: CGRect(x: 0, y: 0, width: 10, height: 10))
        let lease = try! beginCapture()
        let context = try! GuideCaptureContext(image: image, target: target, task: self)
        _ = accept(context, lease: lease)
        try! show(GuidePresentation(kind: .guide_step, text: text, captureID: context.captureID,
                                    target: GuideRect(CGRect(x: 0, y: 0, width: 1, height: 1)),
                                    action: GuideAction(kind: .click), outcome: GuideOutcome(description: text + " done")))
        manualNext()
    }
}
