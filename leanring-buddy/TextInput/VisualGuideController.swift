import AppKit
import Combine
import ImageIO
import OSLog

/// A located mark in global top-left points, ready for the overlay.
struct GuideMark {
    let mark: GuidePresentation.Mark
    let target: CGRect
    /// Drawn beside the mark; nil for walkthrough steps, whose instruction lives in the island.
    let label: String?
    let value: String?
    let ghost: CGRect?
    /// The shared window or display; labels stay inside it.
    let within: CGRect?
    var avoidRects: [CGRect] = []
}

@MainActor
final class VisualGuideController: ObservableObject {
    @Published var task: GuideTaskState?
    @Published var status = "Ready"
    @Published var error: String?
    @Published var isBusy = false
    @Published var lastSent: Date?
    @Published var proposal: GuidePresentation?
    @Published var currentTarget: WindowCaptureTarget?
    @Published var session: AgentSession?
    @Published var demo: GuidePreviewFixture?
    var onResponse: ((String) -> Void)?
    var onTarget: ((GuideMark) -> Void)?
    var onClearTarget: (() -> Void)?
    /// One-off pointer annotation; never part of task provenance.
    var onAnnotate: ((GuideMark) -> Void)?
    var onClearAnnotation: (() -> Void)?
    var defaults = UserDefaults.standard
    /// Consent given once at setup to share the display under the pointer when no window is focused; revocable in Settings.
    var displaySharingApproved: Bool {
        get { defaults.bool(forKey: Self.displaySharingKey) }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: Self.displaySharingKey)
            if !newValue, currentTarget?.displayIdentifier != nil {
                pause(message: "Display sharing is off · Enable it in Settings or choose a window")
            }
        }
    }
    static let displaySharingKey = "displaySharingApproved"
    /// Appended once to a text-only answer when the question needed the screen but sharing is off.
    var sharingHint: String?
    var onStateChanged: (() -> Void)?
    var provider: AgentProvider = .preview
    var executable: URL?
    var sharingPreference: ScreenInclusionPreference = .always
    var profileRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Clicky/Agents", isDirectory: true)

    var agent: GuideAgentSession?
    var work: Task<Void, Never>?
    var lastImage: PNGImageAttachment?
    var lastContext: GuideCaptureContext?
    var capturedWindowBounds: [UInt32: CGRect] = [:]
    var pendingContextRequest: GuidePresentation?
    var lastUserText = ""
    var transaction: UInt64 = 0
    var composerOpen = false
    var sideQuestion = false
    var axOutcomeWasSatisfied: Bool?
    var walkthroughPresented = false
    var awaitingClarification = false
    var agentGeneration: UInt64 = 0
    /// Effort chosen for the next user prompt; consumed by one launch, follow-up checks run at `.low`.
    var pendingEffort: AskEffort = .low
    var activeEffort: AskEffort = .low
    /// Effort the running Claude process was launched with.
    var agentEffort: AskEffort = .low
    /// Effort that actually produced the latest reply, for the bubble footer.
    var replyEffort: AskEffort { provider == .claude ? agentEffort : activeEffort }
    var observer = GuideObserver()
    var targetGuard: Task<Void, Never>?
    var targetGuardSuspendedUntil = Date.distantPast

    init() {
        observer.onAction = { [weak self] in
            guard let self, let context = lastContext, task?.phase == .waiting, task?.isCurrent(context) == true else { return }
            targetGuard?.cancel(); targetGuard = nil
            task?.recordAttempt(); status = "Action detected · checking outcome"; publish()
        }
        observer.onInteractionBegan = { [weak self] in
            // Button press/hover feedback is expected until the corresponding mouse-up is observed.
            self?.targetGuardSuspendedUntil = Date().addingTimeInterval(NSEvent.doubleClickInterval + 0.25)
        }
        observer.onEvidence = { [weak self] in self?.checkNow() }
        observer.onInvalidated = { [weak self] in self?.invalidateTarget() }
        observer.onUnavailable = { [weak self] in self?.pause(message: "Target unavailable or another window is active. Resume or change target.") }
    }

    /// Claude fixes effort per process, so it can change only before a task session starts.
    /// Between tasks a different effort restarts the Claude conversation; during a task it stays fixed.
    var effortAdjustable: Bool { provider == .codex || (provider == .claude && (agent == nil || task == nil)) }

    func ask(_ text: String, target: WindowCaptureTarget?, explicitlyVisual: Bool = false, effort: AskEffort = .low) throws {
        guard !isBusy else { throw AskError.busy }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AskError.emptyPrompt }
        guard text.utf8.count <= 65_536 else { throw AskError.promptTooLarge }
        lastUserText = text; error = nil; proposal = nil; pendingContextRequest = nil; sharingHint = nil
        onClearAnnotation?()
        // With no focused window (e.g. the desktop) the display under the pointer at ask time is the shared target.
        let target = target ?? (sharingPreference != .off && displaySharingApproved
            ? WindowSnapshotCapture.displayTarget(containing: Self.pointerInTopLeftPoints()) : nil)
        let continuingClarification = awaitingClarification
        // Only a walkthrough the user can see is preserved; a task left paused by an error is simply replaced.
        sideQuestion = walkthroughActive && !continuingClarification
        awaitingClarification = false
        if !sideQuestion && !continuingClarification {
            // Only an explicit raise restarts Claude; the default Low after a send keeps the conversation.
            if provider == .claude, agent != nil, effort != .low, effort != agentEffort { closeAgent() }
            walkthroughPresented = false
            task = GuideTaskState(goal: text); currentTarget = target; lastImage = nil; lastContext = nil
        } else if task?.grant == nil, let target {
            currentTarget = target
        }
        if task?.grant == nil, explicitlyVisual, let currentTarget { task?.authorize(currentTarget) }
        if task?.phase == .paused { task?.resume() }
        task?.beginRequest()
        pendingEffort = effort
        let purpose = sideQuestion ? "Related user question; preserve active task. A different goal must be task_proposal."
            : (continuingClarification ? "User reply to clarification; continue the existing goal or propose a different task." : "User goal; choose presentation.")
        launch(message: purpose + "\n" + text, captureFirst: explicitlyVisual)
    }

    var walkthroughActive: Bool {
        guard walkthroughPresented, let phase = task?.phase else { return false }
        return phase != .completed && phase != .canceled
    }

    func composerWillOpen() {
        composerOpen = true; stopObservation(); onClearTarget?()
        if task?.step != nil { task?.pause(); status = "Guide paused while editing"; publish() }
    }
    func composerDidClose(submitted: Bool) {
        composerOpen = false
        if !submitted, task?.step != nil { status = "Guide paused · Resume to refresh"; publish() }
    }
    func pause(message: String = "Sharing paused") {
        if demo != nil { demo?.pause(); status = "Demo paused · no AI"; publish(); return }
        let active = isBusy
        transaction &+= 1; work?.cancel(); work = nil; isBusy = false
        task?.pause(); stopObservation(); onClearTarget?()
        if active { closeAgent() }
        lastImage = nil; lastContext = nil; status = message; publish()
    }
    func resume() {
        if demo != nil { demo?.resume(); status = "Demo · no AI · manual checklist"; publish(); return }
        guard currentTarget?.displayIdentifier == nil || displaySharingApproved else {
            error = "Display sharing is off. Enable it in Settings or choose a window."; publish(); return
        }
        guard !isBusy, let currentTarget, ScopedAccessibility.focused(currentTarget) else {
            error = "Activate the approved target window, then Resume; or choose Change target."; publish(); return
        }
        task?.resume(); retry()
    }
    func retry() {
        guard !isBusy, task != nil else { return }
        if task?.phase == .paused { task?.resume() }
        task?.beginRequest(); sideQuestion = false
        launch(message: recoveryMessage() + "\nLocate the current step again against fresh context.", captureFirst: true)
    }
    func checkNow() {
        guard !isBusy, !composerOpen, task?.beginVerification() == true else { return }
        sideQuestion = false; stopObservation(); onClearTarget?()
        launch(message: "Verify only the current intended outcome.", verifying: true)
    }
    func nextManually() {
        if demo != nil { demo?.next(); status = demo?.completed == true ? "Demo finished manually · no verification" : "Demo · no AI · manual checklist"; publish(); return }
        guard !isBusy, task?.step != nil else { return }
        stopObservation(); onClearTarget?()
        if task?.phase == .paused { task?.resume() }
        task?.manualNext(); task?.beginRequest(); sideQuestion = false
        launch(message: recoveryMessage() + "\nUser manually acknowledged the last step; it is NOT verified. Locate the next step.", captureFirst: true)
    }
    /// Re-locates the previous milestone against fresh context. The model presents it again; it is never marked verified.
    func back() {
        guard demo == nil, !isBusy, let previous = task?.milestones.last else { return }
        stopObservation(); onClearTarget?()
        if task?.phase == .paused { task?.resume() }
        task?.beginRequest(); sideQuestion = false
        launch(message: recoveryMessage() + "\nUser went back to the previous step: \"" + previous.instruction
               + "\". Present that step again against fresh context.", captureFirst: true)
    }
    func finishManually() {
        if demo != nil { while demo?.completed == false { demo?.resume(); demo?.next() }; status = "Demo finished manually · no verification"; publish(); return }
        transaction &+= 1; work?.cancel(); work = nil
        task?.finishManually(); closeAgent(); stopObservation(); onClearTarget?(); walkthroughPresented = false
        lastImage = nil; lastContext = nil; isBusy = false; status = "Finished manually · not verified"; publish()
        onResponse?(status)
    }
    func endTask() {
        demo = nil
        walkthroughPresented = false
        awaitingClarification = false
        transaction &+= 1; work?.cancel(); work = nil
        task?.cancel(); closeAgent(); stopObservation(); onClearTarget?()
        task = nil; currentTarget = nil; proposal = nil; pendingContextRequest = nil
        lastImage = nil; lastContext = nil; session = nil; isBusy = false; sharingHint = nil
        status = "Ready"; error = nil; publish()
    }
    func authorizeWindow(_ target: WindowCaptureTarget) {
        guard !isBusy, task != nil else { return }
        task?.authorize(target, replace: true); currentTarget = target
        if task?.phase == .paused { task?.resume() }
        if let pendingContextRequest {
            self.pendingContextRequest = nil
            launch(message: "User granted this window. Inspect fresh approved context.", captureFirst: true, crop: pendingContextRequest.crop)
        } else { retry() }
    }
    func chooseTarget() {
        guard !isBusy else { return }
        let picker = NSAlert(); picker.messageText = "Choose one window to share for this task"
        picker.informativeText = "Only the selected window and established related UI may be inspected. Other windows remain outside this grant."
        let targets = availableTargets()
        guard !targets.isEmpty else { error = "No available target windows."; publish(); return }
        let list = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 340, height: 26))
        list.addItems(withTitles: targets.map(\.label))
        picker.accessoryView = list; picker.addButton(withTitle: "Share selected window"); picker.addButton(withTitle: "Cancel")
        if picker.runModal() == .alertFirstButtonReturn { authorizeWindow(targets[list.indexOfSelectedItem].target) }
    }
    static func pointerInTopLeftPoints() -> CGPoint {
        let pointer = NSEvent.mouseLocation
        let height = (NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens.first)?.frame.height ?? 0
        return CGPoint(x: pointer.x, y: height - pointer.y)
    }
    func keepTask() { proposal = nil; task?.pause(); status = "Current task preserved · Resume when ready"; publish() }
    func acceptProposal() {
        guard let goal = proposal?.proposedGoal else { return }
        let target = currentTarget; endTask()
        do { try ask(goal, target: target) } catch { self.error = error.localizedDescription; publish() }
    }
    func invalidateTarget(reason: String = "observed_change") {
        observer.cancelPendingMousePress()
        #if DEBUG
        Logger(subsystem: "clicky", category: "guide").info("target invalidated reason=\(reason, privacy: .public)")
        #endif
        targetGuard?.cancel(); targetGuard = nil
        task?.changed(); onClearTarget?(); lastImage = nil; lastContext = nil
        status = "View changed · Check now or Retry"; publish()
    }
    func publish() {
        onStateChanged?()
    }
    func closeAgent() {
        agentGeneration &+= 1
        let old = agent; agent = nil; session = nil
        Task { await old?.close() }
    }
    func startDemo() {
        guard provider == .preview, !isBusy, task == nil || task?.phase == .completed else { return }
        endTask(); demo = GuidePreviewFixture(); status = "Demo · no AI · manual checklist"; publish()
    }
    func recoveryMessage() -> String {
        guard let task else { return "" }
        var message = "Task: " + task.goal
        if !task.milestones.isEmpty {
            message += "\nCompleted milestones: " + task.milestones.map { $0.instruction + " (" + $0.completion.rawValue + ")" }.joined(separator: "; ")
        }
        // Naming a step only when one exists keeps pointing questions from being read as walkthroughs.
        if let step = task.step { message += "\nCurrent step: " + step.text }
        return message
    }
    private func availableTargets() -> [(target: WindowCaptureTarget, label: String)] {
        let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return raw.compactMap { entry in
            guard let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  pid != ProcessInfo.processInfo.processIdentifier,
                  let id = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular,
                  let rawBounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: rawBounds as CFDictionary), bounds.width > 1, bounds.height > 1 else { return nil }
            let name = app.localizedName ?? "Application"
            let title = entry[kCGWindowName as String] as? String ?? "Untitled window"
            let target = WindowCaptureTarget(processIdentifier: pid, windowIdentifier: id,
                                            applicationIdentifier: app.bundleIdentifier ?? "pid:\(pid)", applicationName: name)
            return (target, name + " · " + title + " · " + String(id))
        }
    }
}
