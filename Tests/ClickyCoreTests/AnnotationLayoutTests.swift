import XCTest
@testable import ClickyCore

final class AnnotationLayoutTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 640, height: 480)
    private let target = CGRect(x: 260, y: 180, width: 120, height: 32)

    func testValuePillAvoidsApplyButtonAndQuantityLabel() throws {
        let quantityLabel = CGRect(x: 150, y: 180, width: 92, height: 28)
        let applyButton = CGRect(x: 260, y: 234, width: 120, height: 32)
        let obstacles = CalloutObstacles(hard: [target, quantityLabel, applyButton])
        let placement = try XCTUnwrap(CalloutPlacement.placeIfClear(anchor: .box(target.insetBy(dx: -3, dy: -3)),
            size: CGSize(width: 39, height: 23), bounds: bounds, inset: 24, obstacles: obstacles))
        XCTAssertTrue(CalloutPlacement.isClear(placement.frame, anchor: .box(target), obstacles: obstacles))
        XCTAssertTrue(bounds.insetBy(dx: 24, dy: 24).contains(placement.frame))
    }

    func testLabelAvoidsControlsGhostAndValuePill() throws {
        let obstacles = CalloutObstacles(hard: [target, CGRect(x: 150, y: 180, width: 92, height: 28),
            CGRect(x: 260, y: 234, width: 120, height: 32), CGRect(x: 330, y: 140, width: 56, height: 56),
            CGRect(x: 394, y: 184, width: 39, height: 23)])
        let placement = try XCTUnwrap(CalloutPlacement.placeIfClear(anchor: .box(target), size: CGSize(width: 190, height: 44),
            bounds: bounds, inset: 24, obstacles: obstacles))
        XCTAssertTrue(CalloutPlacement.isClear(placement.frame, anchor: .box(target), obstacles: obstacles))
    }

    func testNoPlacementWhenControlsFillAvailableSpace() {
        let placement = CalloutPlacement.placeIfClear(anchor: .box(target), size: CGSize(width: 100, height: 40),
            bounds: bounds, inset: 24, obstacles: CalloutObstacles(hard: [bounds]))
        XCTAssertNil(placement)
    }

    func testBoundarySearchFindsPocketMissedByGrid() throws {
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 150)
        let target = CGRect(x: 10, y: 10, width: 20, height: 20)
        let obstacles = CalloutObstacles(hard: [CGRect(x: 0, y: 0, width: 79, height: 150),
            CGRect(x: 116, y: 0, width: 84, height: 150), CGRect(x: 0, y: 0, width: 200, height: 47),
            CGRect(x: 0, y: 78, width: 200, height: 72)])
        let placement = try XCTUnwrap(CalloutPlacement.placeIfClear(anchor: .box(target), size: CGSize(width: 20, height: 14),
            bounds: bounds, inset: 0, obstacles: obstacles))
        XCTAssertTrue(CalloutPlacement.isClear(placement.frame, anchor: .box(target), obstacles: obstacles))
        XCTAssertGreaterThanOrEqual(placement.frame.minX, 87)
        XCTAssertLessThanOrEqual(placement.frame.maxX, 108)
        XCTAssertGreaterThanOrEqual(placement.frame.minY, 55)
        XCTAssertLessThanOrEqual(placement.frame.maxY, 70)
    }

    func testBlockedLeaderIsOmittedWithoutCoveringControl() throws {
        let wall = CGRect(x: 0, y: 250, width: 640, height: 30)
        let obstacles = CalloutObstacles(hard: [CGRect(x: 0, y: 0, width: 640, height: 300)])
        let placement = try XCTUnwrap(CalloutPlacement.placeIfClear(anchor: .box(target), size: CGSize(width: 100, height: 40),
            bounds: bounds, inset: 24, obstacles: obstacles))
        XCTAssertNil(placement.leader)
        XCTAssertFalse(placement.frame.intersects(wall))
    }

    func testOversizedOrNonfiniteDimensionsFailClosed() {
        for size in [CGSize(width: 1000, height: 40), CGSize(width: CGFloat.infinity, height: 40),
                     CGSize(width: CGFloat.nan, height: 40)] {
            XCTAssertNil(CalloutPlacement.placeIfClear(anchor: .box(target), size: size,
                bounds: bounds, inset: 24, obstacles: .none))
        }
        XCTAssertNil(CalloutPlacement.placeIfClear(anchor: .box(target), size: CGSize(width: 40, height: 20),
            bounds: .infinite, inset: 24, obstacles: .none))
    }

    func testDenseBoundarySearchIsBoundedAndKeepsEveryObstacle() {
        let controls: [CGRect] = (0..<200).map { index in
            let x = CGFloat((index * 37) % 550) + 20
            let y = CGFloat((index * 29) % 370) + 20
            return CGRect(x: x, y: y, width: 20, height: 14)
        }
        let size = CGSize(width: 100, height: 40)
        let edges = controls.map { $0.insetBy(dx: -CalloutPlacement.clearance, dy: -CalloutPlacement.clearance) }
        let slots = CalloutPlacement.boundarySpace(for: .box(target), size: size, bounds: bounds, inset: 24, obstacles: edges)
        XCTAssertEqual(slots.count, CalloutPlacement.boundaryCoordinateLimit * CalloutPlacement.boundaryCoordinateLimit)
        XCTAssertEqual(slots, CalloutPlacement.boundarySpace(for: .box(target), size: size,
            bounds: bounds, inset: 24, obstacles: edges.reversed()))
        let obstacles = CalloutObstacles(hard: controls)
        if let placement = CalloutPlacement.placeIfClear(anchor: .box(target), size: size,
                                                        bounds: bounds, inset: 24, obstacles: obstacles) {
            XCTAssertTrue(CalloutPlacement.isClear(placement.frame, anchor: .box(target), obstacles: obstacles))
            XCTAssertTrue(bounds.insetBy(dx: 24, dy: 24).contains(placement.frame))
        }
    }
}
