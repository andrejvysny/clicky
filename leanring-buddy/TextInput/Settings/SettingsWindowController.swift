import AppKit
import SwiftUI

/// The one Clicky window: settings above, Local AI below. Opening it starts no worker and does not
/// capture, record or download.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()
    private static let frameName = "ClickySettingsWindow"

    private weak var ask: AskController?
    private weak var companion: CompanionManager?
    private var window: NSWindow?
    private var context: SettingsContext?

    func configure(ask: AskController, companion: CompanionManager?) {
        self.ask = ask
        self.companion = companion
    }

    /// Settings… and ⌘, open General; prompts to load a model open Models.
    func show(_ pane: SettingsPaneID = .general) {
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        if let window, let context {
            context.selection = pane
            present(window)
            return
        }
        guard let ask else { return }
        let context = SettingsContext(ask: ask, companion: companion)
        context.selection = pane
        let window = makeWindow(context: context)
        self.context = context
        self.window = window
        present(window)
    }

    private func makeWindow(context: SettingsContext) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        let hosting = NSHostingController(rootView: SettingsRootView().environmentObject(context))
        hosting.sizingOptions = []
        window.contentViewController = hosting
        // The sidebar runs under the traffic lights, as in the design; the title stays for the Window menu and VoiceOver.
        window.title = "Clicky Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(SettingsColors.content)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentMinSize = NSSize(width: 820, height: 540)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setAccessibilityIdentifier("clickySettingsWindow")
        if !window.setFrameUsingName(Self.frameName) {
            window.setContentSize(NSSize(width: 980, height: 640))
            window.center()
        }
        window.setFrameAutosaveName(Self.frameName)
        return window
    }

    private func present(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        context?.windowClosed()
        window?.contentViewController = nil
        window = nil
        context = nil
    }
}
