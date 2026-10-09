import AppKit

/// Draws a click-through annotation (circle, underline, highlight, arrow, value) for a pointed-at screen
/// location and flies the companion there. Instruction cards live in the notch island, not here.
@MainActor
final class PointingPresenter {
    private let overlay = AnnotationOverlay()
    private var generation: UInt64 = 0
    private var monitor: Any?
    private var timeout: DispatchWorkItem?
    /// AppKit global point, NSScreen frame, label.
    var onFlyCompanion: ((CGPoint, CGRect, String) -> Void)?
    /// Called from `hide()` so the caller can clear the companion location.
    var onHidden: (() -> Void)?

    var windowNumbers: Set<Int> { overlay.windowNumbers }

    private var primaryHeight: CGFloat { AnnotationScreens.primaryHeight }

    /// `rect` is global top-left points. Draws a circle; `progress` belongs to the island now and is ignored.
    func show(rect: CGRect, label: String, persistent: Bool = false, progress: GuideCardProgress? = nil) {
        show(AnnotationOverlay.AnnotationSpec(mark: .circle, target: rect, label: label.isEmpty ? nil : label), persistent: persistent)
    }

    func show(_ spec: AnnotationOverlay.AnnotationSpec, persistent: Bool, tone: GuidanceOverlay.Tone = .waiting) {
        // Clearing the old companion target first lets the companion fly to the new mark instead of staying parked.
        dismiss(notify: true)
        let current = generation
        let rect = spec.target
        overlay.show(spec, tone: tone)
        let center = CGPoint(x: rect.midX, y: primaryHeight - rect.midY)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? NSScreen.main {
            onFlyCompanion?(center, screen.frame, spec.label ?? "")
        }
        if persistent { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.generation == current else { return }
                let location = NSEvent.mouseLocation
                let point = CGPoint(x: location.x, y: self.primaryHeight - location.y)
                if rect.insetBy(dx: -8, dy: -8).contains(point) {
                    self.overlay.update(tone: .success)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                        MainActor.assumeIsolated {
                            guard let self, self.generation == current else { return }
                            self.hide()
                        }
                    }
                } else {
                    self.hide()
                }
            }
        }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == current else { return }
                self.hide()
            }
        }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: work)
    }

    func update(tone: GuidanceOverlay.Tone) {
        overlay.update(tone: tone)
    }

    func hide() {
        dismiss(notify: true)
    }

    private func dismiss(notify: Bool) {
        generation &+= 1
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        timeout?.cancel()
        timeout = nil
        overlay.hide()
        if notify { onHidden?() }
    }
}
