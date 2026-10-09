import AppKit

/// A live Wrong-target selection surface. Unlike the click-through guidance overlay, this panel is
/// interactive and sits above the approved window, so the selection press and release land on Clicky
/// and never reach the application control underneath (a global event monitor could not suppress them).
@MainActor
protocol GuideSelectionSurface: AnyObject {
    func close()
}

@MainActor
final class TargetSelectionPanel: NSPanel, GuideSelectionSurface {
    private var onSelect: ((CGPoint) -> Void)?
    private var onCancel: (() -> Void)?

    /// `region` is global top-left points (the approved window or display).
    static func present(over region: CGRect, onSelect: @escaping (CGPoint) -> Void,
                        onCancel: @escaping () -> Void) -> TargetSelectionPanel? {
        let primaryHeight = (NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens.first)?.frame.height ?? 0
        let frame = CGRect(x: region.minX, y: primaryHeight - region.maxY, width: region.width, height: region.height)
        guard frame.width > 1, frame.height > 1, region.minX.isFinite, region.minY.isFinite else { return nil }
        let panel = TargetSelectionPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.onSelect = onSelect; panel.onCancel = onCancel
        panel.isOpaque = false
        panel.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.08)
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.ignoresMouseEvents = false
        panel.isReleasedWhenClosed = false
        panel.contentView = SelectionView(frame: CGRect(origin: .zero, size: frame.size))
        panel.setAccessibilityLabel("Select the intended control")
        panel.orderFrontRegardless()
        panel.makeKey()
        return panel
    }

    override var canBecomeKey: Bool { true }

    /// Consumes both press and release; the selection completes on release, so no remnant reaches the app.
    fileprivate func selected(at local: CGPoint) {
        let primaryHeight = (NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens.first)?.frame.height ?? 0
        let global = CGPoint(x: frame.minX + local.x, y: primaryHeight - (frame.minY + local.y))
        let handler = onSelect
        close()
        handler?(global)
    }

    fileprivate func cancelled() {
        let handler = onCancel
        close()
        handler?()
    }

    override func close() {
        onSelect = nil; onCancel = nil
        orderOut(nil)
        super.close()
    }

    private final class SelectionView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var acceptsFirstResponder: Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
        override func mouseDown(with event: NSEvent) {}
        override func rightMouseDown(with event: NSEvent) {}
        override func mouseUp(with event: NSEvent) {
            (window as? TargetSelectionPanel)?.selected(at: convert(event.locationInWindow, from: nil))
        }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { (window as? TargetSelectionPanel)?.cancelled() } else { super.keyDown(with: event) }
        }
    }
}
