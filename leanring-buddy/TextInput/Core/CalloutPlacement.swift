// Placement adapted from adammcarter/annotate, MIT License (see THIRD_PARTY_NOTICES.md).
// Global top-left Core Graphics points (y grows downward): ring slot 0 is visually BELOW the target.
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// What a label belongs to.
nonisolated enum CalloutAnchor: Equatable, Sendable {
    /// A loop, highlight or field: the padded box the mark encloses.
    case box(CGRect)
    /// An arrow: the label belongs at the tail and must stay off the shaft.
    case shaft(from: CGPoint, to: CGPoint)
    case point(CGPoint)
}

/// Both lists are hard: a label is opaque, so a plate over a mark hides it.
/// `hard` is whole rectangles (other plates, the target); `ink` is a stroke sampled
/// into short segments so a diagonal arrow does not fence off its whole bounding box.
nonisolated struct CalloutObstacles: Equatable, Sendable {
    var hard: [CGRect]
    var ink: [CGRect]

    static let none = CalloutObstacles(hard: [], ink: [])

    init(hard: [CGRect] = [], ink: [CGRect] = []) {
        self.hard = hard
        self.ink = ink
    }
}

/// A line joining a plate to its mark when they are far enough apart that the eye would not join them.
nonisolated struct CalloutLeader: Equatable, Sendable {
    var start: CGPoint
    var end: CGPoint
}

nonisolated struct CalloutPlacement: Equatable, Sendable {
    let frame: CGRect
    /// Candidate taken; 0 is the preferred slot, so a quiet screen is stable.
    let index: Int
    let leader: CalloutLeader?

    // Design constants from annotate's Tokens.
    static let leaderMinimumGap: CGFloat = 24
    static let minimumLeaderLength: CGFloat = 18
    static let nearGap: CGFloat = 10
    static let clearance: CGFloat = 8
    static let inkClearance: CGFloat = 4
    static let shaftHalfWidth: CGFloat = 8
    static let leaderEndGap: CGFloat = 7
    static let rings = 3
    static let sweepStep: CGFloat = 24
    static let screenInset: CGFloat = 24
    static let boundaryCoordinateLimit = 64

    /// First slot in the ranked list that touches nothing (no plate, no ink, not its own target);
    /// if none is clean, the least bad ring slot (fewest hard hits, then least ink area, then earliest).
    /// Deterministic: no random input.
    static func place(anchor: CalloutAnchor, size: CGSize, bounds: CGRect, inset: CGFloat,
                      obstacles: CalloutObstacles) -> CalloutPlacement {
        let own = ownLimits(of: anchor)
        let slots = candidates(for: anchor, size: size, bounds: bounds, inset: inset)
        let hardIndex = RectIndex(obstacles.hard.map { $0.insetBy(dx: -clearance, dy: -clearance) })
        let inkIndex = RectIndex(obstacles.ink.map { $0.insetBy(dx: -inkClearance, dy: -inkClearance) })

        var best: (index: Int, frame: CGRect, hard: Int, leader: Int, ink: CGFloat)?
        for (index, slot) in slots.enumerated() {
            let frame = clamp(slot, in: bounds, inset: inset)
            let ownHit = own.contains { frame.intersects($0) }
            if !ownHit, !hardIndex.intersects(frame), !inkIndex.intersects(frame),
               !leaderIsBlocked(from: frame, anchor: anchor, hard: hardIndex, ink: inkIndex) {
                return placement(frame: frame, index: index, anchor: anchor)
            }
            let hard = own.filter { frame.intersects($0) }.count + hardIndex.count(frame)
            let inkArea = inkIndex.overlapArea(frame)
            let leaderCost = (hard == 0 && inkArea == 0) ? 1 : Int.max
            if best == nil || (hard, leaderCost, inkArea) < (best!.hard, best!.leader, best!.ink) {
                best = (index, frame, hard, leaderCost, inkArea)
            }
        }

        // Ring slots exhausted: sweep for any clean spot, nearest first.
        for slot in freeSpace(for: anchor, size: size, bounds: bounds, inset: inset) {
            let frame = clamp(slot, in: bounds, inset: inset)
            guard !own.contains(where: { frame.intersects($0) }),
                  !hardIndex.intersects(frame), !inkIndex.intersects(frame) else { continue }
            return placement(frame: frame, index: slots.count, anchor: anchor)
        }

        guard let best else {
            return CalloutPlacement(frame: clamp(CGRect(origin: .zero, size: size), in: bounds, inset: inset),
                                    index: 0, leader: nil)
        }
        return placement(frame: best.frame, index: best.index, anchor: anchor)
    }

    /// Opaque annotations cannot use the legacy least-bad fallback: no plate is safer than covered UI.
    static func placeIfClear(anchor: CalloutAnchor, size: CGSize, bounds: CGRect, inset: CGFloat,
                             obstacles: CalloutObstacles) -> CalloutPlacement? {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              inset.isFinite, inset >= 0, finiteRect(bounds), finiteAnchor(anchor),
              bounds.width >= size.width + inset * 2, bounds.height >= size.height + inset * 2 else { return nil }
        let obstacles = CalloutObstacles(hard: bounded(obstacles.hard, in: bounds), ink: bounded(obstacles.ink, in: bounds))
        let candidate = place(anchor: anchor, size: size, bounds: bounds, inset: inset, obstacles: obstacles)
        if isClear(candidate.frame, anchor: anchor, obstacles: obstacles) {
            return withSafeLeader(candidate, anchor: anchor, obstacles: obstacles)
        }
        // Grid sweeps can miss narrow usable gaps; obstacle edges describe those gaps exactly.
        let hard = obstacles.hard.map { $0.insetBy(dx: -clearance, dy: -clearance) }
        let ink = obstacles.ink.map { $0.insetBy(dx: -inkClearance, dy: -inkClearance) }
        let edges = ownLimits(of: anchor) + hard + ink
        for frame in boundarySpace(for: anchor, size: size, bounds: bounds, inset: inset, obstacles: edges) {
            guard isClear(frame, anchor: anchor, obstacles: obstacles) else { continue }
            return withSafeLeader(placement(frame: frame, index: candidate.index, anchor: anchor),
                                  anchor: anchor, obstacles: obstacles)
        }
        return nil
    }

    private static func withSafeLeader(_ candidate: CalloutPlacement, anchor: CalloutAnchor,
                                       obstacles: CalloutObstacles) -> CalloutPlacement {
        guard candidate.leader != nil else { return candidate }
        let hard = RectIndex(obstacles.hard.map { $0.insetBy(dx: -clearance, dy: -clearance) })
        let ink = RectIndex(obstacles.ink.map { $0.insetBy(dx: -inkClearance, dy: -inkClearance) })
        return leaderIsBlocked(from: candidate.frame, anchor: anchor, hard: hard, ink: ink)
            ? CalloutPlacement(frame: candidate.frame, index: candidate.index, leader: nil) : candidate
    }

    private static func bounded(_ rects: [CGRect], in bounds: CGRect) -> [CGRect] {
        rects.filter(finiteRect).compactMap {
            let clipped = $0.intersection(bounds.insetBy(dx: -clearance, dy: -clearance))
            return finiteRect(clipped) ? clipped : nil
        }
    }

    private static func finiteRect(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && rect.width > 0 && rect.height > 0
            && [rect.minX, rect.minY, rect.maxX, rect.maxY].allSatisfy(\.isFinite)
    }

    private static func finiteAnchor(_ anchor: CalloutAnchor) -> Bool {
        switch anchor {
        case .box(let rect): return finiteRect(rect)
        case .shaft(let start, let end): return [start.x, start.y, end.x, end.y].allSatisfy(\.isFinite)
        case .point(let point): return point.x.isFinite && point.y.isFinite
        }
    }

    /// Whether a plate already at `frame` needs to move at all.
    static func isClear(_ frame: CGRect, anchor: CalloutAnchor, obstacles: CalloutObstacles) -> Bool {
        if ownLimits(of: anchor).contains(where: { frame.intersects($0) }) { return false }
        if obstacles.hard.contains(where: { frame.intersects($0.insetBy(dx: -clearance, dy: -clearance)) }) { return false }
        if obstacles.ink.contains(where: { frame.intersects($0.insetBy(dx: -inkClearance, dy: -inkClearance)) }) { return false }
        return true
    }

    /// Keeps a plate fully inside `bounds`, inset from the edge.
    static func clamp(_ frame: CGRect, in bounds: CGRect, inset: CGFloat) -> CGRect {
        let maxX = max(bounds.minX + inset, bounds.maxX - inset - frame.width)
        let maxY = max(bounds.minY + inset, bounds.maxY - inset - frame.height)
        return CGRect(x: min(max(frame.minX, bounds.minX + inset), maxX),
                      y: min(max(frame.minY, bounds.minY + inset), maxY),
                      width: frame.width, height: frame.height)
    }

    /// The strip an arrow's shaft runs through, which its own label may not sit on.
    static func corridor(from: CGPoint, to: CGPoint) -> CGRect {
        CGRect(x: min(from.x, to.x), y: min(from.y, to.y), width: abs(to.x - from.x), height: abs(to.y - from.y))
            .insetBy(dx: -shaftHalfWidth, dy: -shaftHalfWidth)
    }

    // MARK: - leader

    private static func leaderIsBlocked(from frame: CGRect, anchor: CalloutAnchor, hard: RectIndex, ink: RectIndex) -> Bool {
        let target = anchorRect(of: anchor)
        guard gap(from: frame, to: target) > leaderMinimumGap,
              let leader = shortened(from: edgePoint(of: frame, facing: centre(of: target)),
                                     to: edgePoint(of: target, facing: centre(of: frame)), by: leaderEndGap)
        else { return false }
        let steps = 24
        for step in 0...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let point = CGPoint(x: leader.start.x + (leader.end.x - leader.start.x) * t,
                                y: leader.start.y + (leader.end.y - leader.start.y) * t)
            if hard.covers(point) || ink.covers(point) { return true }
        }
        return false
    }

    private static func placement(frame: CGRect, index: Int, anchor: CalloutAnchor) -> CalloutPlacement {
        // An arrow is already a pointer; a second stub beside it reads as a broken stroke.
        if case .shaft = anchor { return CalloutPlacement(frame: frame, index: index, leader: nil) }
        let target = anchorRect(of: anchor)
        guard gap(from: frame, to: target) > leaderMinimumGap else {
            return CalloutPlacement(frame: frame, index: index, leader: nil)
        }
        let plateEdge = edgePoint(of: frame, facing: centre(of: target))
        let markEdge = edgePoint(of: target, facing: centre(of: frame))
        return CalloutPlacement(frame: frame, index: index, leader: shortened(from: plateEdge, to: markEdge, by: leaderEndGap))
    }

    /// What the plate itself must never cover: the mark it names.
    private static func ownLimits(of anchor: CalloutAnchor) -> [CGRect] {
        switch anchor {
        case .box(let box): return [box]
        case .shaft(let from, let to): return [corridor(from: from, to: to)]
        case .point: return []
        }
    }

    static func anchorRect(of anchor: CalloutAnchor) -> CGRect {
        switch anchor {
        case .box(let box): return box
        case .shaft(let from, _): return CGRect(origin: from, size: .zero)
        case .point(let point): return CGRect(origin: point, size: .zero)
        }
    }

    /// The line with `gap` trimmed off each end, or nil when too short to read as a connector.
    private static func shortened(from start: CGPoint, to end: CGPoint, by gap: CGFloat) -> CalloutLeader? {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length - gap * 2 >= minimumLeaderLength else { return nil }
        let ux = dx / length, uy = dy / length
        return CalloutLeader(start: CGPoint(x: start.x + ux * gap, y: start.y + uy * gap),
                             end: CGPoint(x: end.x - ux * gap, y: end.y - uy * gap))
    }

    static func centre(of rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + rect.width / 2, y: rect.minY + rect.height / 2)
    }

    /// Edge-to-edge distance; zero when the two touch or overlap.
    static func gap(from: CGRect, to: CGRect) -> CGFloat {
        let dx = max(0, max(to.minX - from.maxX, from.minX - to.maxX))
        let dy = max(0, max(to.minY - from.maxY, from.minY - to.maxY))
        return (dx * dx + dy * dy).squareRoot()
    }

    /// Where a line towards `target` leaves `rect`.
    private static func edgePoint(of rect: CGRect, facing target: CGPoint) -> CGPoint {
        let origin = centre(of: rect)
        let dx = target.x - origin.x, dy = target.y - origin.y
        guard abs(dx) > 1e-9 || abs(dy) > 1e-9 else { return origin }
        let scaleX = abs(dx) > 1e-9 ? (rect.width / 2) / abs(dx) : .infinity
        let scaleY = abs(dy) > 1e-9 ? (rect.height / 2) / abs(dy) : .infinity
        let scale = min(min(scaleX, scaleY), 1)
        return CGPoint(x: origin.x + dx * scale, y: origin.y + dy * scale)
    }
}
