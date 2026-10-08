import AppKit
import SwiftUI

private final class QuickAskPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    /// The island hangs from the top edge over the menu bar; AppKit would push it below.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

enum QuickAskPresentation: Equatable {
    case ghost
    case details(showSettings: Bool)
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
    private var currentPresentation = QuickAskPresentation.ghost
    private let isUITest = ProcessInfo.processInfo.arguments.contains("--clicky-ui-test")

    init(controller: AskController) {
        self.controller = controller
        super.init()
        controller.onSubmitted = { [weak self] in
            // UI fixtures keep the panel visible to inspect preview output; production restores focus.
            if !ProcessInfo.processInfo.arguments.contains("--clicky-ui-test") { self?.close(restoreFocus: true) }
        }
    }

    func show(_ presentation: QuickAskPresentation = .ghost) {
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        if let panel, panel.isVisible {
            if presentation != currentPresentation {
                currentPresentation = presentation
                if case .details(let settings) = presentation { controller.showSettings = settings }
                panel.contentView = makeHostingView(for: presentation)
                resize()
            } else if case .details(true) = presentation {
                controller.showSettings = true
                resize()
            }
            panel.makeKeyAndOrderFront(nil)
            return
        }
        originatingApplication = NSWorkspace.shared.frontmostApplication
        let testing = ProcessInfo.processInfo.arguments.contains("--clicky-ui-test")
        controller.beginPresentation(target: testing ? nil : WindowSnapshotCapture.target(for: originatingApplication))
        presentationIdentifier = UUID()
        userChangedFocus = false
        presentationPointer = NSEvent.mouseLocation
        currentPresentation = presentation
        if case .details(let settings) = presentation { controller.showSettings = settings } else { controller.showSettings = false }
        controller.editorGeneration = UUID()
        let newPanel = QuickAskPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        newPanel.contentView = makeHostingView(for: presentation)
        newPanel.onCancel = { [weak self] in self?.close(restoreFocus: true) }
        newPanel.isFloatingPanel = true
        // The island version sits over the menu bar, like the status island it replaces.
        newPanel.level = presentation == .ghost ? .statusBar : .floating
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = presentation != .ghost
        newPanel.hidesOnDeactivate = false
        newPanel.isReleasedWhenClosed = false
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        newPanel.delegate = self
        newPanel.setAccessibilityIdentifier("quickAskPanel")
        panel = newPanel
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(presentationPointer) }) ?? NSScreen.main {
            newPanel.setFrame(placement(pointer: presentationPointer, size: CGSize(width: panelWidth, height: 280), visibleFrame: screen.visibleFrame), display: false)
        }
        resize()
        if !isUITest { installFocusObservers() }
        newPanel.makeKeyAndOrderFront(nil)
    }

    private func placement(pointer: CGPoint, size: CGSize, visibleFrame: CGRect) -> CGRect {
        guard currentPresentation == .ghost else { return PopupPlacement.frame(pointer: pointer, size: size, visibleFrame: visibleFrame) }
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        return IslandLayout.frame(screen: screen?.frame ?? visibleFrame, width: size.width, height: size.height)
    }

    private var panelWidth: CGFloat { currentPresentation == .ghost ? IslandLayout.askWidth : 440 }

    private func makeHostingView(for presentation: QuickAskPresentation) -> NSHostingView<AnyView> {
        let onCancel: () -> Void = { [weak self] in self?.close(restoreFocus: true) }
        let onLayoutChanged: () -> Void = { [weak self] in self?.resize() }
        switch presentation {
        case .ghost:
            let screen = NSScreen.screens.first(where: { $0.frame.contains(presentationPointer) }) ?? NSScreen.main
            let metrics = screen.map(IslandMetrics.init(screen:)) ?? IslandMetrics()
            return NSHostingView(rootView: AnyView(IslandAskView(controller: controller, metrics: metrics, onCancel: onCancel, onLayoutChanged: onLayoutChanged)))
        case .details:
            let screen = NSScreen.screens.first(where: { $0.frame.contains(presentationPointer) }) ?? NSScreen.main
            return NSHostingView(rootView: AnyView(QuickAskView(controller: controller, onCancel: onCancel, onLayoutChanged: onLayoutChanged,
                                                               maximumHeight: max(240, (screen?.visibleFrame.height ?? 800) - 24))))
        }
    }

    func resize() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel, let screen = NSScreen.screens.first(where: { $0.frame.contains(self.presentationPointer) }) ?? NSScreen.main else { return }
            let isGhost = currentPresentation == .ghost
            let fittingSize = panel.contentView?.fittingSize ?? CGSize(width: panelWidth, height: 280)
            panel.setFrame(placement(pointer: presentationPointer, size: CGSize(width: panelWidth, height: max(isGhost ? 30 : 240, fittingSize.height)), visibleFrame: screen.visibleFrame), display: true)
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
        guard !isUITest else { return }
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
