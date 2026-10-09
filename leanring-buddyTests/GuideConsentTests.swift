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
        controller.displayFallbackAllowed = true
        let target = WindowCaptureTarget.display(42)
        controller.displayConsent.approve(display: 42, provider: controller.provider)
        controller.task = GuideTaskState(goal: "Scratch consent test")
        controller.task?.authorize(target)
        controller.currentTarget = target
        controller.displayFallbackAllowed = false
        #expect(controller.displayConsent.grant == nil)
        #expect(controller.task?.phase == .paused)
        #expect(controller.task?.grant?.paused == true)
        #expect(controller.task?.interruptions.contains(.sharingRevoked) == true)
        controller.resume()
        #expect(controller.task?.phase == .paused)
        #expect(controller.error == "Display sharing is not approved. Ask again to approve it, or choose a window.")
        #expect(!controller.isBusy)
    }
}
