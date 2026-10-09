import XCTest
import ClickyCore
@testable import ClickyGuideNative

/// Production `VisualGuideController` paths with deterministic fakes. No paid model, capture or TCC prompt.
@MainActor
final class GuideCoordinatorTests: XCTestCase {
    func testClickVerifiesAndPresentsNextStepWithoutGuideControls() async throws {
        let harness = GuideHarness()
        try await harness.startStep()
        XCTAssertEqual(harness.controller.task?.phase, .waiting)
        XCTAssertEqual(harness.shownTargets.count, 1)
        XCTAssertTrue(harness.controller.observer.isObserving)

        harness.click(at: CGPoint(x: 15, y: 14), time: 10)
        XCTAssertTrue(harness.controller.task?.actionDetected == true)
        await harness.clock.advance(1)
        let verification = try await harness.nextTurn()
        XCTAssertEqual(verification.purpose, .verification)
        XCTAssertNotNil(verification.image)
        try await harness.reply { GuideHarness.verdict($0, matches: true) }
        try await harness.reply { GuideHarness.step($0, pixel: CGRect(x: 30, y: 30, width: 10, height: 8), text: "Click Apply") }

        XCTAssertEqual(harness.controller.task?.milestones.map(\.completion), [.verified])
        XCTAssertEqual(harness.controller.task?.phase, .waiting)
        XCTAssertEqual(harness.controller.task?.step?.text, "Click Apply")
        XCTAssertEqual(harness.shownTargets.count, 2)
    }

    func testDuplicateReleaseIsOneAttempt() async throws {
        let harness = GuideHarness()
        try await harness.startStep()
        harness.click(at: CGPoint(x: 15, y: 14), time: 10)
        // A duplicated monitor callback carries the same timestamp and cannot form a second attempt.
        harness.controller.observer.receiveMouse(GuideMouseEvent(point: harness.screen.point(CGPoint(x: 15, y: 14)),
                                                                 button: 0, count: 1, timestamp: 10.05))
        await harness.clock.advance(1)
        _ = try await harness.nextTurn()
        let turns = await harness.turnCount
        XCTAssertEqual(turns, 3, "planning, context, one verification")
    }

    func testFirstClickOfDoubleClickStepIsNotAnAttempt() async throws {
        let harness = GuideHarness()
        try await harness.startStep(action: .double_click)
        harness.click(at: CGPoint(x: 15, y: 14), count: 1, time: 10)
        XCTAssertFalse(harness.controller.task?.actionDetected == true)
        await harness.clock.advance(1)
        let turns = await harness.turnCount
        XCTAssertEqual(turns, 2, "no verification after a single click")
        harness.click(at: CGPoint(x: 15, y: 14), count: 2, time: 10.2)
        XCTAssertTrue(harness.controller.task?.actionDetected == true)
    }

    func testPauseDuringPlanningRejectsLateStep() async throws {
        let harness = GuideHarness()
        try harness.controller.ask("Open the fixture settings", target: harness.screen.target)
        try await harness.reply { _ in GuideHarness.contextRequest() }
        _ = try await harness.nextTurn()
        XCTAssertTrue(harness.controller.isBusy)
        harness.controller.pause()
        XCTAssertFalse(harness.controller.isBusy)
        XCTAssertEqual(harness.controller.task?.phase, .paused)
        await harness.agent.reply { GuideHarness.step($0) }
        await settle()
        XCTAssertTrue(harness.shownTargets.isEmpty)
        XCTAssertEqual(harness.controller.task?.phase, .paused)
        XCTAssertFalse(harness.controller.observer.isObserving)
    }

    func testEndDuringVerificationRejectsLateVerdict() async throws {
        let harness = GuideHarness()
        try await harness.startStep()
        harness.click(at: CGPoint(x: 15, y: 14), time: 10)
        await harness.clock.advance(1)
        _ = try await harness.nextTurn()
        harness.controller.endTask()
        XCTAssertNil(harness.controller.task)
        XCTAssertFalse(harness.controller.isBusy)
        await harness.agent.reply { GuideHarness.verdict($0, matches: true) }
        await settle()
        let turns = await harness.turnCount
        XCTAssertEqual(turns, 3, "no next-step request after End")
        XCTAssertNil(harness.controller.task)
        XCTAssertEqual(harness.shownTargets.count, 1)
    }

    func testEndDuringCaptureSendsNothing() async throws {
        let harness = GuideHarness()
        try harness.controller.ask("Open the fixture settings", target: harness.screen.target)
        harness.screen.holdCaptures = true
        try await harness.reply { _ in GuideHarness.contextRequest() }
        XCTAssertEqual(harness.screen.captures, 1)
        harness.controller.endTask()
        harness.screen.releaseCapture()
        await settle()
        let turns = await harness.turnCount
        XCTAssertEqual(turns, 1, "the held capture is never transmitted")
        XCTAssertNil(harness.controller.task)
    }

    func testRevokeBetweenCaptureAndSendTransmitsNothing() async throws {
        let harness = GuideHarness()
        try harness.controller.ask("Open the fixture settings", target: harness.screen.target)
        harness.screen.holdCaptures = true
        try await harness.reply { _ in GuideHarness.contextRequest() }
        // What AskController does when the user turns sharing off.
        harness.controller.sharingPreference = .off
        harness.controller.pause()
        harness.screen.releaseCapture()
        await settle()
        let turns = await harness.turnCount
        XCTAssertEqual(turns, 1)
        XCTAssertEqual(harness.controller.task?.grant?.paused, true)
        XCTAssertNil(harness.controller.lastImage)
    }

    func testPauseDuringVerificationCaptureStopsTheCheck() async throws {
        let harness = GuideHarness()
        try await harness.startStep()
        harness.click(at: CGPoint(x: 15, y: 14), time: 10)
        harness.screen.holdCaptures = true
        await harness.clock.advance(1)
        XCTAssertEqual(harness.controller.task?.phase, .verifying)
        harness.controller.pause()
        harness.screen.releaseCapture()
        await settle()
        let turns = await harness.turnCount
        XCTAssertEqual(turns, 2, "no verification request after Pause")
        XCTAssertEqual(harness.controller.task?.phase, .paused)
        XCTAssertFalse(harness.controller.observer.isObserving)
    }

    // MARK: Session display consent (CLICKY-8)

    private func askWithoutWindow(_ harness: GuideHarness) async throws {
        try harness.controller.ask("What is on my desktop?", target: nil)
        try await harness.reply { _ in GuideHarness.contextRequest() }
    }

    func testDisplayAsksBeforeFirstCaptureThenReusesSessionGrant() async throws {
        let harness = GuideHarness()
        harness.consent.display = .display(9)
        try await askWithoutWindow(harness)
        XCTAssertEqual(harness.consent.prompts, 1)
        let turn = try await harness.nextTurn()
        XCTAssertNotNil(turn.image)
        try await harness.reply { _ in GuidePresentation(kind: .explanation, text: "Your desktop") }
        try await askWithoutWindow(harness)
        _ = try await harness.nextTurn()
        XCTAssertEqual(harness.consent.prompts, 1, "same display and provider is not asked again")
        XCTAssertEqual(harness.screen.captures, 2)
    }

    func testTextOnlyCapturesNothingAndAnswersWithoutScreen() async throws {
        let harness = GuideHarness()
        harness.consent.display = .display(9); harness.consent.answer = false
        try await askWithoutWindow(harness)
        let turn = try await harness.nextTurn()
        XCTAssertNil(turn.image)
        XCTAssertEqual(harness.screen.captures, 0)
        XCTAssertEqual(harness.consent.prompts, 1, "Text only does not re-prompt within the request")
    }

    func testNewProcessAsksAgainDespitePersistedPreference() async throws {
        let first = GuideHarness()
        first.consent.display = .display(9)
        try await askWithoutWindow(first)
        let relaunched = GuideHarness()
        relaunched.controller.defaults = first.defaults
        XCTAssertTrue(relaunched.controller.displayFallbackAllowed)
        relaunched.consent.display = .display(9)
        try await askWithoutWindow(relaunched)
        XCTAssertEqual(relaunched.consent.prompts, 1)
    }

    func testRevokedDisplayIsAskedAgainAndOffNeverCaptures() async throws {
        let harness = GuideHarness()
        harness.consent.display = .display(9)
        try await askWithoutWindow(harness)
        try await harness.reply { _ in GuidePresentation(kind: .explanation, text: "Desktop") }
        harness.controller.displayFallbackAllowed = false
        XCTAssertNil(harness.controller.displayConsent.grant)
        try harness.controller.ask("And now?", target: nil)
        try await harness.reply { _ in GuideHarness.contextRequest() }
        XCTAssertEqual(harness.screen.captures, 1, "preference off: no display is bound or captured")
        harness.controller.displayFallbackAllowed = true
        try await harness.reply { _ in GuidePresentation(kind: .explanation, text: "Text answer") }
        try await askWithoutWindow(harness)
        XCTAssertEqual(harness.consent.prompts, 2)
    }
}
