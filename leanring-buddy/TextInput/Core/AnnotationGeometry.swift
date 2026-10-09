// Geometry adapted from adammcarter/annotate, MIT License (see THIRD_PARTY_NOTICES.md).
// All rects and points are global top-left Core Graphics points (y grows downward).
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

nonisolated struct SplitMix64: RandomNumberGenerator, Sendable {
    var state: UInt64

    init(state: UInt64) { self.state = state }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    mutating func unit() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }
}

nonisolated enum AnnotationGeometry {
    static func fnv1a64(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xCBF29CE484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x00000100000001B3
        }
        return hash
    }

    private static let circlePaddingFraction: CGFloat = 0.12
    private static let circleMinimumPadding: CGFloat = 8
    private static let circleMaximumPadding: CGFloat = 34
    private static let circleMinimumDiameter: CGFloat = 56
    private static let underlineDrop: CGFloat = 12
    private static let underlineOverhang: CGFloat = 6
    private static let highlightOutset: CGFloat = 2
    private static let arrowTipGap: CGFloat = 7
    private static let arrowTailReach: CGFloat = 150
    private static let arrowEdgeMargin: CGFloat = 8
    private static let barbFraction: CGFloat = 0.18
    private static let barbMinimum: CGFloat = 12
    private static let barbMaximum: CGFloat = 28
    private static let barbAngle: CGFloat = 28 * .pi / 180

    /// Padding is proportional between a floor and a ceiling so tall targets do not sprawl;
    /// tiny targets grow to a visible minimum diameter.
    static func circleRect(around target: CGRect) -> CGRect {
        let padX = min(max(target.width * circlePaddingFraction, circleMinimumPadding), circleMaximumPadding)
        let padY = min(max(target.height * circlePaddingFraction, circleMinimumPadding), circleMaximumPadding)
        var rect = target.insetBy(dx: -padX, dy: -padY)
        if rect.width < circleMinimumDiameter {
            rect = rect.insetBy(dx: -(circleMinimumDiameter - rect.width) / 2, dy: 0)
        }
        if rect.height < circleMinimumDiameter {
            rect = rect.insetBy(dx: 0, dy: -(circleMinimumDiameter - rect.height) / 2)
        }
        return rect
    }

    static func underline(under target: CGRect) -> (start: CGPoint, end: CGPoint) {
        let y = target.maxY + underlineDrop
        return (CGPoint(x: target.minX - underlineOverhang, y: y),
                CGPoint(x: target.maxX + underlineOverhang, y: y))
    }

    static func highlightRect(_ target: CGRect) -> CGRect {
        target.insetBy(dx: -highlightOutset, dy: -highlightOutset)
    }

    /// Tip just outside an edge of `rect`, tail up to 150 pt away on the same side, inside `bounds`.
    /// The seed only picks the position along the edge (outer fifth avoided) and breaks ties.
    static func arrowToRect(_ rect: CGRect, bounds: CGRect?, from: CGPoint? = nil, seed: UInt64) -> (tip: CGPoint, tail: CGPoint) {
        var generator = SplitMix64(state: seed &* 0x9E37_79B9)
        let wide = CGRect(x: rect.minX - 400, y: rect.minY - 400, width: rect.width + 800, height: rect.height + 800)
        var box = bounds ?? wide

        // 0 left, 1 right, 2 top (min y), 3 bottom (max y)
        let room: [(side: Int, space: CGFloat)] = [
            (0, rect.minX - box.minX),
            (1, box.maxX - rect.maxX),
            (2, rect.minY - box.minY),
            (3, box.maxY - rect.maxY),
        ]
        let roomiest = room.max(by: { $0.space < $1.space })?.side ?? 1
        let tied = room.allSatisfy { abs($0.space - room[0].space) < 0.5 }
        var side = approachSide(to: rect, from: from) ?? (tied ? Int(generator.next() % 4) : roomiest)

        let t = CGFloat(0.2 + generator.unit() * 0.6)
        let gap = arrowTipGap
        let reach = arrowTailReach
        let margin = arrowEdgeMargin
        // A target filling its window leaves no room for a shaft; clamping would put the tail past the tip.
        let needed = gap + margin + 24
        if room[side].space < needed { side = roomiest }
        if room[side].space < needed { box = wide }
        let lateral = reach * 0.45

        switch side {
        case 0:
            let y = rect.minY + rect.height * t
            return (CGPoint(x: rect.minX - gap, y: y),
                    CGPoint(x: max(box.minX + margin, rect.minX - gap - reach), y: y + lateral))
        case 1:
            let y = rect.minY + rect.height * t
            return (CGPoint(x: rect.maxX + gap, y: y),
                    CGPoint(x: min(box.maxX - margin, rect.maxX + gap + reach), y: y + lateral))
        case 2:
            let x = rect.minX + rect.width * t
            return (CGPoint(x: x, y: rect.minY - gap),
                    CGPoint(x: x + lateral, y: max(box.minY + margin, rect.minY - gap - reach)))
        default:
            let x = rect.minX + rect.width * t
            return (CGPoint(x: x, y: rect.maxY + gap),
                    CGPoint(x: x + lateral, y: min(box.maxY - margin, rect.maxY + gap + reach)))
        }
    }

    /// The edge a shaft from `point` can reach without crossing `rect`, measured in half-extents
    /// so wide bars are approached from above/below and tall columns from the side; nil when level on both axes.
    static func approachSide(to rect: CGRect, from point: CGPoint?) -> Int? {
        guard let point else { return nil }
        let halfWidth = max(rect.width / 2, 0.5)
        let halfHeight = max(rect.height / 2, 0.5)
        let candidates: [(Int, CGFloat)] = [
            (0, (rect.minX - point.x) / halfWidth),
            (1, (point.x - rect.maxX) / halfWidth),
            (2, (rect.minY - point.y) / halfHeight),
            (3, (point.y - rect.maxY) / halfHeight),
        ].filter { $0.1 > 0 }
        return candidates.max(by: { $0.1 < $1.1 })?.0
    }

    /// Barb endpoints for an arrowhead at `tip`, swept back along the shaft from `tail`.
    static func arrowBarbs(tip: CGPoint, tail: CGPoint) -> (CGPoint, CGPoint) {
        let dx = tip.x - tail.x, dy = tip.y - tail.y
        let length = (dx * dx + dy * dy).squareRoot()
        let barbLength = min(max(barbFraction * length, barbMinimum), barbMaximum)
        let angle = atan2(dy, dx)
        func barb(_ sweep: CGFloat) -> CGPoint {
            point(from: tip, distance: barbLength, angle: angle + .pi + sweep)
        }
        return (barb(barbAngle), barb(-barbAngle))
    }

    static func point(from origin: CGPoint, distance: CGFloat, angle: CGFloat) -> CGPoint {
        CGPoint(x: origin.x + distance * cos(angle), y: origin.y + distance * sin(angle))
    }
}
