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
    case lastReply
}

@MainActor
final class QuickAskPanelManager: NSObject, NSWindowDelegate {
    private let controller: AskController
    private var panel: NSPanel?
    private var originatingApplication: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?
    private var outsideClickMonitor: Any?
    private var presentationPointer = CGPoint.zero
    /// Top edge fixed at open so the answer pushes content downward instead of re-centering the card.
    private var anchoredTop: CGFloat?
    private var userChangedFocus = false
    private var isClosing = false
    private var presentationIdentifier = UUID()
    private var scheduledResize: UUID?
    private var currentPresentation = QuickAskPresentation.ghost
    private let isUITest = ProcessInfo.processInfo.arguments.contains("--clicky-ui-test")

    init(controller: AskController) {
        self.controller = controller
        super.init()
        // A host edit closes Quick Ask without restoring focus; the writing coordinator returns focus to the
        // exact bound control itself, and only after the submit key is released.
        controller.writing.closeComposer = { [weak self] in self?.close(restoreFocus: false) }
        controller.writing.showNotice = { WritingNoticePanel.show($0) }
        // Quick Ask stays open after Enter: the answer appears under the input, which keeps focus for a follow-up.
    }

    func show(_ presentation: QuickAskPresentation = .ghost) {
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        // The shortcut must never type into an open Last reply panel: close it and open a fresh Quick Ask.
        if presentation == .ghost, currentPresentation != .ghost, panel?.isVisible == true { close(restoreFocus: false) }
        if let panel, panel.isVisible {
            if presentation != currentPresentation {
                presentationIdentifier = UUID()
                scheduledResize = nil
                currentPresentation = presentation
                panel.contentView = makeHostingView(for: presentation)
                if !isUITest { installFocusObservers() }
                resize()
            }
            panel.makeKeyAndOrderFront(nil)
            return
        }
        originatingApplication = WindowSnapshotCapture.originatingApplication()
        let testing = ProcessInfo.processInfo.arguments.contains("--clicky-ui-test")
        controller.beginPresentation(target: testing ? nil : WindowSnapshotCapture.target(for: originatingApplication))
        presentationIdentifier = UUID()
        userChangedFocus = false
        presentationPointer = NSEvent.mouseLocation
        anchoredTop = nil
        currentPresentation = presentation
        controller.editorGeneration = UUID()
        let newPanel = QuickAskPanel(contentRect: CGRect(x: 0, y: 0, width: panelWidth, height: 280),
                                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        newPanel.contentView = makeHostingView(for: presentation)
        newPanel.onCancel = { [weak self] in self?.escape() }
        newPanel.isFloatingPanel = true
        newPanel.level = .floating
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        // The ghost Quick Ask has no card, so a window shadow would draw a box around transparent space.
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
        currentPresentation == .ghost
            ? PopupPlacement.besideCompanion(pointer: pointer, size: size, visibleFrame: visibleFrame)
            : PopupPlacement.frame(pointer: pointer, size: size, visibleFrame: visibleFrame)
    }

    private var panelWidth: CGFloat { currentPresentation == .ghost ? IslandLayout.cursorAskWidth : 440 }

    private func makeHostingView(for presentation: QuickAskPresentation) -> NSHostingView<AnyView> {
        let onCancel: () -> Void = { [weak self] in self?.escape() }
        let expectedPresentation = presentationIdentifier
        let onLayoutChanged: () -> Void = { [weak self] in
            guard let self, presentationIdentifier == expectedPresentation else { return }
            resize()
        }
        let host: NSHostingView<AnyView>
        switch presentation {
        case .ghost:
            host = NSHostingView(rootView: AnyView(CursorAskView(controller: controller, onCancel: onCancel, onLayoutChanged: onLayoutChanged)))
        case .lastReply:
            let screen = NSScreen.screens.first(where: { $0.frame.contains(presentationPointer) }) ?? NSScreen.main
            host = NSHostingView(rootView: AnyView(QuickAskView(controller: controller, onCancel: onCancel, onLayoutChanged: onLayoutChanged,
                                                               maximumHeight: max(240, (screen?.visibleFrame.height ?? 800) - 24))))
        }
        host.frame = CGRect(x: 0, y: 0, width: panelWidth, height: 280)
        return host
    }

    func resize() {
        guard scheduledResize == nil else { return }
        let expectedPresentation = presentationIdentifier
        let request = UUID()
        scheduledResize = request
        DispatchQueue.main.async { [weak self] in
            guard let self, scheduledResize == request else { return }
            scheduledResize = nil
            guard presentationIdentifier == expectedPresentation, panel?.isVisible == true else { return }
            applyPanelLayout()
        }
    }

    private func applyPanelLayout() {
        guard let panel, let screen = NSScreen.screens.first(where: { $0.frame.contains(presentationPointer) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        guard ShellPanelLayout.isValid(visible) else { return }
        let isGhost = currentPresentation == .ghost
        let height = ShellPanelLayout.height(measured: panel.contentView?.fittingSize.height ?? 280,
                                             minimum: isGhost ? 30 : 240, maximum: visible.height)
        var frame = placement(pointer: presentationPointer, size: CGSize(width: panelWidth, height: height), visibleFrame: visible)
        if isGhost {
            let top = anchoredTop ?? frame.maxY
            anchoredTop = top
            frame = ShellPanelLayout.anchoredFrame(frame, top: top, visibleFrame: visible)
        }
        guard ShellPanelLayout.isValid(frame) else { return }
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    /// Escape stops a running reply first; the next Escape closes Quick Ask.
    private func escape() {
        if controller.isBusy || controller.writing.isBusy { controller.stopReply() } else { close(restoreFocus: true) }
    }

    /// While a reply is running Quick Ask stays put, so the answer always lands under the input.
    private var pinned: Bool { controller.isBusy || controller.writing.isBusy }

    func close(restoreFocus: Bool) {
        guard let panel, panel.isVisible, !isClosing else { return }
        isClosing = true
        presentationIdentifier = UUID()
        scheduledResize = nil
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
            guard let self, presentationIdentifier == expectedPresentation, !isClosing, !pinned, NSApp.modalWindow == nil,
                  panel?.isVisible == true, panel?.isKeyWindow == false else { return }
            userChangedFocus = true
            close(restoreFocus: false)
        }
    }

    private func installFocusObservers() {
        removeFocusObservers()
        let expectedPresentation = presentationIdentifier
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor [weak self] in
                guard let self, presentationIdentifier == expectedPresentation, panel?.isVisible == true else { return }
                if !pinned, application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                   application.processIdentifier != originatingApplication?.processIdentifier {
                    userChangedFocus = true
                    close(restoreFocus: false)
                }
            }
        }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, presentationIdentifier == expectedPresentation, !pinned, NSApp.modalWindow == nil,
                      let panel, panel.isVisible, !panel.frame.contains(NSEvent.mouseLocation) else { return }
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
