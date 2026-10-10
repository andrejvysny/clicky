import AppKit
import SwiftUI

/// Opens the one resizable Local AI Lab window. Opening it starts no worker and does not capture, record or download.
@MainActor
final class LocalAILabWindow: NSObject, NSWindowDelegate {
    static let shared = LocalAILabWindow()

    private var window: NSWindow?
    private var model: LocalAILabModel?

    func show(runtime: LocalAIRuntime) {
        if let window, model?.runtime === runtime {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let model = LocalAILabModel(runtime: runtime)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Local AI Lab"
        window.contentViewController = NSHostingController(rootView: LocalAILabView(model: model))
        window.setContentSize(NSSize(width: 920, height: 680))
        window.contentMinSize = NSSize(width: 760, height: 520)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.model = model
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Closing stops any recording and cancels running Lab jobs; loaded models stay until you unload them.
    func windowWillClose(_ notification: Notification) {
        model?.windowClosed()
        window?.contentViewController = nil
        window = nil
        model = nil
    }
}
