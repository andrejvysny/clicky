import AppKit
import SwiftUI

/// A brief, click-through, never-key result line near the pointer after Quick Ask closed for a host edit
/// ("Inserted — not executed", "Not inserted: …"). It never takes focus from the edited application.
@MainActor
enum WritingNoticePanel {
    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?

    static func show(_ message: String) {
        hideWork?.cancel()
        let host = NSHostingView(rootView: Text(message).font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(Color.black.opacity(0.85))).fixedSize()
            .accessibilityIdentifier("writingNotice"))
        let size = host.fittingSize
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        var origin = CGPoint(x: pointer.x + 18, y: pointer.y - size.height - 18)
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
            origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        }
        let notice = panel ?? NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        notice.isOpaque = false; notice.backgroundColor = .clear; notice.hasShadow = false
        notice.level = .floating; notice.ignoresMouseEvents = true
        notice.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        notice.contentView = host
        notice.setFrame(CGRect(origin: origin, size: size), display: true)
        notice.orderFrontRegardless()
        panel = notice
        let work = DispatchWorkItem { panel?.orderOut(nil) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }
}
