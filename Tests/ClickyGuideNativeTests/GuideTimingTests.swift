import AppKit
import XCTest
import ClickyCore
@testable import ClickyGuideNative

/// Elapsed-time budgets use the monotonic clock, waits end on cancellation, metrics are per task,
/// and an uncertain step keeps its mark only while the control under it is unchanged.
@MainActor
final class GuideTimingTests: XCTestCase {
    private func waitingForApp() async throws -> GuideHarness {
        let harness = GuideHarness()
        harness.screen.outcome = false
        try await harness.startStep()
        harness.click(at: CGPoint(x: 15, y: 14), time: 10)
        await harness.clock.advance(0.5)
        XCTAssertEqual(harness.controller.status, "Waiting for the app")
        return harness
    }

    func testForwardWallClockJumpDoesNotCutTheAppWaitShort() async throws {
        let harness = try await waitingForApp()
        harness.clock.wallSkew = 3_600
        await harness.clock.advance(GuideHarnessTiming.appPoll)
        XCTAssertEqual(harness.controller.status, "Waiting for the app")
        let turns = await harness.turnCount
        XCTAssertEqual(turns, 2, "no early vision check")
        for _ in 0..<14 { await harness.clock.advance(GuideHarnessTiming.appPoll) }
        let verification = try await harness.nextTurn()
        XCTAssertEqual(verification.purpose, .verification)
    }

    func testBackwardWallClockJumpDoesNotExtendTheAppWait() async throws {
        let harness = try await waitingForApp()
        harness.clock.wallSkew = -3_600
        for _ in 0..<14 { await harness.clock.advance(GuideHarnessTiming.appPoll) }
        let verification = try await harness.nextTurn()
        XCTAssertEqual(verification.purpose, .verification)
    }

    func testCancellingAFocusWaitEndsItImmediately() async {
        let started = ProcessInfo.processInfo.systemUptime
        let wait = Task { await ScopedAccessibility.poll(timeout: 60) { false } }
        wait.cancel()
        let focused = await wait.value
        XCTAssertFalse(focused)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1)
    }

    func testMetricsArePerTaskAndRecordTheFirstInstruction() async throws {
        let harness = GuideHarness()
        try await harness.startStep()
        XCTAssertNotNil(harness.controller.metrics.percentile(.firstInstruction, 0.5))
        harness.click(at: CGPoint(x: 15, y: 14), time: 10)
        XCTAssertEqual(harness.controller.metrics[.attempts], 1)
        harness.controller.endTask()
        try harness.controller.ask("Open the fixture settings again", target: harness.screen.target)
        XCTAssertEqual(harness.controller.metrics[.attempts], 0, "a new task starts from zero")
        XCTAssertNil(harness.controller.metrics.percentile(.firstInstruction, 0.5))
    }

    func testReplacedControlClearsTheUncertainMark() async throws {
        let harness = GuideHarness()
        try await harness.startStep()
        try await harness.reachUncertainty(time: 10)
        XCTAssertEqual(harness.controller.task?.phase, .uncertain)
        let cleared = harness.clearedTargets, turns = await harness.turnCount
        harness.screen.paint(CGRect(x: 10, y: 10, width: 12, height: 8), value: 0)
        await harness.clock.advance(1); await harness.clock.advance(1)
        XCTAssertEqual(harness.controller.status, "View changed · Find again or Re-check")
        XCTAssertGreaterThan(harness.clearedTargets, cleared, "the stale mark is removed")
        XCTAssertFalse(harness.controller.observer.isObserving)
        let after = await harness.turnCount
        XCTAssertEqual(after, turns, "clearing sends nothing")
    }

    func testUnchangedControlKeepsTheUncertainMark() async throws {
        let harness = GuideHarness()
        try await harness.startStep()
        try await harness.reachUncertainty(time: 10)
        let cleared = harness.clearedTargets
        await harness.clock.advance(1); await harness.clock.advance(1); await harness.clock.advance(1)
        XCTAssertEqual(harness.controller.task?.phase, .uncertain)
        XCTAssertEqual(harness.clearedTargets, cleared)
        XCTAssertTrue(harness.controller.observer.isObserving)
    }

    func testTargetChangedWhileLocatingLooksAgainAutomatically() async throws {
        let harness = GuideHarness()
        try harness.controller.ask("Open the fixture settings", target: harness.screen.target)
        try await harness.reply { _ in GuideHarness.contextRequest() }
        let locating = try await harness.nextTurn()
        // Hover or loading changes the target after the capture the provider saw.
        harness.screen.paint(CGRect(x: 10, y: 10, width: 12, height: 8), value: 90)
        await harness.agent.reply(GuideHarness.step(locating))
        await settle()
        let again = try await harness.nextTurn()
        XCTAssertNotNil(again.image, "a fresh capture, not an error")
        XCTAssertEqual(harness.controller.metrics[.relocations], 1)
        try await harness.reply { GuideHarness.step($0) }
        XCTAssertEqual(harness.controller.task?.phase, .waiting)
        XCTAssertNil(harness.controller.error)
    }

    func testTargetThatKeepsChangingStopsWithinBudgetAndKeepsTheConversation() async throws {
        let harness = GuideHarness()
        try harness.controller.ask("Open the fixture settings", target: harness.screen.target)
        try await harness.reply { _ in GuideHarness.contextRequest() }
        for shade in [UInt8(200), 100, 0] {
            let turn = try await harness.nextTurn()
            harness.screen.paint(CGRect(x: 10, y: 10, width: 12, height: 8), value: shade)
            await harness.agent.reply(GuideHarness.step(turn))
            await settle()
        }
        XCTAssertEqual(harness.controller.metrics[.relocations], GuideStepBudget.relocations)
        XCTAssertEqual(harness.controller.error, "The target kept changing while it was being located · Retry when it settles.")
        let closed = await harness.agent.closed
        XCTAssertFalse(closed, "a host-side check keeps the provider conversation")
    }

    func testClarificationReplyTimeIsNotFirstInstructionLatency() async throws {
        let harness = GuideHarness()
        try harness.controller.ask("Open the fixture settings", target: harness.screen.target)
        try await harness.reply { _ in GuidePresentation(kind: .clarification, text: "Which report?") }
        await harness.clock.advance(30)
        try harness.controller.ask("The Q3 one", target: harness.screen.target)
        try await harness.reply { _ in GuideHarness.contextRequest() }
        try await harness.reply { GuideHarness.step($0) }
        let first = try XCTUnwrap(harness.controller.metrics.percentile(.firstInstruction, 0.5))
        XCTAssertLessThan(first, 30)
    }

    func testResumeWhileFocusIsElsewhereExplainsAndDoesNotRetry() async throws {
        let harness = GuideHarness()
        try await harness.startStep()
        harness.controller.pause()
        let turns = await harness.turnCount
        harness.screen.focused = false
        harness.controller.resume()
        await settle()
        XCTAssertEqual(harness.controller.error, "Activate the approved target window, then Resume; or choose Change target.")
        XCTAssertEqual(harness.controller.task?.phase, .paused)
        harness.screen.focused = true
        harness.controller.resume()
        await settle()
        let after = await harness.turnCount
        XCTAssertEqual(after, turns + 1, "Resume with focus back re-locates once")
    }

    func testClarificationDuringAWalkthroughAsksForAnAnswerInsteadOfReady() async throws {
        let harness = GuideHarness()
        try await harness.startStep()
        try await harness.act(time: 10, verdict: .confirmed)
        try await harness.reply { _ in GuidePresentation(kind: .clarification, text: "Anything else?") }
        XCTAssertEqual(harness.controller.status, "Question for you · answer in Quick Ask")
        XCTAssertTrue(harness.controller.awaitingClarification)
    }

    func testUndecidableOutcomeLooksOnceAtTheCurrentStateBeforeUncertainty() async throws {
        let harness = GuideHarness()
        try await harness.startStep()
        try await harness.act(time: 10, verdict: .unknown)
        await harness.clock.advance(GuideHarnessTiming.settle)
        try await harness.reply { GuideHarness.verdict($0, matches: false, state: .unknown) }
        let recovery = try await harness.nextTurn()
        XCTAssertNotEqual(recovery.purpose, .verification)
        XCTAssertNotNil(recovery.image)
        XCTAssertEqual(harness.controller.metrics[.recoveries], 1)
        await harness.agent.reply(GuideHarness.step(recovery, text: "Double-click Q3"))
        await settle()
        XCTAssertEqual(harness.controller.task?.phase, .waiting)
        XCTAssertEqual(harness.controller.task?.milestones.count, 0, "recovery never claims the earlier step")
    }

    func testVerificationTurnCarriesTheInstruction() async throws {
        let harness = GuideHarness()
        try await harness.startStep()
        harness.click(at: CGPoint(x: 15, y: 14), time: 10)
        await harness.clock.advance(0.5)
        let verification = try await harness.nextTurn()
        XCTAssertTrue(verification.message.contains("The user was asked: Click Settings"))
    }

    func testHoverFeedbackWhileLocatingIsToleratedUnderThePointer() async throws {
        let harness = GuideHarness()
        try harness.controller.ask("Open the fixture settings", target: harness.screen.target)
        try await harness.reply { _ in GuideHarness.contextRequest() }
        let locating = try await harness.nextTurn()
        harness.screen.pointer = harness.screen.point(CGPoint(x: 14, y: 12))
        harness.screen.paint(CGRect(x: 10, y: 10, width: 12, height: 8), value: 200)
        await harness.agent.reply(GuideHarness.step(locating))
        await settle()
        XCTAssertEqual(harness.controller.task?.phase, .waiting)
        XCTAssertEqual(harness.controller.metrics[.relocations], 0)
    }

    func testRenderingNoiseNeverRelocatesTheGuardedTarget() async throws {
        let harness = GuideHarness()
        try await harness.startStep()
        harness.screen.paint(CGRect(x: 12, y: 12, width: 1, height: 1), value: 0)
        for _ in 0..<4 { await harness.clock.advance(1) }
        XCTAssertEqual(harness.controller.task?.phase, .waiting)
        XCTAssertEqual(harness.controller.metrics[.relocations], 0)
    }

    func testRecoveryThatRepeatsTheStepAsksForReCheckNotAnotherClick() async throws {
        let harness = GuideHarness()
        try await harness.startStep()
        try await harness.act(time: 10, verdict: .contradicted)
        await harness.clock.advance(GuideHarnessTiming.settle)
        try await harness.reply { GuideHarness.verdict($0, matches: false, state: .contradicted) }
        try await harness.reply { GuideHarness.step($0) }
        XCTAssertEqual(harness.controller.task?.phase, .uncertain)
        XCTAssertEqual(harness.controller.status, "I couldn't confirm that · Re-check")
        XCTAssertTrue(harness.controller.observer.isObserving, "the mark stays watched")
    }

    func testRecoveryThatMovesOnPresentsTheNewStepNormally() async throws {
        let harness = GuideHarness()
        try await harness.startStep()
        try await harness.act(time: 10, verdict: .contradicted)
        await harness.clock.advance(GuideHarnessTiming.settle)
        try await harness.reply { GuideHarness.verdict($0, matches: false, state: .contradicted) }
        try await harness.reply { GuideHarness.step($0, pixel: CGRect(x: 40, y: 30, width: 10, height: 8), text: "Click Advanced") }
        XCTAssertEqual(harness.controller.task?.phase, .waiting)
    }
}
