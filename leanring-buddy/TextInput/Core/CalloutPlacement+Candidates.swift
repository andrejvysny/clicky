// Placement adapted from adammcarter/annotate, MIT License (see THIRD_PARTY_NOTICES.md).
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

nonisolated extension CalloutPlacement {
    /// Ranked positions a plate may take, best first. Index 0 is the preferred slot.
    static func candidates(for anchor: CalloutAnchor, size: CGSize, bounds: CGRect, inset: CGFloat) -> [CGRect] {
        switch anchor {
        case .box(let box):
            return (0..<rings).flatMap { ring(around: box, size: size, step: $0) }

        case .shaft(let from, let to):
            let dx = to.x - from.x
            let dy = to.y - from.y
            let length = max((dx * dx + dy * dy).squareRoot(), 1)
            let normal = CGPoint(x: -dy / length, y: dx / length)
            let away = CGPoint(x: -dx / length, y: -dy / length)
            // Behind the tail first, level with it: the eye reads label, shaft, target in one movement.
            let beyond: CGFloat = dx <= 0 ? 1 : -1
            let level = CGRect(x: beyond > 0 ? from.x + nearGap : from.x - nearGap - size.width,
                               y: from.y - size.height / 2, width: size.width, height: size.height)
            let behindDistance = halfExtent(of: size, along: away) + nearGap
            let behind = centred(at: CGPoint(x: from.x + away.x * behindDistance, y: from.y + away.y * behindDistance), size: size)
            let sideGap = halfExtent(of: size, along: normal) + nearGap
            let sides = [CGFloat(1), -1].map { side in
                centred(at: CGPoint(x: from.x + normal.x * sideGap * side, y: from.y + normal.y * sideGap * side), size: size)
            }
            let tail = CGRect(origin: from, size: .zero)
            return [level, behind] + sides + (0..<rings).flatMap { ring(around: tail, size: size, step: $0) }

        case .point(let point):
            let dot = CGRect(origin: point, size: .zero)
            return [centred(at: point, size: size)] + (0..<rings).flatMap { ring(around: dot, size: size, step: $0) }
        }
    }

    /// Every spot a plate could stand in `bounds`, nearest to the mark first; last resort when rings are taken.
    static func freeSpace(for anchor: CalloutAnchor, size: CGSize, bounds: CGRect, inset: CGFloat) -> [CGRect] {
        let origin = centre(of: anchorRect(of: anchor))
        let left = bounds.minX + inset
        let top = bounds.minY + inset
        let right = bounds.maxX - inset - size.width
        let bottom = bounds.maxY - inset - size.height
        guard right > left, bottom > top else { return [] }

        var slots: [(CGRect, CGFloat)] = []
        var y = top
        while y <= bottom {
            var x = left
            while x <= right {
                let dx = origin.x - (x + size.width / 2)
                let dy = origin.y - (y + size.height / 2)
                slots.append((CGRect(x: x, y: y, width: size.width, height: size.height), dx * dx + dy * dy))
                x += sweepStep
            }
            y += sweepStep
        }
        return slots.sorted { $0.1 < $1.1 }.map(\.0)
    }

    /// Positions around a box at a fixed gap: the four sides first (a plate squared to an edge reads as
    /// belonging to it), then corners. Each ring step clears the ring inside it by a whole plate.
    /// y-down: "below" is the larger-y side, and comes first.
    private static func ring(around box: CGRect, size: CGSize, step: Int) -> [CGRect] {
        let gapX = nearGap + CGFloat(step) * (size.width + clearance)
        let gapY = nearGap + CGFloat(step) * (size.height + clearance)

        let below = box.maxY + gapY
        let above = box.minY - gapY - size.height
        let left = box.minX - gapX - size.width
        let right = box.maxX + gapX

        let midX = box.midX - size.width / 2
        let midY = box.midY - size.height / 2
        let startX = box.minX
        let endX = box.maxX - size.width
        let startY = box.minY
        let endY = box.maxY - size.height

        var slots: [CGRect] = []
        for y in [below, above] {
            for x in [midX, startX, endX] { slots.append(CGRect(x: x, y: y, width: size.width, height: size.height)) }
        }
        for x in [right, left] {
            for y in [midY, startY, endY] { slots.append(CGRect(x: x, y: y, width: size.width, height: size.height)) }
        }
        for x in [right, left] {
            for y in [below, above] { slots.append(CGRect(x: x, y: y, width: size.width, height: size.height)) }
        }
        return slots
    }

    private static func centred(at point: CGPoint, size: CGSize) -> CGRect {
        CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height)
    }

    private static func halfExtent(of size: CGSize, along direction: CGPoint) -> CGFloat {
        abs(direction.x) * size.width / 2 + abs(direction.y) * size.height / 2
    }
}

/// Uniform grid over rectangles so a candidate is only tested against nearby ones;
/// sweeping a busy screen was quadratic without it.
nonisolated final class RectIndex {
    private let cell: CGFloat = 64
    private var buckets: [Int64: [Int]] = [:]
    private let rects: [CGRect]
    /// Visit stamps let a query skip rectangles it already tested without allocating a set per candidate.
    private var stamps: [Int]
    private var visit = 0

    init(_ rects: [CGRect]) {
        self.rects = rects
        self.stamps = Array(repeating: 0, count: rects.count)
        for (index, rect) in rects.enumerated() {
            for key in keys(of: rect) { buckets[key, default: []].append(index) }
        }
    }

    func intersects(_ frame: CGRect) -> Bool {
        for key in keys(of: frame) {
            for index in buckets[key] ?? [] where frame.intersects(rects[index]) { return true }
        }
        return false
    }

    /// Distinct rectangles overlapping `frame`.
    func count(_ frame: CGRect) -> Int {
        visit += 1
        var total = 0
        for key in keys(of: frame) {
            for index in buckets[key] ?? [] where stamps[index] != visit {
                stamps[index] = visit
                if frame.intersects(rects[index]) { total += 1 }
            }
        }
        return total
    }

    /// Area of `frame` covered, counting each rectangle once.
    func overlapArea(_ frame: CGRect) -> CGFloat {
        visit += 1
        var total: CGFloat = 0
        for key in keys(of: frame) {
            for index in buckets[key] ?? [] where stamps[index] != visit {
                stamps[index] = visit
                let overlap = frame.intersection(rects[index])
                if !overlap.isNull { total += overlap.width * overlap.height }
            }
        }
        return total
    }

    func covers(_ point: CGPoint) -> Bool {
        let key = Self.key(Int64((point.x / cell).rounded(.down)), Int64((point.y / cell).rounded(.down)))
        for index in buckets[key] ?? [] where rects[index].contains(point) { return true }
        return false
    }

    private static func key(_ x: Int64, _ y: Int64) -> Int64 {
        x &* 73_856_093 &+ y &* 19_349_663
    }

    private func keys(of rect: CGRect) -> [Int64] {
        let minX = Int64((rect.minX / cell).rounded(.down))
        let maxX = Int64((rect.maxX / cell).rounded(.down))
        let minY = Int64((rect.minY / cell).rounded(.down))
        let maxY = Int64((rect.maxY / cell).rounded(.down))
        var keys: [Int64] = []
        for y in minY...maxY {
            for x in minX...maxX { keys.append(Self.key(x, y)) }
        }
        return keys
    }
}
