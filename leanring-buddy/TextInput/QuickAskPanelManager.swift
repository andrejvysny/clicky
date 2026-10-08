import AppKit
import SwiftUI

private final class QuickAskPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

@MainActor
final class QuickAskPanelManager: NSObject, NSWindowDelegate {
    private let controller: AskController
    private var panel: NSPanel?
    private var originatingApplication: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?
    private var outsideClickMonitor: Any?
    private var presentationPointer = CGPoint.zero
    private var userChangedFocus = false
    private var isClosing = false
    private var presentationIdentifier = UUID()

    init(controller: AskController) {
        self.controller = controller
        super.init()
        controller.onSubmitted = { [weak self] in
            // UI fixtures keep the panel visible to inspect preview output; production restores focus.
            if !ProcessInfo.processInfo.arguments.contains("--clicky-ui-test") { self?.close(restoreFocus: true) }
        }
    }

    func show(settings: Bool = false) {
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        if let panel, panel.isVisible {
            if settings { controller.showSettings = true; resize() }
            panel.makeKeyAndOrderFront(nil)
            return
        }
        originatingApplication = NSWorkspace.shared.frontmostApplication
        let testing = ProcessInfo.processInfo.arguments.contains("--clicky-ui-test")
        controller.beginPresentation(target: testing ? nil : WindowSnapshotCapture.target(for: originatingApplication))
        presentationIdentifier = UUID()
        userChangedFocus = false
        presentationPointer = NSEvent.mouseLocation
        controller.showSettings = settings
        controller.editorGeneration = UUID()
        let screen = NSScreen.screens.first(where: { $0.frame.contains(presentationPointer) }) ?? NSScreen.main
        let view = QuickAskView(controller: controller, onCancel: { [weak self] in self?.close(restoreFocus: true) },
                                onLayoutChanged: { [weak self] in self?.resize() }, maximumHeight: max(240, (screen?.visibleFrame.height ?? 800) - 24))
        let hostingView = NSHostingView(rootView: view)
        let newPanel = QuickAskPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        newPanel.contentView = hostingView
        newPanel.onCancel = { [weak self] in self?.close(restoreFocus: true) }
        newPanel.isFloatingPanel = true
        newPanel.level = .floating
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = true
        newPanel.hidesOnDeactivate = false
        newPanel.isReleasedWhenClosed = false
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        newPanel.delegate = self
        newPanel.setAccessibilityIdentifier("quickAskPanel")
        panel = newPanel
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(presentationPointer) }) ?? NSScreen.main {
            newPanel.setFrame(PopupPlacement.frame(pointer: presentationPointer, size: CGSize(width: 440, height: 280), visibleFrame: screen.visibleFrame), display: false)
        }
        resize()
        installFocusObservers()
        newPanel.makeKeyAndOrderFront(nil)
    }

    func resize() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel, let screen = NSScreen.screens.first(where: { $0.frame.contains(presentationPointer) }) ?? NSScreen.main else { return }
            let fittingSize = panel.contentView?.fittingSize ?? CGSize(width: 440, height: 280)
            panel.setFrame(PopupPlacement.frame(pointer: presentationPointer, size: CGSize(width: 440, height: max(240, fittingSize.height)), visibleFrame: screen.visibleFrame), display: true)
        }
    }

    func close(restoreFocus: Bool) {
        guard let panel, panel.isVisible, !isClosing else { return }
        isClosing = true
        let ownedFocus = panel.isKeyWindow
        panel.orderOut(nil)
        removeFocusObservers()
        controller.endPresentation()
        if restoreFocus && ownedFocus && !userChangedFocus,
           let application = originatingApplication, !application.isTerminated,
           NSWorkspace.shared.frontmostApplication?.processIdentifier != application.processIdentifier {
            application.activate(options: [])
        }
        isClosing = false
    }

    func windowDidResignKey(_ notification: Notification) {
        let expectedPresentation = presentationIdentifier
        DispatchQueue.main.async { [weak self] in
            guard let self, presentationIdentifier == expectedPresentation, !isClosing, NSApp.modalWindow == nil, panel?.isVisible == true, panel?.isKeyWindow == false else { return }
            userChangedFocus = true
            close(restoreFocus: false)
        }
    }

    private func installFocusObservers() {
        removeFocusObservers()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                   application.processIdentifier != originatingApplication?.processIdentifier {
                    userChangedFocus = true
                    close(restoreFocus: false)
                }
            }
        }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, NSApp.modalWindow == nil, let panel, !panel.frame.contains(NSEvent.mouseLocation) else { return }
                userChangedFocus = true
                close(restoreFocus: false)
            }
        }
    }

    private func removeFocusObservers() {
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        activationObserver = nil
        outsideClickMonitor = nil
    }

    deinit {
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
    }
}
