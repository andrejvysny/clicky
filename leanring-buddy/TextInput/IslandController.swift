import AppKit
import Combine
import SwiftUI

/// The notch island appears only for walkthrough instructions: the current step, or a blocked or uncertain one.
/// Conversation stays in Quick Ask under the input; the companion spins while working and turns red on error.
@MainActor
final class IslandController: ObservableObject {
    enum Mode: Equatable { case hidden, guide, guideAttention }

    @Published private(set) var mode: Mode = .hidden
    @Published private(set) var metrics = IslandMetrics()
    /// User hid the step card; reset when the step changes or the walkthrough ends.
    @Published var guideCollapsed = false
    let ask: AskController
    var guide: VisualGuideController { ask.guide }
    /// Reply shortcuts exist only while Quick Ask shows a reply, so they never shadow editor bindings otherwise.
    var onReplyAvailabilityChanged: ((Bool) -> Void)?
    /// Companion cursor state: (working, failed).
    var onCompanionState: ((Bool, Bool) -> Void)?

    private var cancellables: Set<AnyCancellable> = []
    private var panel: NSPanel?
    private var refreshScheduled = false
    private var layoutScheduled = false
    private var lastStepCount = 0

    init(ask: AskController) {
        self.ask = ask
        ask.objectWillChange.sink { [weak self] in self?.scheduleRefresh() }.store(in: &cancellables)
        ask.guide.objectWillChange.sink { [weak self] in self?.scheduleRefresh() }.store(in: &cancellables)
    }

    func toggleGuide() { guideCollapsed.toggle(); refresh() }

    /// objectWillChange fires before the value changes; read state on the next turn of the run loop.
    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in self?.refreshScheduled = false; self?.refresh() }
    }

    func refresh() {
        let stepCount = guide.task?.milestones.count ?? 0
        if !walkthroughVisible || stepCount != lastStepCount { guideCollapsed = false }
        lastStepCount = stepCount
        let next = computeMode()
        if next != mode { mode = next }
        onReplyAvailabilityChanged?(ask.isComposing && !ask.response.isEmpty)
        // A walkthrough reports its own errors in the island; other failures show under the input.
        onCompanionState?(ask.isBusy, !ask.isBusy && !walkthroughVisible && ask.errorMessage != nil)
        layoutPanel()
    }

    private var walkthroughVisible: Bool {
        guard let task = guide.task, guide.walkthroughPresented else { return false }
        return task.phase != .completed && task.phase != .canceled
    }

    /// A condition that needs the user, so the island stays expanded and cannot be hidden.
    var isBlocked: Bool {
        let phase = guide.task?.phase
        return guide.proposal != nil
            || (walkthroughVisible && (phase == .paused || phase == .uncertain || guide.error != nil))
    }

    private func computeMode() -> Mode {
        if ask.isComposing { return .hidden }
        if guide.demo != nil || isBlocked { return .guideAttention }
        if walkthroughVisible { return guideCollapsed ? .guide : .guideAttention }
        return .hidden
    }

    var width: CGFloat {
        switch mode {
        case .guideAttention: return IslandLayout.replyWidth
        default: return metrics.compactWidth
        }
    }

    func layoutPanel() {
        // Geometry preferences can fire during NSHostingView layout; measuring synchronously reenters it.
        guard !layoutScheduled else { return }
        layoutScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            layoutScheduled = false
            applyPanelLayout()
        }
    }

    private func applyPanelLayout() {
        guard mode != .hidden else { panel?.orderOut(nil); return }
        let panel = self.panel ?? makePanel()
        // Pick the display when the island appears; keep it while visible so it never jumps screens.
        let screen = panel.isVisible ? (panel.screen ?? IslandMetrics.pointerScreen()) : IslandMetrics.pointerScreen()
        guard let screen else { return }
        guard ShellPanelLayout.isValid(screen.frame) else { return }
        let newMetrics = IslandMetrics(screen: screen)
        if newMetrics != metrics { metrics = newMetrics }
        let height = ShellPanelLayout.height(measured: panel.contentView?.fittingSize.height ?? metrics.headerHeight,
                                             minimum: metrics.headerHeight, maximum: screen.frame.height)
        let frame = IslandLayout.frame(screen: screen.frame, width: width, height: height)
        guard ShellPanelLayout.isValid(frame) else { return }
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let initialFrame = CGRect(x: 0, y: 0, width: width, height: metrics.headerHeight)
        let panel = IslandPanel(contentRect: initialFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isExcludedFromWindowsMenu = true
        panel.setAccessibilityIdentifier("clickyIsland")
        let host = NSHostingView(rootView: IslandView(controller: self))
        host.frame = initialFrame
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        self.panel = panel
        return panel
    }

    /// Overlays to exclude from any capture.
    var windowNumbers: Set<Int> { panel.map { $0.windowNumber > 0 ? [$0.windowNumber] : [] } ?? [] }
}

/// Never key: island buttons accept clicks without activating Clicky; only Quick Ask takes focus.
private final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
