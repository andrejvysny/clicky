import AppKit
import Combine
import SwiftUI

/// Notch-anchored status surface. Derives one mode from Ask/guide state; grows only for a reply,
/// an uncertain or blocked step, a display-sharing question, or an expanded error.
@MainActor
final class IslandController: ObservableObject {
    enum Mode: Equatable { case hidden, working, reply, replyTucked, guide, guideAttention, displayApproval, error }

    @Published private(set) var mode: Mode = .hidden
    @Published private(set) var metrics = IslandMetrics()
    @Published var errorExpanded = false
    @Published var guideExpanded = false
    let ask: AskController
    var guide: VisualGuideController { ask.guide }
    /// Reply shortcuts exist only while the reply is expanded, so they never shadow editor bindings otherwise.
    var onReplyAvailabilityChanged: ((Bool) -> Void)?

    private var replyExpanded = false
    private var seenReply: Date?
    private var cancellables: Set<AnyCancellable> = []
    private var panel: NSPanel?
    private var clickMonitor: Any?
    private var refreshScheduled = false

    init(ask: AskController) {
        self.ask = ask
        ask.objectWillChange.sink { [weak self] in self?.scheduleRefresh() }.store(in: &cancellables)
        ask.guide.objectWillChange.sink { [weak self] in self?.scheduleRefresh() }.store(in: &cancellables)
    }

    func toggleReply() {
        guard !ask.response.isEmpty else { return }
        replyExpanded.toggle(); refresh()
    }
    func tuckReply() { if replyExpanded { replyExpanded = false; refresh() } }
    func toggleGuide() { guideExpanded.toggle(); refresh() }
    func toggleError() { errorExpanded.toggle(); refresh() }

    /// objectWillChange fires before the value changes; read state on the next turn of the run loop.
    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in self?.refreshScheduled = false; self?.refresh() }
    }

    func refresh() {
        if ask.lastReplyAt != seenReply { seenReply = ask.lastReplyAt; replyExpanded = ask.lastReplyAt != nil }
        if ask.response.isEmpty || ask.isComposing { replyExpanded = false }
        if ask.errorMessage == nil { errorExpanded = false }
        if !walkthroughVisible { guideExpanded = false }
        let next = computeMode()
        if next != mode { mode = next }
        onReplyAvailabilityChanged?(next == .reply)
        // SwiftUI applies the new mode on the next pass; measure after it.
        DispatchQueue.main.async { [weak self] in self?.layoutPanel() }
        updateClickMonitor()
    }

    private var walkthroughVisible: Bool {
        guard let task = guide.task, guide.walkthroughPresented else { return false }
        return task.phase != .completed && task.phase != .canceled
    }

    private func computeMode() -> Mode {
        if ask.isComposing { return .hidden }
        if guide.needsDisplayApproval { return .displayApproval }
        let phase = guide.task?.phase
        let blocked = guide.needsSharingApproval || guide.proposal != nil
            || (walkthroughVisible && (phase == .paused || phase == .uncertain || guide.error != nil))
        if guide.demo != nil || blocked { return .guideAttention }
        if ask.isBusy { return .working }
        if replyExpanded { return .reply }
        if walkthroughVisible { return guideExpanded ? .guideAttention : .guide }
        if ask.errorMessage != nil { return .error }
        if !ask.response.isEmpty { return .replyTucked }
        return .hidden
    }

    var width: CGFloat {
        switch mode {
        case .reply, .guideAttention, .displayApproval: return IslandLayout.replyWidth
        case .error where errorExpanded: return IslandLayout.replyWidth
        case .error: return metrics.compactWidth + 40
        default: return metrics.compactWidth
        }
    }

    func layoutPanel() {
        guard mode != .hidden else { panel?.orderOut(nil); return }
        let panel = self.panel ?? makePanel()
        // Pick the display when the island appears; keep it while visible so it never jumps screens.
        let screen = panel.isVisible ? (panel.screen ?? IslandMetrics.pointerScreen()) : IslandMetrics.pointerScreen()
        guard let screen else { return }
        let newMetrics = IslandMetrics(screen: screen)
        if newMetrics != metrics { metrics = newMetrics }
        let height = max(metrics.headerHeight, panel.contentView?.fittingSize.height ?? metrics.headerHeight)
        panel.setFrame(IslandLayout.frame(screen: screen.frame, width: width, height: height), display: true)
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let panel = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
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
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        self.panel = panel
        return panel
    }

    /// An expanded reply tucks to a dot as soon as the user clicks in their app, without a timer.
    private func updateClickMonitor() {
        let wanted = mode == .reply
        if wanted, clickMonitor == nil {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.tuckReply() }
            }
        } else if !wanted, let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor); clickMonitor = nil
        }
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
