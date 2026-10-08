import AppKit

/// Draws the click-through target circle for a pointed-at screen location and flies the companion there.
@MainActor
final class PointingPresenter {
    private let overlay = GuidanceOverlay()
    private var generation: UInt64 = 0
    private var monitor: Any?
    private var timeout: DispatchWorkItem?
    /// AppKit global point, NSScreen frame, label.
    var onFlyCompanion: ((CGPoint, CGRect, String) -> Void)?

    private var primaryHeight: CGFloat {
        (NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens.first)?.frame.height ?? 0
    }

    /// `rect` is global top-left points.
    func show(rect: CGRect, label: String) {
        hide()
        let current = generation
        overlay.show(target: rect, instruction: label.isEmpty ? "Here" : label)
        overlay.update(status: "Click it, or click anywhere to dismiss", tone: .waiting)
        let center = CGPoint(x: rect.midX, y: primaryHeight - rect.midY)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? NSScreen.main {
            onFlyCompanion?(center, screen.frame, label)
        }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.generation == current else { return }
                let location = NSEvent.mouseLocation
                let point = CGPoint(x: location.x, y: self.primaryHeight - location.y)
                if rect.insetBy(dx: -8, dy: -8).contains(point) {
                    self.overlay.update(status: "✓ Clicked", tone: .success)
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

    func hide() {
        generation &+= 1
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        timeout?.cancel()
        timeout = nil
        overlay.hide()
    }
}
