import Foundation
import Testing
@testable import Clicky

@MainActor
struct GuideConsentTests {
    @Test func revokingDisplaySharingPausesAndPreventsResume() throws {
        let name = "ClickyGuideConsentTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let controller = VisualGuideController()
        controller.defaults = defaults
        controller.displaySharingApproved = true
        let target = WindowCaptureTarget.display(42)
        controller.task = GuideTaskState(goal: "Scratch consent test")
        controller.task?.authorize(target)
        controller.currentTarget = target
        controller.displaySharingApproved = false
        #expect(controller.task?.phase == .paused)
        #expect(controller.task?.grant?.paused == true)
        controller.resume()
        #expect(controller.task?.phase == .paused)
        #expect(controller.error == "Display sharing is off. Enable it in Settings or choose a window.")
        #expect(!controller.isBusy)
    }
}
