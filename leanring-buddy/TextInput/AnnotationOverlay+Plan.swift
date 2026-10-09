// Mark geometry and label placement adapted from adammcarter/annotate, MIT License (see THIRD_PARTY_NOTICES.md).
import AppKit

/// Pure-ish layout: turns a spec into global top-left paths plus placed label/pill views.
extension AnnotationOverlay {
    private static let labelGap: CGFloat = 24

    func makePlan(_ spec: AnnotationSpec, home: NSScreen) -> Plan {
        let homeFrame = AnnotationScreens.topLeftFrame(of: home)
        let shaped = shape(for: spec, homeFrame: homeFrame)
        var hard = [spec.target]
        var plan = Plan(pieces: shaped.pieces, extent: shaped.extent, lineWidth: Self.lineWidth(for: spec.target))

        if let ghost = spec.ghost {
            let ghostRect = AnnotationGeometry.circleRect(around: ghost)
            plan.pieces.append(Piece(role: .ghost, path: CGPath(ellipseIn: ghostRect, transform: nil)))
            plan.extent = plan.extent.union(ghostRect)
            hard.append(ghostRect)
        }

        if let value = spec.value, !value.isEmpty, let box = shaped.pillBox {
            let view = AnnotationLabelViews.pill(text: value, color: Self.blue)
            let frame = placeFrame(for: view, anchor: .box(box), hard: hard, spec: spec, home: home)
            plan.pill = Placed(view: view, frame: frame)
            plan.extent = plan.extent.union(frame)
            hard.append(frame)
        }

        if let label = spec.label, !label.isEmpty {
            let view = AnnotationLabelViews.card(text: label)
            let bounds = labelBounds(for: view.frame.size, spec: spec, home: home)
            let placement = CalloutPlacement.place(anchor: shaped.anchor, size: view.frame.size, bounds: bounds.area,
                                                   inset: bounds.inset, obstacles: CalloutObstacles(hard: hard))
            // No clean slot is better shown as no label than as a label covering the target.
            guard !placement.frame.intersects(spec.target) else { return plan }
            plan.card = Placed(view: view, frame: placement.frame)
            plan.extent = plan.extent.union(placement.frame)
            if let leader = placement.leader {
                let path = CGMutablePath()
                path.move(to: leader.start)
                path.addLine(to: leader.end)
                plan.pieces.append(Piece(role: .leader, path: path))
            }
        }
        return plan
    }

    private func placeFrame(for view: NSView, anchor: CalloutAnchor, hard: [CGRect], spec: AnnotationSpec, home: NSScreen) -> CGRect {
        let bounds = labelBounds(for: view.frame.size, spec: spec, home: home)
        return CalloutPlacement.place(anchor: anchor, size: view.frame.size, bounds: bounds.area,
                                      inset: bounds.inset, obstacles: CalloutObstacles(hard: hard)).frame
    }

    /// `within` when the plate fits inside it with the inset; otherwise the display's visible frame.
    private func labelBounds(for size: CGSize, spec: AnnotationSpec, home: NSScreen) -> (area: CGRect, inset: CGFloat) {
        if let within = spec.within {
            let area = within.intersection(AnnotationScreens.topLeftFrame(of: home))
            if !area.isNull, area.width >= size.width + Self.labelGap * 2, area.height >= size.height + Self.labelGap * 2 {
                return (area, Self.labelGap)
            }
        }
        return (AnnotationScreens.topLeftVisibleFrame(of: home), 12)
    }

    /// 2.5 pt for small targets up to 4.5 pt for large ones, linear between 80 and 760 pt.
    static func lineWidth(for target: CGRect) -> CGFloat {
        let t = min(max((max(target.width, target.height) - 80) / (760 - 80), 0), 1)
        return 2.5 + 2 * t
    }

    // MARK: - per-mark shapes

    private func shape(for spec: AnnotationSpec, homeFrame: CGRect) -> Shaped {
        switch spec.mark {
        case .circle:
            let rect = AnnotationGeometry.circleRect(around: spec.target)
            return Shaped(pieces: [Piece(role: .stroke, path: CGPath(ellipseIn: rect, transform: nil))],
                          extent: rect, anchor: .box(rect), pillBox: nil)
        case .underline:
            let line = AnnotationGeometry.underline(under: spec.target)
            let path = CGMutablePath()
            path.move(to: line.start)
            path.addLine(to: line.end)
            let extent = spec.target.union(CGRect(x: line.start.x, y: line.start.y, width: line.end.x - line.start.x, height: 0))
            return Shaped(pieces: [Piece(role: .stroke, path: path)], extent: extent, anchor: .box(extent), pillBox: nil)
        case .highlight:
            let rect = AnnotationGeometry.highlightRect(spec.target)
            return Shaped(pieces: [Piece(role: .fillStroke, path: CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil))],
                          extent: rect, anchor: .box(rect), pillBox: nil)
        case .arrow:
            return arrowShape(spec, homeFrame: homeFrame)
        case .value:
            let rect = spec.target.insetBy(dx: -3, dy: -3)
            return Shaped(pieces: [Piece(role: .stroke, path: CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil))],
                          extent: rect, anchor: .box(rect), pillBox: rect)
        }
    }

    private func arrowShape(_ spec: AnnotationSpec, homeFrame: CGRect) -> Shaped {
        // Bit patterns never trap, unlike Int(_:) on a non-finite or huge coordinate.
        let seedText = [spec.target.minX, spec.target.minY, spec.target.width, spec.target.height]
            .map { String(Double($0).bitPattern) }.joined(separator: ",") + (spec.label ?? "")
        let arrow = AnnotationGeometry.arrowToRect(spec.target, bounds: spec.within ?? homeFrame, seed: AnnotationGeometry.fnv1a64(seedText))
        let shaft = CGMutablePath()
        shaft.move(to: arrow.tail)
        shaft.addLine(to: arrow.tip)
        let barbs = AnnotationGeometry.arrowBarbs(tip: arrow.tip, tail: arrow.tail)
        let head = CGMutablePath()
        head.move(to: barbs.0)
        head.addLine(to: arrow.tip)
        head.addLine(to: barbs.1)
        let extent = spec.target.union(CGRect(x: min(arrow.tail.x, arrow.tip.x), y: min(arrow.tail.y, arrow.tip.y),
                                              width: abs(arrow.tip.x - arrow.tail.x), height: abs(arrow.tip.y - arrow.tail.y)))
        return Shaped(pieces: [Piece(role: .stroke, path: shaft), Piece(role: .barbs, path: head)],
                      extent: extent, anchor: .shaft(from: arrow.tail, to: arrow.tip), pillBox: nil)
    }
}
