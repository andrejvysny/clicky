import ApplicationServices
import XCTest
import ClickyCore
@testable import ClickyGuideNative

/// Regressions for review findings on the hardened coordinator.
@MainActor
final class GuideReviewRegressionTests: XCTestCase {
    func testMarkDoneAndRetryCannotUndoStoppedSharing() async throws {
        let harness = GuideHarness()
        try await harness.startStep()
        harness.controller.stopSharing()
        let captures = harness.screen.captures
        harness.controller.nextManually()
        harness.controller.retry()
        await settle()
        XCTAssertEqual(harness.controller.task?.grant?.paused, true)
        XCTAssertEqual(harness.screen.captures, captures, "nothing captured after Stop sharing")
        XCTAssertEqual(harness.controller.task?.milestones.count, 0)
    }

    func testRetryLiftsAnExplicitPauseDeliberately() async throws {
        let harness = GuideHarness()
        try await harness.startStep()
        harness.controller.pause()
        harness.controller.retry()
        _ = try await harness.nextTurn()
        XCTAssertTrue(harness.controller.task?.interruptions.isEmpty == true)
    }

    func testCompletedStepSnapshotNeverReturnsAfterASideAnswer() async throws {
        let harness = GuideHarness()
        harness.controller.walkthroughPresented = true
        try await harness.startStep()
        try await harness.act(time: 10)
        try await harness.reply { _ in GuidePresentation(kind: .explanation, text: "Next you would open Apply.") }
        harness.controller.composerDidClose(submitted: true)
        await settle()
        XCTAssertNil(harness.controller.task?.step, "the verified step is not shown again")
        XCTAssertEqual(harness.controller.task?.milestones.count, 1)
    }

    func testQuickAskDuringHistoryBrowsingDoesNotRestartObservation() async throws {
        let harness = GuideHarness()
        try await harness.startStep()
        try await harness.act(time: 10)
        try await harness.reply { GuideHarness.step($0, text: "Click B") }
        harness.controller.back()
        harness.controller.composerWillOpen()
        harness.controller.composerDidClose(submitted: false)
        await settle()
        XCTAssertFalse(harness.controller.observer.isObserving)
        XCTAssertNotNil(harness.controller.task?.historyIndex)
    }

    func testAccessibilityNoiseAfterAnEpisodeNeedsANewAttempt() async throws {
        let harness = GuideHarness()
        try await harness.startStep()
        try await harness.reachUncertainty(time: 10)
        let turns = await harness.turnCount
        for _ in 0..<5 {
            harness.controller.observer.receiveAccessibility(kAXValueChangedNotification as String)
            await harness.clock.advance(1)
        }
        let after = await harness.turnCount
        XCTAssertEqual(after, turns, "value-change noise spends no episodes")
        XCTAssertEqual(harness.controller.task?.budget.episodesUsed, 2)
    }

    func testFlappingFocusWithAChangedTargetIsBounded() async throws {
        let harness = GuideHarness()
        try await harness.startStep()
        harness.screen.paint(CGRect(x: 10, y: 10, width: 12, height: 8), value: 0)
        for _ in 0..<5 {
            harness.controller.interruptForAppSwitch()
            harness.controller.activationChanged()
            await settle()
            if await harness.agent.hasPendingTurn { await harness.agent.reply { GuideHarness.step($0) } }
            await settle()
            harness.screen.paint(CGRect(x: 10, y: 10, width: 12, height: 8), value: UInt8.random(in: 1...200))
        }
        XCTAssertLessThanOrEqual(harness.controller.metrics[.relocations], GuideStepBudget.relocations)
    }
}
