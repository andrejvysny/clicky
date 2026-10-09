import XCTest
@testable import ClickyCore

final class GuideControlAvailabilityTests: XCTestCase {
    func testEndAndPauseStayEnabledInEveryBusyPhase() {
        for phase in [GuideTaskState.Phase.locating, .waiting, .verifying, .uncertain] {
            let controls = GuideControlAvailability(phase: phase, isBusy: true, hasStep: true)
            XCTAssertTrue(controls.end, "\(phase)")
            XCTAssertTrue(controls.pause, "\(phase)")
            XCTAssertFalse(controls.next, "\(phase)")
            XCTAssertFalse(controls.retry, "\(phase)")
            XCTAssertFalse(controls.recheck, "\(phase)")
            XCTAssertFalse(controls.changeTarget, "\(phase)")
        }
    }

    func testPausedTaskOffersResumeAndEndButNotPause() {
        let controls = GuideControlAvailability(phase: .paused, isBusy: false, hasStep: true)
        XCTAssertTrue(controls.resume)
        XCTAssertTrue(controls.end)
        XCTAssertFalse(controls.pause)
    }

    func testFinishedTaskOffersNoActions() {
        let controls = GuideControlAvailability(phase: .completed, isBusy: false, hasStep: false)
        XCTAssertFalse(controls.end || controls.pause || controls.next || controls.retry || controls.resume)
    }

    func testIdleWaitingStepEnablesRecheckAndManualNext() {
        let controls = GuideControlAvailability(phase: .waiting, isBusy: false, hasStep: true)
        XCTAssertTrue(controls.recheck && controls.next && controls.pause && controls.end)
    }
}
