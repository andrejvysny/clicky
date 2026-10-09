import ApplicationServices
import XCTest
import ClickyCore
@testable import ClickyGuideNative

/// Established related dialogs/sheets are normal transitions; unrelated focus is not (CLICKY-9).
@MainActor
final class GuideSurfaceTests: XCTestCase {
    private let dialog = WindowCaptureTarget(processIdentifier: 4242, windowIdentifier: 78,
                                             applicationIdentifier: "fixture.clicky", applicationName: "Fixture")

    func testRelatedDialogOpenedByTheClickContinuesAutomatically() async throws {
        let harness = GuideHarness()
        try await harness.startStep()
        harness.click(at: CGPoint(x: 15, y: 14), time: 10)
        harness.screen.related = [dialog]
        harness.controller.observer.receiveAccessibility(kAXFocusedWindowChangedNotification as String)
        XCTAssertNotEqual(harness.controller.task?.phase, .paused, "a related dialog is not an app switch")
        await harness.clock.advance(0.5)
        let verification = try await harness.nextTurn()
        XCTAssertEqual(verification.purpose, .verification)
        XCTAssertEqual(verification.context?.includedWindows.count, 2, "the dialog joins the capture as an established surface")
        try await harness.reply { GuideHarness.verdict($0, matches: true) }
        try await harness.reply { GuideHarness.step($0, text: "Click OK in the dialog") }
        XCTAssertEqual(harness.controller.task?.phase, .waiting)
        XCTAssertEqual(harness.controller.metrics[.relocations], 0)
    }

    func testDialogWithoutAnAttemptReGroundsOnTheActiveSurface() async throws {
        let harness = GuideHarness()
        try await harness.startStep()
        harness.screen.related = [dialog]
        harness.controller.observer.receiveAccessibility(kAXFocusedWindowChangedNotification as String)
        let relocation = try await harness.nextTurn()
        XCTAssertNotNil(relocation.image)
        XCTAssertEqual(harness.controller.metrics[.relocations], 1)
    }

    func testFocusOutsideTheSurfaceGroupIsATemporarySwitch() async throws {
        let harness = GuideHarness()
        try await harness.startStep()
        harness.screen.focused = false
        harness.controller.observer.receiveAccessibility(kAXFocusedWindowChangedNotification as String)
        XCTAssertEqual(harness.controller.task?.interruptions, [.appSwitch])
        XCTAssertEqual(harness.controller.task?.grant?.paused, false)
    }

    func testClosedTargetNeedsDeliberateRecovery() async throws {
        let harness = GuideHarness()
        try await harness.startStep()
        harness.screen.bounds = nil
        harness.controller.observer.receiveAccessibility(kAXUIElementDestroyedNotification as String)
        XCTAssertEqual(harness.controller.task?.interruptions, [.targetClosed])
        harness.controller.activationChanged()
        XCTAssertEqual(harness.controller.task?.phase, .paused)
        XCTAssertEqual(harness.controller.task?.grant?.paused, true)
    }
}
