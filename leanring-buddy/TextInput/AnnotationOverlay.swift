// Mark geometry and label placement adapted from adammcarter/annotate, MIT License (see THIRD_PARTY_NOTICES.md).
// Marks are clean geometric strokes, not hand-drawn ink.
import AppKit
import QuartzCore
import SwiftUI

/// Draws one click-through mark (circle, underline, highlight, arrow or value callout) with an optional
/// ghost circle and a short label that never overlaps the target. Coordinates are global top-left points.
@MainActor
final class AnnotationOverlay {
    struct AnnotationSpec {
        var mark: GuidePresentation.Mark
        var target: CGRect
        var label: String? = nil
        var value: String? = nil
        var ghost: CGRect? = nil
        /// Region (usually the target window) the arrow tail and label should stay inside when they fit.
        var within: CGRect? = nil
    }

    enum Role { case stroke, fillStroke, barbs, ghost, leader }

    struct Piece {
        var role: Role
        var path: CGPath
    }

    struct Placed {
        var view: NSView
        var frame: CGRect
    }

    struct Plan {
        var pieces: [Piece]
        var extent: CGRect
        var lineWidth: CGFloat
        var card: Placed?
        var pill: Placed?
    }

    struct Shaped {
        var pieces: [Piece]
        var extent: CGRect
        var anchor: CalloutAnchor
        /// Box the value pill hangs from; nil for other marks.
        var pillBox: CGRect?
    }

    private var windows: [CGDirectDisplayID: AnnotationOverlayWindow] = [:]
    private var activeWindows: [AnnotationOverlayWindow] = []
    private var shapeLayers: [(layer: CAShapeLayer, role: Role, lineWidth: CGFloat)] = []
    private var pulseLayers: [CALayer] = []
    private var spec: AnnotationSpec?
    private var tone: GuidanceOverlay.Tone = .waiting
    private var generation = 0
    private var rebuildWork: DispatchWorkItem?

    static let blue = NSColor(DS.Colors.overlayCursorBlue)

    nonisolated(unsafe) private var screenObserver: NSObjectProtocol?

    init() {
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    var windowNumbers: Set<Int> {
        Set(activeWindows.filter { $0.windowNumber > 0 }.map(\.windowNumber))
    }

    func show(_ spec: AnnotationSpec, tone: GuidanceOverlay.Tone = .waiting) {
        teardown()
        self.spec = spec
        self.tone = tone
        render(animated: true)
    }

    func update(tone: GuidanceOverlay.Tone) {
        self.tone = tone
        for entry in shapeLayers { style(entry.layer, role: entry.role, lineWidth: entry.lineWidth) }
        updatePulse()
    }

    func hide() {
        guard spec != nil, !activeWindows.isEmpty else {
            spec = nil
            teardown()
            return
        }
        spec = nil
        generation += 1
        let current = generation
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == current else { return }
                self.teardown()
            }
        }
        for window in activeWindows {
            guard let layer = window.canvasView.layer else { continue }
            // Fade from what is on screen now, so hiding mid draw-on does not pop to full opacity first.
            let from = layer.presentation()?.opacity ?? layer.opacity
            layer.opacity = 0
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = from
            fade.toValue = 0
            fade.duration = 0.35
            layer.add(fade, forKey: "fade")
        }
        CATransaction.commit()
    }

    // MARK: - lifecycle

    private func teardown() {
        generation += 1
        rebuildWork?.cancel()
        rebuildWork = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for window in windows.values {
            window.canvasView.clear()
            window.orderOut(nil)
        }
        CATransaction.commit()
        activeWindows = []
        shapeLayers = []
        pulseLayers = []
    }

    private func screensChanged() {
        rebuildWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.spec != nil else { return }
                self.pruneWindows()
                self.render(animated: false)
            }
        }
        rebuildWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func pruneWindows() {
        let live = Set(NSScreen.screens.compactMap(AnnotationScreens.displayID(of:)))
        for (id, window) in windows where !live.contains(id) {
            window.orderOut(nil)
            window.close()
            windows[id] = nil
        }
    }

    private func window(for screen: NSScreen) -> AnnotationOverlayWindow? {
        guard let id = AnnotationScreens.displayID(of: screen) else { return nil }
        let window = windows[id] ?? AnnotationOverlayWindow(screen: screen)
        if window.frame != screen.frame { window.setFrame(screen.frame, display: false) }
        windows[id] = window
        return window
    }

    // MARK: - rendering

    private func render(animated: Bool) {
        guard let spec, let home = AnnotationScreens.home(for: spec.target) ?? NSScreen.main else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let animate = animated && !reduceMotion
        let plan = makePlan(spec, home: home)
        let previouslyActive = activeWindows
        activeWindows = []
        shapeLayers = []
        pulseLayers = []

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for screen in NSScreen.screens {
            let isHome = screen == home
            guard isHome || AnnotationScreens.topLeftFrame(of: screen).intersects(plan.extent),
                  let window = window(for: screen) else { continue }
            window.canvasView.clear()
            addContent(plan, to: window, on: screen, includeViews: isHome, animate: animate)
            if reduceMotion && animated { fadeIn(window.canvasView.layer) }
            window.orderFrontRegardless()
            activeWindows.append(window)
        }
        CATransaction.commit()
        for stale in previouslyActive where !activeWindows.contains(stale) {
            stale.canvasView.clear()
            stale.orderOut(nil)
        }
        updatePulse()
    }

    private func addContent(_ plan: Plan, to window: AnnotationOverlayWindow, on screen: NSScreen,
                            includeViews: Bool, animate: Bool) {
        guard let root = window.canvasView.layer else { return }
        let screenFrame = AnnotationScreens.topLeftFrame(of: screen)
        let local = AnnotationScreens.localRect(plan.extent.insetBy(dx: -40, dy: -40), on: screen)
        let container = CALayer()
        container.frame = local
        root.addSublayer(container)
        if spec?.mark == .circle { pulseLayers.append(container) }

        // global top-left -> container-local y-up
        var toLocal = CGAffineTransform(a: 1, b: 0, c: 0, d: -1,
                                        tx: -screenFrame.minX - local.minX, ty: screenFrame.maxY - local.minY)
        for piece in plan.pieces {
            let layer = CAShapeLayer()
            layer.frame = container.bounds
            layer.contentsScale = screen.backingScaleFactor
            layer.path = piece.path.copy(using: &toLocal)
            layer.fillColor = nil
            layer.lineCap = .round
            layer.lineJoin = .round
            let width = piece.role == .ghost || piece.role == .leader ? 1.5 : plan.lineWidth
            container.addSublayer(layer)
            shapeLayers.append((layer, piece.role, width))
            style(layer, role: piece.role, lineWidth: width)
            if animate { drawOn(layer, role: piece.role) }
        }
        guard includeViews else { return }
        for placed in [plan.pill, plan.card].compactMap({ $0 }) {
            placed.view.frame = AnnotationScreens.localRect(placed.frame, on: screen)
            window.canvasView.addSubview(placed.view)
            if animate { fadeIn(view: placed.view) }
        }
    }

    // MARK: - style and motion

    private func style(_ layer: CAShapeLayer, role: Role, lineWidth: CGFloat) {
        layer.lineWidth = lineWidth
        layer.shadowOpacity = 0
        layer.lineDashPattern = nil
        switch role {
        case .ghost:
            layer.strokeColor = Self.blue.cgColor
            layer.lineDashPattern = [5, 4]
            layer.opacity = 0.35
        case .leader:
            layer.strokeColor = NSColor(tone.color).withAlphaComponent(0.55).cgColor
        case .stroke, .fillStroke, .barbs:
            let base = NSColor(tone.color)
            let alpha: CGFloat = tone == .verifying ? 0.45 : (tone == .stale ? 0.55 : 1)
            layer.strokeColor = base.withAlphaComponent(alpha).cgColor
            layer.fillColor = role == .fillStroke ? base.withAlphaComponent(0.16 * alpha).cgColor : nil
            if tone == .stale { layer.lineDashPattern = [5, 4] }
            if tone != .verifying && tone != .stale {
                layer.shadowColor = base.cgColor
                layer.shadowOpacity = 0.6
                layer.shadowRadius = 8
                layer.shadowOffset = .zero
            }
        }
    }

    private func drawOn(_ layer: CAShapeLayer, role: Role) {
        let shaftIsArrow = spec?.mark == .arrow
        switch role {
        case .leader: return
        case .ghost: fadeIn(layer: layer, to: 0.35)
        case .barbs: addDrawOn(to: layer, duration: 0.11, delay: 0.30, curve: (0.35, 0, 0.20, 1))
        case .stroke, .fillStroke:
            addDrawOn(to: layer, duration: shaftIsArrow ? 0.30 : 0.45, delay: 0,
                      curve: shaftIsArrow ? (0.35, 0, 0.20, 1) : (0.31, 0, 0.18, 1))
        }
    }

    private func addDrawOn(to layer: CAShapeLayer, duration: CFTimeInterval, delay: CFTimeInterval,
                           curve: (Float, Float, Float, Float)) {
        let animation = CABasicAnimation(keyPath: "strokeEnd")
        animation.fromValue = 0
        animation.toValue = 1
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(controlPoints: curve.0, curve.1, curve.2, curve.3)
        if delay > 0 {
            animation.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + delay
            animation.fillMode = .backwards
        }
        layer.add(animation, forKey: "draw")
    }

    private func fadeIn(_ layer: CALayer?) {
        guard let layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.2
        layer.add(fade, forKey: "fadeIn")
    }

    private func fadeIn(layer: CALayer, to opacity: Float) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = opacity
        fade.duration = 0.45
        layer.add(fade, forKey: "fadeIn")
    }

    private func fadeIn(view: NSView) {
        view.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            view.animator().alphaValue = 1
        }
    }

    /// Only the waiting circle pulses; other states hold still so a change reads as a state change.
    private func updatePulse() {
        let pulses = tone == .waiting && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for layer in pulseLayers {
            layer.removeAnimation(forKey: "pulse")
            guard pulses else { continue }
            let pulse = CABasicAnimation(keyPath: "transform.scale")
            pulse.fromValue = 1.0
            pulse.toValue = 1.06
            pulse.duration = 0.9
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(pulse, forKey: "pulse")
        }
    }
}
