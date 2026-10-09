//
//  MenuBarPanelManager.swift
//  leanring-buddy
//
//  Manages the NSStatusItem (menu bar icon) and a custom borderless NSPanel
//  that drops down below it when clicked. The panel hosts a SwiftUI view
//  (CompanionPanelView) via NSHostingView. Uses the same NSPanel pattern as
//  FloatingSessionButton and GlobalPushToTalkOverlay for consistency.
//
//  The panel is non-activating so it does not steal focus from the user's
//  current app, and auto-dismisses when the user clicks outside.
//

import AppKit
import SwiftUI

extension Notification.Name {
    static let clickyDismissPanel = Notification.Name("clickyDismissPanel")
}

/// Custom NSPanel subclass that can become the key window even with
/// .nonactivatingPanel style, allowing text fields to receive focus.
private class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class MenuBarPanelManager: NSObject {
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var clickOutsideMonitor: Any?
    private var dismissPanelObserver: NSObjectProtocol?
    private var presentationIdentifier = UUID()
    private var scheduledLayout: UUID?

    private let companionManager: CompanionManager
    private let askController: AskController
    private let onOpenQuickAsk: (QuickAskPresentation) -> Void
    private let panelWidth: CGFloat = 320
    private let panelHeight: CGFloat = 380

    init(companionManager: CompanionManager, askController: AskController, onOpenQuickAsk: @escaping (QuickAskPresentation) -> Void) {
        self.companionManager = companionManager
        self.askController = askController
        self.onOpenQuickAsk = onOpenQuickAsk
        super.init()
        createStatusItem()

        dismissPanelObserver = NotificationCenter.default.addObserver(
            forName: .clickyDismissPanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.hidePanel()
        }
    }

    deinit {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let observer = dismissPanelObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Status Item

    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        guard let button = statusItem?.button else { return }

        button.image = makeClickyMenuBarIcon()
        button.image?.isTemplate = true
        button.action = #selector(statusItemClicked)
        button.target = self
    }

    /// Draws the clicky triangle as a menu bar icon. Uses the same shape
    /// and rotation as the in-app cursor so the menu bar icon matches.
    private func makeClickyMenuBarIcon() -> NSImage {
        let iconSize: CGFloat = 18
        let image = NSImage(size: NSSize(width: iconSize, height: iconSize))
        image.lockFocus()

        let triangleSize = iconSize * 0.7
        let cx = iconSize * 0.50
        let cy = iconSize * 0.50
        let height = triangleSize * sqrt(3.0) / 2.0

        let top = CGPoint(x: cx, y: cy + height / 1.5)
        let bottomLeft = CGPoint(x: cx - triangleSize / 2, y: cy - height / 3)
        let bottomRight = CGPoint(x: cx + triangleSize / 2, y: cy - height / 3)

        let angle = 35.0 * .pi / 180.0
        func rotate(_ point: CGPoint) -> CGPoint {
            let dx = point.x - cx, dy = point.y - cy
            let cosA = CGFloat(cos(angle)), sinA = CGFloat(sin(angle))
            return CGPoint(x: cx + cosA * dx - sinA * dy, y: cy + sinA * dx + cosA * dy)
        }

        let path = NSBezierPath()
        path.move(to: rotate(top))
        path.line(to: rotate(bottomLeft))
        path.line(to: rotate(bottomRight))
        path.close()

        NSColor.black.setFill()
        path.fill()

        image.unlockFocus()
        return image
    }

    /// Opens the panel automatically on app launch so the user sees
    /// permissions and the start button right away.
    func showPanelOnLaunch() {
        // Small delay so the status item has time to appear in the menu bar
        let expectedPresentation = presentationIdentifier
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, presentationIdentifier == expectedPresentation else { return }
            showPanel()
        }
    }

    @objc private func statusItemClicked() {
        if let panel, panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    // MARK: - Panel Lifecycle

    private func showPanel() {
        presentationIdentifier = UUID()
        scheduledLayout = nil
        if panel == nil {
            createPanel()
        }

        positionPanelBelowStatusItem(height: panel?.frame.height ?? panelHeight)

        panel?.makeKeyAndOrderFront(nil)
        panel?.orderFrontRegardless()
        installClickOutsideMonitor()
        schedulePanelLayout()
    }

    private func hidePanel() {
        presentationIdentifier = UUID()
        scheduledLayout = nil
        panel?.orderOut(nil)
        removeClickOutsideMonitor()
    }

    private func createPanel() {
        let companionPanelView = TextCompanionPanelView(controller: askController, companionManager: companionManager, onOpenQuickAsk: { [weak self] presentation in
            self?.hidePanel()
            self?.onOpenQuickAsk(presentation)
        })
            .frame(width: panelWidth)

        let hostingView = NSHostingView(rootView: companionPanelView)
        hostingView.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        let menuBarPanel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        menuBarPanel.isFloatingPanel = true
        menuBarPanel.level = .floating
        menuBarPanel.isOpaque = false
        menuBarPanel.backgroundColor = .clear
        menuBarPanel.hasShadow = false
        menuBarPanel.hidesOnDeactivate = false
        menuBarPanel.isExcludedFromWindowsMenu = true
        menuBarPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        menuBarPanel.isMovableByWindowBackground = false
        menuBarPanel.titleVisibility = .hidden
        menuBarPanel.titlebarAppearsTransparent = true

        menuBarPanel.contentView = hostingView
        panel = menuBarPanel
    }

    private func schedulePanelLayout() {
        guard scheduledLayout == nil else { return }
        let request = UUID()
        let expectedPresentation = presentationIdentifier
        scheduledLayout = request
        // The first hosting-view layout must finish before asking AppKit for its fitting size.
        DispatchQueue.main.async { [weak self] in
            guard let self, scheduledLayout == request else { return }
            scheduledLayout = nil
            guard presentationIdentifier == expectedPresentation, panel?.isVisible == true else { return }
            let measured = panel?.contentView?.fittingSize.height ?? panelHeight
            positionPanelBelowStatusItem(height: measured.isFinite && measured > 0 ? measured : panelHeight)
        }
    }

    private func positionPanelBelowStatusItem(height: CGFloat) {
        guard let panel, let buttonWindow = statusItem?.button?.window,
              let screen = buttonWindow.screen ?? NSScreen.main else { return }
        let statusItemFrame = buttonWindow.frame
        let visible = screen.visibleFrame
        guard ShellPanelLayout.isValid(statusItemFrame), ShellPanelLayout.isValid(visible) else { return }
        let gapBelowMenuBar: CGFloat = 4
        let width = min(panelWidth, visible.width)
        let actualHeight = ShellPanelLayout.height(measured: height, minimum: 30, maximum: visible.height)
        let x = max(visible.minX, min(statusItemFrame.midX - width / 2, visible.maxX - width))
        let top = min(visible.maxY, statusItemFrame.minY - gapBelowMenuBar)
        let frame = ShellPanelLayout.anchoredFrame(CGRect(x: x, y: top - actualHeight, width: width, height: actualHeight),
                                                   top: top, visibleFrame: visible)
        guard ShellPanelLayout.isValid(frame) else { return }
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    // MARK: - Click Outside Dismissal

    /// Installs a global event monitor that hides the panel when the user clicks
    /// anywhere outside it — the same transient dismissal behavior as NSPopover.
    /// Uses a short delay so that system permission dialogs (triggered by Grant
    /// buttons in the panel) don't immediately dismiss the panel when they appear.
    private func installClickOutsideMonitor() {
        removeClickOutsideMonitor()
        let expectedPresentation = presentationIdentifier

        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, presentationIdentifier == expectedPresentation, let panel = self.panel else { return }

            // Check if the click is inside the status item button — if so, the
            // statusItemClicked handler will toggle the panel, so don't also hide.
            let clickLocation = NSEvent.mouseLocation
            if panel.frame.contains(clickLocation) {
                return
            }

            // Delay dismissal slightly to avoid closing the panel when
            // a system permission dialog appears (e.g. microphone access).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self, weak panel] in
                guard let self, presentationIdentifier == expectedPresentation, panel?.isVisible == true else { return }

                guard NSApp.modalWindow == nil else { return }
                self.hidePanel()
            }
        }
    }

    private func removeClickOutsideMonitor() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
    }
}
