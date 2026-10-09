import XCTest
@testable import ClickyCore

final class GuideMouseReleaseTests: XCTestCase {
    private let target = CGRect(x: 10, y: 20, width: 100, height: 40)
    private let inside = CGPoint(x: 50, y: 30)
    private let outside = CGPoint(x: 500, y: 300)

    func testNativeZeroCountReleaseUsesOnlyPairedPressCount() throws {
        var releases = GuideMouseReleaseTracker(target: target)
        var matcher = GuideInteractionMatcher(action: GuideAction(kind: .click), target: target)
        XCTAssertTrue(releases.began(button: 0, count: 1, point: inside, timestamp: 1))
        XCTAssertEqual(releases.pressedButton, 0)
        let count = try XCTUnwrap(releases.released(button: 0, count: 0, point: inside, timestamp: 1.1))
        XCTAssertEqual(count, 1)
        XCTAssertTrue(matcher.mouse(button: 0, count: count, point: inside, timestamp: 1.1))
        XCTAssertNil(releases.pressedButton)
        XCTAssertNil(releases.released(button: 0, count: 0, point: inside, timestamp: 1.2))
    }

    func testDoubleClickCardinalityIsPreservedAcrossZeroCountReleases() throws {
        var releases = GuideMouseReleaseTracker(target: target)
        var doubleClick = GuideInteractionMatcher(action: GuideAction(kind: .double_click), target: target)
        var singleClick = GuideInteractionMatcher(action: GuideAction(kind: .click), target: target)
        releases.began(button: 0, count: 1, point: inside, timestamp: 1)
        let first = try XCTUnwrap(releases.released(button: 0, count: 0, point: inside, timestamp: 1.1))
        XCTAssertFalse(doubleClick.mouse(button: 0, count: first, point: inside, timestamp: 1.1))
        releases.began(button: 0, count: 2, point: inside, timestamp: 1.2)
        let second = try XCTUnwrap(releases.released(button: 0, count: 0, point: inside, timestamp: 1.3))
        XCTAssertEqual(second, 2)
        XCTAssertTrue(doubleClick.mouse(button: 0, count: second, point: inside, timestamp: 1.3))
        XCTAssertFalse(singleClick.mouse(button: 0, count: second, point: inside, timestamp: 1.3))
    }

    func testActualReleaseCountsMustAgreeWithPress() {
        var releases = GuideMouseReleaseTracker(target: target)
        releases.began(button: 0, count: 2, point: inside, timestamp: 1)
        XCTAssertEqual(releases.released(button: 0, count: 2, point: inside, timestamp: 1.1), 2)
        releases.began(button: 0, count: 1, point: inside, timestamp: 2)
        XCTAssertNil(releases.released(button: 0, count: 2, point: inside, timestamp: 2.1))
        releases.began(button: 0, count: 2, point: inside, timestamp: 3)
        XCTAssertNil(releases.released(button: 0, count: 1, point: inside, timestamp: 3.1))
    }

    func testOrphanWrongButtonAndOutsideReleasesAreRejected() {
        var releases = GuideMouseReleaseTracker(target: target)
        XCTAssertNil(releases.released(button: 0, count: 1, point: inside, timestamp: 1))
        releases.began(button: 0, count: 1, point: inside, timestamp: 2)
        XCTAssertNil(releases.released(button: 1, count: 0, point: inside, timestamp: 2.1))
        XCTAssertNil(releases.pressedButton)
        XCTAssertFalse(releases.began(button: 0, count: 1, point: outside, timestamp: 3))
        XCTAssertNil(releases.released(button: 0, count: 0, point: inside, timestamp: 3.1))
        releases.began(button: 0, count: 1, point: inside, timestamp: 4)
        XCTAssertNil(releases.released(button: 0, count: 0, point: outside, timestamp: 4.1))
        XCTAssertNil(releases.released(button: 0, count: 0, point: inside, timestamp: 4.2))
    }

    func testDraggedOrInvalidatedPressCannotProduceLaterClick() {
        var releases = GuideMouseReleaseTracker(target: target)
        releases.began(button: 0, count: 1, point: inside, timestamp: 1)
        releases.cancel()
        XCTAssertNil(releases.pressedButton)
        XCTAssertNil(releases.released(button: 0, count: 0, point: inside, timestamp: 1.1))
        releases.began(button: 0, count: 1, point: inside, timestamp: 2)
        XCTAssertEqual(releases.released(button: 0, count: 0, point: inside, timestamp: 2.1), 1)
    }

    func testHeldPressDoesNotExpireBeforeCorrespondingRelease() {
        var releases = GuideMouseReleaseTracker(target: target)
        releases.began(button: 0, count: 1, point: inside, timestamp: 1)
        XCTAssertEqual(releases.pressedButton, 0)
        XCTAssertEqual(releases.released(button: 0, count: 0, point: inside, timestamp: 21), 1)
    }

    func testRightClickUsesSameButtonPair() throws {
        var releases = GuideMouseReleaseTracker(target: target)
        var matcher = GuideInteractionMatcher(action: GuideAction(kind: .right_click), target: target)
        releases.began(button: 1, count: 1, point: inside, timestamp: 1)
        let count = try XCTUnwrap(releases.released(button: 1, count: 0, point: inside, timestamp: 1.1))
        XCTAssertTrue(matcher.mouse(button: 1, count: count, point: inside, timestamp: 1.1))
    }

    func testInvalidPressOrReleaseMetadataFailsClosed() {
        var releases = GuideMouseReleaseTracker(target: target)
        XCTAssertFalse(releases.began(button: 0, count: 0, point: inside, timestamp: 1))
        XCTAssertFalse(releases.began(button: 2, count: 1, point: inside, timestamp: 1))
        XCTAssertFalse(releases.began(button: 0, count: 1, point: inside, timestamp: .nan))
        for releaseTime in [0.5, 1, Double.infinity] {
            releases.began(button: 0, count: 1, point: inside, timestamp: 1)
            XCTAssertNil(releases.released(button: 0, count: 0, point: inside, timestamp: releaseTime))
        }
        releases.began(button: 0, count: 1, point: inside, timestamp: 2)
        XCTAssertNil(releases.released(button: 0, count: -1, point: inside, timestamp: 2.1))
    }
}
