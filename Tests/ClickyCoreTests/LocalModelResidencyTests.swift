import XCTest
@testable import ClickyCore

final class LocalModelResidencyTests: XCTestCase {
    func testManualIsDefaultAndNeverLoadsImplicitly() {
        let settings = LocalResidencySettings()
        for group in LocalModelGroup.allCases {
            XCTAssertEqual(settings[group].load, .manual)
            XCTAssertNil(settings[group].idleUnloadMinutes)
            XCTAssertEqual(LocalResidencyPlanner.admission(policy: settings[group], isLoaded: false), .needsExplicitLoad)
        }
        XCTAssertTrue(LocalResidencyPlanner.groupsToPreload(settings).isEmpty)
    }

    func testExplicitRunAndOptInPoliciesMayLoad() {
        XCTAssertEqual(LocalResidencyPlanner.admission(policy: LocalResidencyPolicy(), isLoaded: false, explicitRun: true), .loadAutomatically)
        XCTAssertEqual(LocalResidencyPlanner.admission(policy: LocalResidencyPolicy(load: .onDemand), isLoaded: false), .loadAutomatically)
        XCTAssertEqual(LocalResidencyPlanner.admission(policy: LocalResidencyPolicy(), isLoaded: true), .ready)
    }

    func testPreloadIsPerGroupSoVoiceNeverPullsVision() {
        var settings = LocalResidencySettings()
        settings.speech = LocalResidencyPolicy(load: .preloadAtStartup)
        settings.cleanup = LocalResidencyPolicy(load: .preloadAtStartup)
        XCTAssertEqual(LocalResidencyPlanner.groupsToPreload(settings), [.cleanup, .speech])
        XCTAssertEqual(settings.vision.load, .manual)
    }

    func testSettingsRoundTripAndClampIdleMinutes() throws {
        var settings = LocalResidencySettings()
        settings.vision = LocalResidencyPolicy(load: .onDemand, idleUnloadMinutes: 0)
        XCTAssertEqual(settings.vision.idleUnloadMinutes, 1)
        let decoded = try JSONDecoder().decode(LocalResidencySettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded, settings)
    }

    func testIdleTrackerSkipsBusyAndUnlimitedGroups() {
        var settings = LocalResidencySettings()
        settings.vision.idleUnloadMinutes = 5
        settings.speech.idleUnloadMinutes = 5
        var tracker = LocalIdleTracker()
        tracker.touch(.vision, at: 0)
        tracker.touch(.speech, at: 0)
        tracker.touch(.cleanup, at: 0)
        let loaded: Set<LocalModelGroup> = [.vision, .speech, .cleanup]
        XCTAssertEqual(tracker.due(at: 299, settings: settings, loaded: loaded, busy: []), [])
        XCTAssertEqual(tracker.due(at: 300, settings: settings, loaded: loaded, busy: [.speech]), [.vision])
        tracker.touch(.vision, at: 200)
        XCTAssertEqual(tracker.due(at: 301, settings: settings, loaded: loaded, busy: []), [.speech])
    }

    func testMemoryBudgetLeavesRoomForForegroundApps() {
        let gib: UInt64 = 1 << 30
        XCTAssertEqual(LocalResidencyPlanner.memoryAdmission(estimatedBytes: 4 * gib, residentBytes: 3 * gib, physicalMemory: 24 * gib), .ready)
        guard case .overBudget(_, let available) = LocalResidencyPlanner.memoryAdmission(estimatedBytes: 8 * gib, residentBytes: 4 * gib, physicalMemory: 24 * gib) else {
            return XCTFail("expected over budget")
        }
        XCTAssertLessThan(available, 8 * gib)
        XCTAssertGreaterThan(LocalResidencyPlanner.estimatedFootprint(weightBytes: 3_000_000_000), 3_000_000_000)
    }
}
