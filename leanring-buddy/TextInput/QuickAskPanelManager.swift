import AppKit
import SwiftUI

private final class QuickAskPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
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
    private var followTimer: Timer?
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
                updatePointerFollowing()
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
            newPanel.setFrame(placement(pointer: presentationPointer, size: CGSize(width: panelWidth, height: 280), visibleFrame: screen.visibleFrame), display: false)
        }
        resize()
        installFocusObservers()
        newPanel.makeKeyAndOrderFront(nil)
        updatePointerFollowing()
    }

    private func placement(pointer: CGPoint, size: CGSize, visibleFrame: CGRect) -> CGRect {
        currentPresentation == .ghost
            ? PopupPlacement.besideCompanion(pointer: pointer, size: size, visibleFrame: visibleFrame)
            : PopupPlacement.frame(pointer: pointer, size: size, visibleFrame: visibleFrame)
    }

    /// The ghost input travels with the pointer beside the companion. The UI-test fixture keeps it
    /// stationary because XCUITest moves the pointer onto the elements it clicks.
    private func updatePointerFollowing() {
        followTimer?.invalidate()
        followTimer = nil
        guard currentPresentation == .ghost, !isUITest else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.followPointer() }
        }
        RunLoop.main.add(timer, forMode: .common)
        followTimer = timer
    }

    private func followPointer() {
        // Holding Option pins the pill so its buttons can be reached with the mouse.
        guard let panel, panel.isVisible, currentPresentation == .ghost, !NSEvent.modifierFlags.contains(.option) else { return }
        let pointer = NSEvent.mouseLocation
        guard pointer != presentationPointer,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main else { return }
        presentationPointer = pointer
        panel.setFrame(placement(pointer: pointer, size: panel.frame.size, visibleFrame: screen.visibleFrame), display: false)
    }

    private var panelWidth: CGFloat { currentPresentation == .ghost ? 300 : 440 }

    private func makeHostingView(for presentation: QuickAskPresentation) -> NSHostingView<AnyView> {
        let onCancel: () -> Void = { [weak self] in self?.close(restoreFocus: true) }
        let onLayoutChanged: () -> Void = { [weak self] in self?.resize() }
        switch presentation {
        case .ghost:
            return NSHostingView(rootView: AnyView(GhostAskView(controller: controller, onCancel: onCancel, onLayoutChanged: onLayoutChanged)))
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
        followTimer?.invalidate()
        followTimer = nil
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
