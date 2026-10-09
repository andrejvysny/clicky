import ApplicationServices
import XCTest
import ClickyCore
@testable import ClickyGuideNative

/// Automatic loop hardening on the production coordinator: stable targets (CLICKY-10), attempts (CLICKY-14),
/// AX-first and bounded verification (CLICKY-15) and progression with goal checks (CLICKY-16).
@MainActor
final class GuideLoopTests: XCTestCase {
    private let target = CGRect(x: 10, y: 10, width: 12, height: 8)

    func testHoverFeedbackOnTheTargetDoesNotInvalidateIt() async throws {
        let harness = GuideHarness()
        try await harness.startStep()
        harness.screen.pointer = harness.screen.point(CGPoint(x: 14, y: 12))
        harness.screen.paint(target, value: 120)
        await harness.clock.advance(1); await harness.clock.advance(1); await harness.clock.advance(1)
        XCTAssertEqual(harness.controller.task?.phase, .waiting)
        let turns = await harness.turnCount
        XCTAssertEqual(turns, 2)
        XCTAssertEqual(harness.controller.metrics[.relocations], 0)
    }

    func testPersistentReplacementWithPointerAwayRelocatesTheSameStep() async throws {
        let harness = GuideHarness()
        try await harness.startStep()
        harness.screen.paint(target, value: 0)
        await harness.clock.advance(1)
        XCTAssertEqual(harness.controller.task?.phase, .waiting, "one mismatch may be a transient animation")
        await harness.clock.advance(1)
        let relocation = try await harness.nextTurn()
        XCTAssertNotNil(relocation.image)
        XCTAssertEqual(harness.controller.status, "Finding the control")
        try await harness.reply { GuideHarness.step($0, pixel: CGRect(x: 40, y: 30, width: 10, height: 8)) }
        XCTAssertEqual(harness.controller.task?.phase, .waiting)
        XCTAssertEqual(harness.controller.task?.milestones.count, 0, "re-grounding never claims progress")
        XCTAssertEqual(harness.shownTargets.last, CGRect(x: 140, y: 130, width: 10, height: 8))
    }

    func testWindowMoveRelocatesImmediatelyAndBudgetEndsInUncertainty() async throws {
        let harness = GuideHarness()
        try await harness.startStep()
        for move in 1...GuideStepBudget.relocations {
            harness.screen.bounds = harness.screen.bounds?.offsetBy(dx: 5, dy: 0)
            await harness.clock.advance(1)
            try await harness.reply { GuideHarness.step($0) }
            XCTAssertEqual(harness.controller.metrics[.relocations], move)
        }
        harness.screen.bounds = harness.screen.bounds?.offsetBy(dx: 5, dy: 0)
        await harness.clock.advance(1)
        XCTAssertEqual(harness.controller.task?.phase, .uncertain)
        XCTAssertFalse(harness.controller.isBusy)
    }

    func testPendingOutcomeWaitsForTheAppThenRechecksOnce() async throws {
        let harness = GuideHarness()
        try await harness.startStep()
        try await harness.act(time: 10, verdict: .pending)
        XCTAssertEqual(harness.controller.status, "Waiting for the app")
        let before = await harness.turnCount
        await harness.clock.advance(1)
        let during = await harness.turnCount
        XCTAssertEqual(during, before, "no model polling while waiting")
        await harness.clock.advance(GuideHarnessTiming.appWait)
        try await harness.reply { GuideHarness.verdict($0, matches: true) }
        try await harness.reply { GuideHarness.step($0, text: "Click Apply") }
        XCTAssertEqual(harness.controller.task?.milestones.map(\.completion), [.verified])
        XCTAssertEqual(harness.controller.metrics[.visionChecks], 2)
    }

    func testAccessibilityConfirmsOutcomeWithoutAVerificationTurn() async throws {
        let harness = GuideHarness()
        harness.screen.outcome = false
        try await harness.startStep()
        harness.click(at: CGPoint(x: 15, y: 14), time: 10)
        harness.screen.outcome = true
        await harness.clock.advance(0.5)
        let next = try await harness.nextTurn()
        XCTAssertNotEqual(next.purpose, .verification)
        XCTAssertEqual(harness.controller.task?.milestones.map(\.completion), [.verified])
        XCTAssertEqual(harness.controller.metrics[.localConfirmations], 1)
        XCTAssertEqual(harness.controller.metrics[.visionChecks], 0)
    }

    func testSlowAccessibilityOutcomeWaitsLocallyThenFallsBackToVision() async throws {
        let harness = GuideHarness()
        harness.screen.outcome = false
        try await harness.startStep()
        harness.click(at: CGPoint(x: 15, y: 14), time: 10)
        await harness.clock.advance(0.5)
        XCTAssertEqual(harness.controller.status, "Waiting for the app")
        for _ in 0..<6 { await harness.clock.advance(GuideHarnessTiming.appPoll) }
        XCTAssertEqual(harness.screen.captures, 2, "nothing captured while waiting locally")
        let waiting = await harness.turnCount
        XCTAssertEqual(waiting, 2, "and nothing sent")
        for _ in 0..<8 { await harness.clock.advance(GuideHarnessTiming.appPoll) }
        let verification = try await harness.nextTurn()
        XCTAssertEqual(verification.purpose, .verification)
    }

    func testPreSatisfiedAccessibilityStateCannotVerifyTheStep() async throws {
        let harness = GuideHarness()
        harness.screen.outcome = true
        try await harness.startStep()
        try await harness.act(time: 10, verdict: .confirmed)
        XCTAssertEqual(harness.controller.metrics[.localConfirmations], 0)
        XCTAssertEqual(harness.controller.metrics[.visionChecks], 1)
    }

    func testUncertaintyKeepsWatchingAndANewAttemptReArmsABoundedCheck() async throws {
        let harness = GuideHarness()
        try await harness.startStep()
        try await harness.reachUncertainty(time: 10)
        XCTAssertEqual(harness.controller.task?.phase, .uncertain)
        XCTAssertTrue(harness.controller.observer.isObserving, "uncertainty keeps a safe watch on the target")
        XCTAssertEqual(harness.shownTargets.count, 3, "the target stays marked")
        try await harness.act(time: 20, verdict: .confirmed)
        try await harness.reply { GuideHarness.step($0, text: "Click Apply") }
        XCTAssertEqual(harness.controller.task?.milestones.map(\.completion), [.verified])
        XCTAssertEqual(harness.controller.metrics[.manualAcknowledgements], 0)
    }

    func testAttemptEpisodesAreBoundedPerStep() async throws {
        let harness = GuideHarness()
        try await harness.startStep()
        for episode in 0..<GuideStepBudget.episodes {
            try await harness.act(time: Double(10 + episode * 10), verdict: .unknown)
            await harness.clock.advance(GuideHarnessTiming.settle)
            try await harness.reply { GuideHarness.verdict($0, matches: false, state: .unknown) }
            // The first undecidable episode spends the step's single recovery look.
            if episode == 0 { try await harness.reply { GuideHarness.step($0) } }
        }
        let spent = await harness.turnCount
        harness.click(at: CGPoint(x: 15, y: 14), time: 100)
        await harness.clock.advance(1)
        let after = await harness.turnCount
        XCTAssertEqual(after, spent, "further clicks need an explicit Re-check")
        XCTAssertEqual(harness.controller.task?.phase, .uncertain)
        harness.controller.checkNow()
        _ = try await harness.nextTurn()
    }

    func testFocusNoiseWithoutAnAttemptNeverReachesTheProvider() async throws {
        let harness = GuideHarness()
        try await harness.startStep()
        harness.controller.observer.receiveAccessibility(kAXFocusedUIElementChangedNotification as String)
        harness.controller.observer.receiveAccessibility(kAXValueChangedNotification as String)
        await harness.clock.advance(1)
        let turns = await harness.turnCount
        XCTAssertEqual(turns, 2)
        XCTAssertEqual(harness.controller.task?.phase, .waiting)
    }

    func testContradictedOutcomeAdaptsOnceFromTheCurrentState() async throws {
        let harness = GuideHarness()
        try await harness.startStep()
        try await harness.act(time: 10, verdict: .contradicted)
        await harness.clock.advance(GuideHarnessTiming.settle)
        try await harness.reply { GuideHarness.verdict($0, matches: false, state: .contradicted) }
        let recovery = try await harness.nextTurn()
        XCTAssertEqual(recovery.purpose, .continuation)
        XCTAssertTrue(recovery.message.contains("was not confirmed"))
        try await harness.reply { GuideHarness.step($0, pixel: CGRect(x: 40, y: 30, width: 10, height: 8), text: "Click Advanced") }
        XCTAssertEqual(harness.controller.task?.phase, .waiting)
        XCTAssertEqual(harness.controller.task?.milestones.count, 0, "no fabricated progress")
    }

    func testCompletionIsAcceptedOnlyAfterStoredGoalChecksVerify() async throws {
        let harness = GuideHarness()
        try await harness.startStep()
        try await harness.act(time: 10)
        try await harness.reply { GuideHarness.completed($0) }
        let goal = try await harness.nextTurn()
        XCTAssertEqual(goal.purpose, .verification)
        XCTAssertTrue(goal.message.contains("Settings panel is open"), "stored goal check is verified")
        XCTAssertNotEqual(harness.controller.task?.phase, .completed)
        try await harness.reply { GuideHarness.verdict($0, matches: true) }
        XCTAssertEqual(harness.controller.task?.phase, .completed)
        XCTAssertEqual(harness.controller.status, "Task complete · verified")
    }

    func testRevertedGoalBlocksCompletionAndContinuesOnce() async throws {
        let harness = GuideHarness()
        try await harness.startStep()
        try await harness.act(time: 10)
        try await harness.reply { GuideHarness.completed($0) }
        try await harness.reply { GuideHarness.verdict($0, matches: false, state: .contradicted) }
        let continuation = try await harness.nextTurn()
        XCTAssertTrue(continuation.message.contains("did not confirm the goal"))
        try await harness.reply { GuideHarness.completed($0) }
        try await harness.reply { GuideHarness.verdict($0, matches: false, state: .contradicted) }
        XCTAssertEqual(harness.controller.task?.phase, .uncertain)
        XCTAssertNotEqual(harness.controller.status, "Task complete · verified")
    }

    func testFiveStepClickAndDoubleClickWorkflowNeedsNoGuideControls() async throws {
        let harness = GuideHarness()
        try await harness.startStep()
        let actions: [GuideAction.Kind] = [.double_click, .click, .double_click, .click]
        var time = 10.0
        for (index, next) in actions.enumerated() {
            let count = harness.controller.task?.step?.action?.kind == .double_click ? 2 : 1
            try await harness.act(count, time: time)
            try await harness.reply { GuideHarness.step($0, action: next, text: "Step \(index + 2)") }
            XCTAssertEqual(harness.controller.task?.phase, .waiting)
            time += 10
        }
        try await harness.act(harness.controller.task?.step?.action?.kind == .double_click ? 2 : 1, time: time)
        try await harness.reply { GuideHarness.completed($0) }
        try await harness.reply { GuideHarness.verdict($0, matches: true) }
        XCTAssertEqual(harness.controller.task?.phase, .completed)
        XCTAssertEqual(harness.controller.task?.milestones.map(\.completion), Array(repeating: .verified, count: 5))
        XCTAssertEqual(harness.controller.metrics[.manualAcknowledgements], 0)
        XCTAssertEqual(harness.controller.metrics[.relocations], 0)
        XCTAssertEqual(harness.controller.metrics[.attempts], 5)
        print("five-step coordinator metrics:", harness.controller.metrics.summary)
    }

    // MARK: Back (CLICKY-36)

    func testBackBrowsesHistoryWithoutProviderRequestsOrDuplicateProgress() async throws {
        let harness = GuideHarness()
        try await harness.startStep()
        try await harness.act(time: 10)
        try await harness.reply { GuideHarness.step($0, text: "Click B") }
        try await harness.act(time: 20)
        try await harness.reply { GuideHarness.step($0, text: "Click C") }
        let turns = await harness.turnCount
        harness.controller.back()
        XCTAssertEqual(harness.controller.task?.historyItem?.instruction, "Click B")
        XCTAssertFalse(harness.controller.observer.isObserving, "nothing can complete while browsing")
        harness.controller.back()
        XCTAssertEqual(harness.controller.task?.historyItem?.instruction, "Click Settings")
        harness.click(at: CGPoint(x: 15, y: 14), time: 30)
        await harness.clock.advance(1)
        let browsing = await harness.turnCount
        XCTAssertEqual(browsing, turns, "Back sends nothing and clicks do not count")
        harness.controller.forward(); harness.controller.forward()
        await settle()
        XCTAssertNil(harness.controller.task?.historyIndex)
        XCTAssertEqual(harness.controller.task?.step?.text, "Click C")
        XCTAssertTrue(harness.controller.observer.isObserving, "returning revalidated the active step")
        XCTAssertEqual(harness.controller.task?.milestones.count, 2)
        let after = await harness.turnCount
        XCTAssertEqual(after, turns)
    }
}

enum GuideHarnessTiming {
    static let appWait = 3.0
    static let appPoll = 0.25
    static let settle = 1.0
}
