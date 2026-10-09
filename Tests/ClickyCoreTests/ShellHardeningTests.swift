import XCTest
@testable import ClickyCore

final class ShellHardeningTests: XCTestCase {
    func testInvalidMeasuredHeightUsesMinimumAndOversizedHeightIsBounded() {
        for height: CGFloat in [0, -12, .nan, .infinity, -.infinity] {
            XCTAssertEqual(ShellPanelLayout.height(measured: height, minimum: 30, maximum: 800), 30)
        }
        XCTAssertEqual(ShellPanelLayout.height(measured: 1200, minimum: 30, maximum: 800), 800)
        XCTAssertEqual(ShellPanelLayout.height(measured: 88, minimum: 240, maximum: 200), 200)
    }

    func testGrowthKeepsComposerTopFixedAndClipsToAvailableRoom() {
        let visible = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
        let placed = CGRect(x: -800, y: -200, width: 380, height: 900)
        let result = ShellPanelLayout.anchoredFrame(placed, top: 500, visibleFrame: visible)
        XCTAssertEqual(result.maxY, 500)
        XCTAssertEqual(result.height, 700)
        XCTAssertTrue(visible.contains(result))
        XCTAssertTrue(ShellPanelLayout.isValid(result))
    }

    func testOnlyPositiveFiniteFramesAreAccepted() {
        XCTAssertFalse(ShellPanelLayout.isValid(.zero))
        XCTAssertFalse(ShellPanelLayout.isValid(CGRect(x: 0, y: 0, width: -10, height: 20)))
        XCTAssertFalse(ShellPanelLayout.isValid(CGRect(x: CGFloat.infinity, y: 0, width: 10, height: 20)))
        XCTAssertTrue(ShellPanelLayout.isValid(CGRect(x: -10, y: -20, width: 10, height: 20)))
    }

    func testConflictPreservesWorkingShortcutAndRollbackDoesNotRegisterAgain() {
        var registration = ShortcutRegistration<Int>()
        let original = ShortcutBinding(keyCode: 49, modifiers: 0xA00)
        let conflicting = ShortcutBinding(keyCode: 0, modifiers: 0x100)
        var acquisitions = 0
        var released: [Int] = []
        XCTAssertTrue(registration.register(original, acquire: { _ in acquisitions += 1; return 1 }, release: { released.append($0) }))
        XCTAssertFalse(registration.register(conflicting, acquire: { _ in acquisitions += 1; return nil }, release: { released.append($0) }))
        XCTAssertEqual(registration.binding, original)
        XCTAssertTrue(released.isEmpty)
        XCTAssertTrue(registration.register(original, acquire: { _ in XCTFail("Rollback must retain the existing registration"); return nil }, release: { released.append($0) }))
        XCTAssertEqual(acquisitions, 2)
        registration.unregister { released.append($0) }
        XCTAssertEqual(released, [1])
        XCTAssertNil(registration.binding)
    }

    func testSuccessfulReplacementAcquiresBeforeReleasingOriginal() {
        var registration = ShortcutRegistration<Int>()
        var events: [String] = []
        XCTAssertTrue(registration.register(ShortcutBinding(keyCode: 49, modifiers: 0xA00), acquire: { _ in 1 }, release: { _ in XCTFail("No previous resource") }))
        XCTAssertTrue(registration.register(ShortcutBinding(keyCode: 0, modifiers: 0x100), acquire: { _ in
            events.append("acquire")
            return 2
        }, release: { events.append("release \($0)") }))
        XCTAssertEqual(events, ["acquire", "release 1"])
        registration.unregister { events.append("release \($0)") }
        registration.unregister { _ in XCTFail("Must not release twice") }
        XCTAssertEqual(events, ["acquire", "release 1", "release 2"])
    }

    func testInitialRegistrationFailureLeavesNoActiveShortcut() {
        var registration = ShortcutRegistration<Int>()
        XCTAssertFalse(registration.register(ShortcutBinding(keyCode: 49, modifiers: 0xA00), acquire: { _ in nil }, release: { _ in XCTFail("No resource to release") }))
        XCTAssertNil(registration.binding)
    }
}
