import XCTest
import ClickyCore
@testable import ClickyGuideNative

/// Temporary interruptions resume by themselves after fresh validation; deliberate holds never do (CLICKY-17).
@MainActor
final class GuideInterruptionTests: XCTestCase {
    func testCancelledQuickAskResumesAfterLocalRevalidationWithoutTheProvider() async throws {
        let harness = GuideHarness()
        try await harness.startStep()
        harness.controller.composerWillOpen()
        XCTAssertEqual(harness.controller.task?.interruptions, [.composer])
        XCTAssertFalse(harness.controller.observer.isObserving)
        harness.controller.composerDidClose(submitted: false)
        await settle()
        XCTAssertEqual(harness.controller.task?.phase, .waiting)
        XCTAssertTrue(harness.controller.observer.isObserving)
        let turns = await harness.turnCount
        XCTAssertEqual(turns, 2, "an unchanged target is revalidated locally")
        XCTAssertEqual(harness.shownTargets.count, 2)
    }

    func testChangedTargetAfterQuickAskIsReGroundedNotReused() async throws {
        let harness = GuideHarness()
        try await harness.startStep()
        harness.controller.composerWillOpen()
        harness.screen.paint(CGRect(x: 10, y: 10, width: 12, height: 8), value: 0)
        harness.controller.composerDidClose(submitted: false)
        let relocation = try await harness.nextTurn()
        XCTAssertNotNil(relocation.image)
        XCTAssertEqual(harness.shownTargets.count, 1, "stale coordinates are not shown again")
    }

    func testSideAnswerPreservesTheStepAndDismissalContinuesIt() async throws {
        let harness = GuideHarness()
        harness.controller.walkthroughPresented = true
        try await harness.startStep()
        harness.controller.composerWillOpen()
        try harness.controller.ask("What does this setting do?", target: harness.screen.target)
        try await harness.reply { _ in GuidePresentation(kind: .explanation, text: "It controls the theme.") }
        XCTAssertEqual(harness.controller.task?.interruptions, [.sideAnswer])
        XCTAssertEqual(harness.controller.task?.step?.text, "Click Settings")
        harness.controller.composerDidClose(submitted: true)
        await settle()
        XCTAssertEqual(harness.controller.task?.phase, .waiting)
        XCTAssertTrue(harness.controller.task?.milestones.isEmpty == true)
        XCTAssertTrue(harness.controller.observer.isObserving)
    }

    func testBriefAppSwitchCapturesNothingAwayAndResumesOnReturn() async throws {
        let harness = GuideHarness()
        try await harness.startStep()
        harness.screen.focused = false
        await harness.clock.advance(1)
        XCTAssertEqual(harness.controller.task?.interruptions, [.appSwitch])
        let capturesAway = harness.screen.captures
        await harness.clock.advance(5)
        XCTAssertEqual(harness.screen.captures, capturesAway, "nothing is captured while another app is active")
        harness.screen.focused = true
        harness.controller.activationChanged()
        await settle()
        XCTAssertEqual(harness.controller.task?.phase, .waiting)
        XCTAssertTrue(harness.controller.observer.isObserving)
    }

    func testExplicitPauseDuringAnAppSwitchSurvivesTheReturn() async throws {
        let harness = GuideHarness()
        try await harness.startStep()
        harness.screen.focused = false
        await harness.clock.advance(1)
        harness.controller.pause()
        harness.screen.focused = true
        harness.controller.activationChanged()
        await settle()
        XCTAssertEqual(harness.controller.task?.phase, .paused)
        XCTAssertTrue(harness.controller.task?.interruptions.contains(.explicitPause) == true)
        XCTAssertEqual(harness.controller.status, "Paused · Resume when ready")
        XCTAssertFalse(harness.controller.observer.isObserving)
    }

    func testLateActivationCannotOverrideRevokedSharing() async throws {
        let harness = GuideHarness()
        try await harness.startStep()
        harness.controller.composerWillOpen()
        harness.controller.pause(message: "Sharing off", reason: .sharingRevoked)
        harness.controller.composerDidClose(submitted: false)
        harness.controller.activationChanged()
        await settle()
        XCTAssertEqual(harness.controller.task?.phase, .paused)
        XCTAssertEqual(harness.controller.task?.grant?.paused, true)
        let turns = await harness.turnCount
        XCTAssertEqual(turns, 2)
    }

    func testStepArrivingWhileQuickAskIsOpenIsRevalidatedWhenItCloses() async throws {
        let harness = GuideHarness()
        try await harness.startStep()
        harness.click(at: CGPoint(x: 15, y: 14), time: 10)
        await harness.clock.advance(0.5)
        harness.controller.composerWillOpen()
        try await harness.reply { GuideHarness.verdict($0, matches: true) }
        try await harness.reply { GuideHarness.step($0, text: "Click Apply") }
        XCTAssertFalse(harness.controller.observer.isObserving, "no observation while the composer is open")
        harness.controller.composerDidClose(submitted: false)
        await settle()
        XCTAssertEqual(harness.controller.task?.step?.text, "Click Apply")
        XCTAssertTrue(harness.controller.observer.isObserving)
    }
}
