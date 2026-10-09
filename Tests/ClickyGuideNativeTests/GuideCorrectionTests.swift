import XCTest
import ClickyCore
@testable import ClickyGuideNative

/// Wrong target select-only mode (CLICKY-34) and stop-sharing revocation (CLICKY-11).
@MainActor
final class GuideCorrectionTests: XCTestCase {
    func testSelectionIsAHintNotAnAttemptAndIsRemovedBeforeCapture() async throws {
        let harness = GuideHarness()
        try await harness.startStep()
        harness.controller.beginCorrection()
        XCTAssertTrue(harness.controller.correcting)
        XCTAssertFalse(harness.controller.observer.isObserving, "nothing completes during correction")
        XCTAssertEqual(harness.selection.region, harness.screen.bounds)
        var surfaceOpenAtCapture: Bool?
        harness.screen.beforeCapture = { surfaceOpenAtCapture = harness.selection.surface?.closed == false }
        harness.selection.select(harness.screen.point(CGPoint(x: 40, y: 30)))
        let turn = try await harness.nextTurn()
        XCTAssertEqual(surfaceOpenAtCapture, false, "selection UI is gone before the model capture")
        XCTAssertTrue(turn.message.contains("User-selected image pixel: x=40, y=30."))
        XCTAssertEqual(harness.controller.metrics[.attempts], 0)
        try await harness.reply { GuideHarness.step($0, pixel: CGRect(x: 36, y: 26, width: 10, height: 8)) }
        XCTAssertEqual(harness.controller.task?.phase, .waiting)
        XCTAssertEqual(harness.controller.task?.milestones.count, 0, "correction never completes the step")
        XCTAssertTrue(harness.controller.observer.isObserving)
    }

    func testEscapeCancelsCorrectionAndRestoresTheStepLocally() async throws {
        let harness = GuideHarness()
        try await harness.startStep()
        harness.controller.beginCorrection()
        harness.selection.cancel()
        await settle()
        XCTAssertFalse(harness.controller.correcting)
        XCTAssertTrue(harness.controller.observer.isObserving)
        let turns = await harness.turnCount
        XCTAssertEqual(turns, 2)
    }

    func testEndAndPauseCloseTheSelectionSurface() async throws {
        let harness = GuideHarness()
        try await harness.startStep()
        harness.controller.beginCorrection()
        harness.controller.pause()
        XCTAssertEqual(harness.selection.surface?.closed, true)
        XCTAssertFalse(harness.controller.correcting)
        harness.selection.select(harness.screen.point(CGPoint(x: 40, y: 30)))
        await settle()
        let turns = await harness.turnCount
        XCTAssertEqual(turns, 2, "a late selection after Pause is ignored")
    }

    func testSelectionOutsideTheSharedWindowIsRejected() async throws {
        let harness = GuideHarness()
        try await harness.startStep()
        harness.controller.beginCorrection()
        harness.selection.select(CGPoint(x: 5, y: 5))
        await settle()
        let turns = await harness.turnCount
        XCTAssertEqual(turns, 2)
        XCTAssertTrue(harness.controller.observer.isObserving)
    }

    func testTypedCorrectionWhenLiveSelectionIsUnavailable() async throws {
        let harness = GuideHarness()
        harness.selection.available = false
        try await harness.startStep()
        harness.controller.beginCorrection()
        XCTAssertEqual(harness.controller.status, "Describe the right control in Quick Ask")
        harness.controller.composerWillOpen()
        try harness.controller.ask("the blue Export button at the bottom", target: harness.screen.target)
        let turn = try await harness.nextTurn()
        XCTAssertTrue(turn.message.contains("the blue Export button at the bottom"))
        XCTAssertEqual(harness.controller.task?.goal, "Open the fixture settings", "a correction never replaces the goal")
    }

    func testStopSharingDuringVerificationRejectsTheLateVerdict() async throws {
        let harness = GuideHarness()
        try await harness.startStep()
        harness.click(at: CGPoint(x: 15, y: 14), time: 10)
        await harness.clock.advance(0.5)
        _ = try await harness.nextTurn()
        harness.controller.stopSharing()
        XCTAssertEqual(harness.controller.task?.grant?.paused, true)
        XCTAssertTrue(harness.controller.task?.interruptions.contains(.sharingRevoked) == true)
        await harness.agent.reply { GuideHarness.verdict($0, matches: true) }
        await settle()
        XCTAssertEqual(harness.controller.task?.milestones.count, 0)
        let turns = await harness.turnCount
        XCTAssertEqual(turns, 3)
    }
}
