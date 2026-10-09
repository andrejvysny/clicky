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
        try await harness.act(time: 10, verdict: .unknown)
        await harness.clock.advance(GuideHarnessTiming.settle)
        try await harness.reply { GuideHarness.verdict($0, matches: false, state: .unknown) }
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
        try await harness.act(time: 10, verdict: .unknown)
        await harness.clock.advance(GuideHarnessTiming.settle)
        try await harness.reply { GuideHarness.verdict($0, matches: false, state: .unknown) }
        let cleared = harness.clearedTargets
        await harness.clock.advance(1); await harness.clock.advance(1); await harness.clock.advance(1)
        XCTAssertEqual(harness.controller.task?.phase, .uncertain)
        XCTAssertEqual(harness.clearedTargets, cleared)
        XCTAssertTrue(harness.controller.observer.isObserving)
    }
}
