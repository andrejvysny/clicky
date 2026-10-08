import AppKit
import Combine
import ImageIO

@MainActor
final class VisualGuideController: ObservableObject {
    @Published var task: GuideTaskState?
    @Published var status = "Ready"
    @Published var error: String?
    @Published var isBusy = false
    @Published var lastSent: Date?
    @Published var proposal: GuidePresentation?
    @Published var needsSharingApproval = false
    @Published var currentTarget: WindowCaptureTarget?
    @Published var session: AgentSession?
    @Published var demo: GuidePreviewFixture?
    var onResponse: ((String) -> Void)?
    var onTarget: ((CGRect, String) -> Void)?
    var onClearTarget: (() -> Void)?
    /// One-off pointer annotation (global top-left rect, label); never part of task provenance.
    var onAnnotate: ((CGRect, String) -> Void)?
    @Published var needsDisplayApproval = false
    /// Session-scoped consent to send the display under the pointer when no window is focused.
    var displayApprovedThisSession = false
    /// Declined for the current request only; the next question may ask again.
    var displayDeclined = false
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
    var broaderPointer: CGPoint?
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

    init() {
        observer.onAction = { [weak self] in
            guard let self, let context = lastContext, task?.phase == .waiting, task?.isCurrent(context) == true else { return }
            task?.recordAttempt(); status = "Action detected · checking outcome"; publish()
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
        lastUserText = text; error = nil; proposal = nil
        let continuingClarification = awaitingClarification
        sideQuestion = task != nil && task?.phase != .completed && task?.phase != .canceled && !continuingClarification
        awaitingClarification = false
        if task == nil || task?.phase == .completed || task?.phase == .canceled {
            // Only an explicit raise restarts Claude; the default Low after a send keeps the conversation.
            if provider == .claude, agent != nil, effort != .low, effort != agentEffort { closeAgent() }
            task = GuideTaskState(goal: text); currentTarget = target
        }
        if task?.grant == nil, explicitlyVisual, let currentTarget { task?.authorize(currentTarget) }
        if task?.phase == .paused { task?.resume() }
        task?.beginRequest(); displayDeclined = false
        pendingEffort = effort
        let purpose = sideQuestion ? "Related user question; preserve active task. A different goal must be task_proposal."
            : (continuingClarification ? "User reply to clarification; continue the existing goal or propose a different task." : "User goal; choose presentation.")
        launch(message: purpose + "\n" + text, captureFirst: explicitlyVisual)
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
        guard !isBusy, let currentTarget, ScopedAccessibility.focused(currentTarget) else {
            error = "Activate the approved target window, then Resume; or choose Change target."; publish(); return
        }
        task?.resume(); retry()
    }
    func retry() {
        guard !isBusy, task != nil else { return }
        if needsSharingApproval { return }
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
    func finishManually() {
        if demo != nil { while demo?.completed == false { demo?.resume(); demo?.next() }; status = "Demo finished manually · no verification"; publish(); return }
        transaction &+= 1; work?.cancel(); work = nil
        task?.finishManually(); closeAgent(); stopObservation(); onClearTarget?()
        lastImage = nil; lastContext = nil; isBusy = false; status = "Finished manually · not verified"; publish()
    }
    func endTask() {
        demo = nil
        walkthroughPresented = false
        awaitingClarification = false
        transaction &+= 1; work?.cancel(); work = nil
        task?.cancel(); closeAgent(); stopObservation(); onClearTarget?()
        task = nil; currentTarget = nil; proposal = nil; pendingContextRequest = nil
        lastImage = nil; lastContext = nil; session = nil; isBusy = false; needsSharingApproval = false; needsDisplayApproval = false
        status = "Ready"; error = nil; publish()
    }
    func authorizeWindow(_ target: WindowCaptureTarget) {
        guard !isBusy, task != nil else { return }
        task?.authorize(target, replace: true); currentTarget = target; needsSharingApproval = false
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
    func shareBroaderOnce() {
        guard !isBusy, task != nil else { return }
        let pointer = NSEvent.mouseLocation
        let height = (NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens.first)?.frame.height ?? 0
        let approvedPointer = CGPoint(x: pointer.x, y: height - pointer.y)
        let alert = NSAlert(); alert.messageText = "Share the display under the pointer once?"
        alert.informativeText = "Other applications on that display will be visible to the selected provider. This does not expand the task's window grant."
        alert.addButton(withTitle: "Share display once"); alert.addButton(withTitle: "Cancel")
        if alert.runModal() != .alertFirstButtonReturn { return }
        broaderPointer = approvedPointer
        lastImage = nil; lastContext = nil
        launch(message: "One explicitly authorized display overview. Explain what is needed; request the approved window before guiding.", broaderOnce: true)
    }
    func approveDisplay() {
        guard needsDisplayApproval else { return }
        needsDisplayApproval = false; displayApprovedThisSession = true; pendingContextRequest = nil
        broaderPointer = Self.pointerInTopLeftPoints()
        launch(message: "User shared the display. Answer using this overview.", broaderOnce: true)
    }
    func declineDisplay() {
        needsDisplayApproval = false; pendingContextRequest = nil; displayDeclined = true
        launch(message: "User declined screen sharing. Answer from text alone; do not request context again.")
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
    func invalidateTarget() {
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
        return "Task: " + task.goal + "\nCompleted milestones: " + task.milestones.map {
            $0.instruction + " (" + $0.completion.rawValue + ")"
        }.joined(separator: "; ") + "\nCurrent step: " + (task.step?.text ?? "locate next action")
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
