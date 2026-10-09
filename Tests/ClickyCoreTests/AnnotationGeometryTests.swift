import XCTest
@testable import ClickyCore

final class AnnotationGeometryTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 1400, height: 900)
    private let inset: CGFloat = 16
    private let plate = CGSize(width: 200, height: 44)

    func testLabelNeverCoversItsTarget() {
        let target = CGRect(x: 600, y: 400, width: 160, height: 120)
        let placed = CalloutPlacement.place(anchor: .box(target), size: plate, bounds: bounds, inset: inset, obstacles: .none)
        XCTAssertFalse(placed.frame.intersects(target))
    }

    func testRingSlotZeroIsBelowTargetInYDown() {
        let target = CGRect(x: 600, y: 400, width: 160, height: 120)
        let placed = CalloutPlacement.place(anchor: .box(target), size: plate, bounds: bounds, inset: inset, obstacles: .none)
        XCTAssertEqual(placed.index, 0)
        XCTAssertGreaterThanOrEqual(placed.frame.minY, target.maxY)
    }

    func testLabelStaysInsideBoundsWhenItFits() {
        let corner = CGRect(x: 1350, y: 860, width: 40, height: 30)
        let placed = CalloutPlacement.place(anchor: .box(corner), size: plate, bounds: bounds, inset: inset, obstacles: .none)
        XCTAssertTrue(bounds.insetBy(dx: inset, dy: inset).contains(placed.frame))
        XCTAssertFalse(placed.frame.intersects(corner))
    }

    func testLabelStepsAsideForExistingLabel() {
        let target = CGRect(x: 600, y: 400, width: 160, height: 120)
        let first = CalloutPlacement.place(anchor: .box(target), size: plate, bounds: bounds, inset: inset, obstacles: .none).frame
        let second = CalloutPlacement.place(anchor: .box(target), size: plate, bounds: bounds, inset: inset,
                                            obstacles: CalloutObstacles(hard: [first]))
        XCTAssertNotEqual(second.frame, first)
        XCTAssertFalse(second.frame.intersects(first.insetBy(dx: -8, dy: -8)))
        XCTAssertFalse(second.frame.intersects(target))
    }

    func testArrowLabelStaysOffItsShaft() {
        let tail = CGPoint(x: 900, y: 400), tip = CGPoint(x: 640, y: 300)
        let placed = CalloutPlacement.place(anchor: .shaft(from: tail, to: tip), size: plate, bounds: bounds,
                                            inset: inset, obstacles: .none)
        XCTAssertFalse(placed.frame.intersects(CalloutPlacement.corridor(from: tail, to: tip)))
    }

    func testPillObstacleKeepsLabelApart() {
        let target = CGRect(x: 600, y: 400, width: 160, height: 120)
        let pill = CGRect(x: 600, y: 530, width: 90, height: 24)
        let placed = CalloutPlacement.place(anchor: .box(target), size: plate, bounds: bounds, inset: inset,
                                            obstacles: CalloutObstacles(hard: [pill]))
        XCTAssertFalse(placed.frame.intersects(pill))
        XCTAssertFalse(placed.frame.intersects(target))
    }

    func testArrowTipHugsRectEdgeAndTailStaysInBounds() {
        let rect = CGRect(x: 500, y: 300, width: 120, height: 40)
        for seed in UInt64(1)...40 {
            let arrow = AnnotationGeometry.arrowToRect(rect, bounds: bounds, seed: seed)
            let outside = rect.insetBy(dx: -8, dy: -8)
            XCTAssertTrue(outside.contains(arrow.tip), "seed \(seed)")
            XCTAssertFalse(rect.contains(arrow.tip), "seed \(seed)")
            XCTAssertTrue(bounds.contains(arrow.tail), "seed \(seed)")
        }
    }

    func testArrowFromPointApproachesFacingSide() {
        let rect = CGRect(x: 500, y: 300, width: 120, height: 40)
        let arrow = AnnotationGeometry.arrowToRect(rect, bounds: bounds, from: CGPoint(x: 100, y: 320), seed: 3)
        XCTAssertEqual(arrow.tip.x, rect.minX - 7, accuracy: 0.001)
    }

    func testCircleRectMinimumAndContainsTarget() {
        let tiny = CGRect(x: 100, y: 100, width: 4, height: 4)
        let circle = AnnotationGeometry.circleRect(around: tiny)
        XCTAssertGreaterThanOrEqual(circle.width, 56)
        XCTAssertGreaterThanOrEqual(circle.height, 56)
        XCTAssertTrue(circle.contains(tiny))
        let big = CGRect(x: 0, y: 0, width: 800, height: 600)
        XCTAssertEqual(AnnotationGeometry.circleRect(around: big).width, 800 + 68, accuracy: 0.001)
    }

    func testUnderlineSitsBelowTargetWithOverhang() {
        let target = CGRect(x: 100, y: 200, width: 80, height: 20)
        let line = AnnotationGeometry.underline(under: target)
        XCTAssertEqual(line.start.y, target.maxY + 12, accuracy: 0.001)
        XCTAssertEqual(line.start.x, target.minX - 6, accuracy: 0.001)
        XCTAssertEqual(line.end.x, target.maxX + 6, accuracy: 0.001)
    }

    func testHighlightGrowsByTwo() {
        let target = CGRect(x: 10, y: 10, width: 50, height: 20)
        XCTAssertEqual(AnnotationGeometry.highlightRect(target), CGRect(x: 8, y: 8, width: 54, height: 24))
    }

    func testBarbsLengthClamped() {
        let short = AnnotationGeometry.arrowBarbs(tip: CGPoint(x: 10, y: 0), tail: .zero)
        XCTAssertEqual(hypot(short.0.x - 10, short.0.y), 12, accuracy: 0.001)
        let long = AnnotationGeometry.arrowBarbs(tip: CGPoint(x: 400, y: 0), tail: .zero)
        XCTAssertEqual(hypot(long.0.x - 400, long.0.y), 28, accuracy: 0.001)
    }

    func testSeedHashIsStable() {
        XCTAssertEqual(AnnotationGeometry.fnv1a64(""), 0xCBF29CE484222325)
        var a = SplitMix64(state: 7), b = SplitMix64(state: 7)
        XCTAssertEqual(a.next(), b.next())
    }
}
