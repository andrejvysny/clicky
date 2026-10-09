import AppKit
import Combine
import ImageIO
import OSLog
#if canImport(ClickyCore)
import ClickyCore
#endif

/// A located mark in global top-left points, ready for the overlay.
struct GuideMark {
    let mark: GuidePresentation.Mark
    let target: CGRect
    /// Drawn beside the mark: the short action for a step (or its consequence warning), the label for an annotation.
    let label: String?
    let value: String?
    let ghost: CGRect?
    /// The shared window or display; labels stay inside it.
    let within: CGRect?
    var avoidRects: [CGRect] = []
    /// A destructive or externally committing step: drawn in the warning tone with its consequence.
    var warning = false
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
    /// Wrong-target select-only mode; nothing completes while it is on.
    @Published var correcting = false
    var selectionSurface: GuideSelectionSurface?
    var pendingSelection: CGPoint?
    var onResponse: ((String) -> Void)?
    var onTarget: ((GuideMark) -> Void)?
    var onClearTarget: (() -> Void)?
    /// One-off pointer annotation; never part of task provenance.
    var onAnnotate: ((GuideMark) -> Void)?
    var onClearAnnotation: (() -> Void)?
    var defaults = UserDefaults.standard
    /// Preference: may Clicky offer to share the display when no window is focused. Never a live grant;
    /// each running Clicky process asks once per display and provider (`displayConsent`).
    var displayFallbackAllowed: Bool {
        get { defaults.object(forKey: GuideDisplayConsent.preferenceKey) as? Bool ?? true }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: GuideDisplayConsent.preferenceKey)
            if !newValue { revokeDisplaySharing() }
        }
    }
    /// In-memory session grant; cleared by relaunch and revocation.
    var displayConsent = GuideDisplayConsent()
    /// Identifies one submitted question so Text only declines just that request.
    var requestGeneration: UInt64 = 0
    var displayGranted: Bool {
        guard let display = currentTarget?.displayIdentifier else { return true }
        return displayConsent.grant == GuideDisplayConsent.Grant(display: display, provider: provider)
    }
    func revokeDisplaySharing() {
        displayConsent.revoke()
        if currentTarget?.displayIdentifier != nil {
            pause(message: "Display sharing is off · Ask again to approve, or choose a window", reason: .sharingRevoked)
        } else { publish() }
    }
    /// Appended once to a text-only answer when the question needed the screen but sharing is off.
    var sharingHint: String?
    var onStateChanged: (() -> Void)?
    var provider: AgentProvider = .preview
    var executable: URL?
    var sharingPreference: ScreenInclusionPreference = .always
    var profileRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Clicky/Agents", isDirectory: true)

    var agent: (any GuideAgentRunning)?
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
    let environment: GuideEnvironment
    let observer: GuideObserver
    var targetGuard: Task<Void, Never>?
    var targetGuardSuspendedUntil = Date.distantPast
    /// Where the current step was presented, so uncertainty can keep observing the same target.
    var stepScreenRect: CGRect?
    var stepSnapshot: GuideStepSnapshot?
    var activationWatch: GuideEventSources?
    var stepWindowBounds: CGRect?
    var attemptAt: Date?
    var lastAdvanceAt: Date?
    /// Content-free cost and latency counters for this Clicky process.
    var metrics = GuideMetrics()

    init(environment: GuideEnvironment? = nil) {
        let environment = environment ?? .live
        self.environment = environment
        observer = GuideObserver(environment: environment)
        observer.onAction = { [weak self] in self?.attemptObserved() }
        observer.onInteractionBegan = { [weak self] in
            // Button press/hover feedback is expected until the corresponding mouse-up is observed.
            guard let self else { return }
            targetGuardSuspendedUntil = environment.now().addingTimeInterval(NSEvent.doubleClickInterval + 0.25)
        }
        observer.onEvidence = { [weak self] in self?.evidenceObserved() }
        observer.onInvalidated = { [weak self] in self?.relocateTarget(reason: "observed_change") }
        observer.onUnavailable = { [weak self] in self?.interruptForAppSwitch() }
        observer.onClosed = { [weak self] in
            self?.pause(message: "Target closed or minimized · Choose a window to resume", reason: .targetClosed)
        }
    }

    /// Claude fixes effort per process, so it can change only before a task session starts.
    /// Between tasks a different effort restarts the Claude conversation; during a task it stays fixed.
    var effortAdjustable: Bool { provider == .codex || (provider == .claude && (agent == nil || task == nil)) }

    func ask(_ text: String, target: WindowCaptureTarget?, explicitlyVisual: Bool = false, effort: AskEffort = .low) throws {
        guard !isBusy else { throw AskError.busy }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AskError.emptyPrompt }
        guard text.utf8.count <= 65_536 else { throw AskError.promptTooLarge }
        if correcting {
            // Typed Wrong-target correction: the text describes the intended control for the same step.
            lastUserText = text
            if task?.clearTemporaryInterruption(.composer) == true { task?.resume() }
            correct(description: text); return
        }
        lastUserText = text; error = nil; proposal = nil; pendingContextRequest = nil; sharingHint = nil
        requestGeneration &+= 1
        onClearAnnotation?()
        // With no focused window (e.g. the desktop) the display under the pointer at ask time is bound now,
        // so later pointer movement cannot retarget it; it is shared only after session consent.
        let target = target ?? (sharingPreference != .off && displayFallbackAllowed
            ? environment.displayTarget(environment.pointer()) : nil)
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
        if task?.phase == .paused {
            // A side question clears only the composer hold; an explicit pause stays latched (the turn is then text-only).
            if sideQuestion { _ = task?.clearTemporaryInterruption(.composer) } else { task?.resume() }
        }
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

    func pause(message: String = "Sharing paused", reason: GuideInterruption = .explicitPause) {
        let started = environment.uptime()
        defer { metrics.sample(.cancellation, seconds: environment.uptime() - started) }
        if demo != nil { demo?.pause(); status = "Demo paused · no AI"; publish(); return }
        endSelection(); pendingSelection = nil
        let active = isBusy
        transaction &+= 1; work?.cancel(); work = nil; isBusy = false
        task?.pause(reason); stopObservation(); onClearTarget?()
        if active { closeAgent() }
        lastImage = nil; lastContext = nil; status = message; publish()
    }
    func resume() {
        if demo != nil { demo?.resume(); status = "Demo · no AI · manual checklist"; publish(); return }
        guard displayGranted else {
            error = "Display sharing is not approved. Ask again to approve it, or choose a window."; publish(); return
        }
        guard !isBusy, let currentTarget, environment.focused(currentTarget) else {
            error = "Activate the approved target window, then Resume; or choose Change target."; publish(); return
        }
        activationWatch?.remove(); activationWatch = nil
        task?.resume(); retry()
    }
    func retry() {
        guard !isBusy, task != nil else { return }
        if task?.phase == .paused { task?.resume() }
        task?.beginRequest(); sideQuestion = false
        launch(message: recoveryMessage() + "\nLocate the current step again against fresh context.", captureFirst: true)
    }
    /// A matched interaction is an attempt, acknowledged locally before any provider latency; it is never success.
    func attemptObserved() {
        guard task?.historyIndex == nil, let phase = task?.phase, phase == .waiting || phase == .uncertain else { return }
        if phase == .waiting { guard let context = lastContext, task?.isCurrent(context) == true else { return } }
        guard task?.recordAttempt() == true else { return }
        targetGuard?.cancel(); targetGuard = nil
        attemptAt = environment.now(); metrics.count(.attempts)
        status = "Got it · checking"; publish()
        if let eventTime = observer.lastAttemptTimestamp {
            metrics.sample(.acknowledgement, seconds: environment.uptime() - eventTime)
        }
    }
    /// Settled attempt or relevant AX change. Without an attempt only a local AX predicate may check,
    /// so focus changes and notification noise never trigger captures or provider calls.
    func evidenceObserved() {
        guard let task, let step = task.step, let target = currentTarget else { return }
        if !task.actionDetected {
            guard axOutcomeWasSatisfied != true, let outcome = step.outcome,
                  environment.outcomeMatches(outcome, target) == true else { return }
        }
        checkNow(automatic: true)
    }
    /// Starts a verification episode. Automatic episodes are budgeted per step; an explicit Re-check is not.
    func checkNow(automatic: Bool = false) {
        guard !isBusy, !composerOpen, task?.historyIndex == nil, task?.beginVerification(automatic: automatic) == true else {
            if automatic, task?.phase == .uncertain { status = "I couldn't confirm that · Re-check"; publish() }
            return
        }
        sideQuestion = false; stopObservation(); onClearTarget?()
        launch(message: "Verify only the current intended outcome.", verifying: true)
    }
    func nextManually() {
        if demo != nil { demo?.next(); status = demo?.completed == true ? "Demo finished manually · no verification" : "Demo · no AI · manual checklist"; publish(); return }
        guard !isBusy, task?.step != nil, task?.historyIndex == nil else { return }
        stopObservation(); onClearTarget?()
        if task?.phase == .paused { task?.resume() }
        task?.manualNext(); task?.beginRequest(); sideQuestion = false; metrics.count(.manualAcknowledgements)
        launch(message: recoveryMessage() + "\nUser manually acknowledged the last step; it is NOT verified. Locate the next step.", captureFirst: true)
    }
    /// Shows the previous instruction from history. No provider request, desktop action or old coordinates:
    /// observation is frozen while browsing so nothing can complete, and returning revalidates the active step.
    func back() {
        guard demo == nil, !isBusy, task?.browseBack() == true else { return }
        stopObservation(); onClearTarget?()
        status = "Earlier step · past guidance, nothing to do"; publish()
    }
    func forward() {
        guard demo == nil, !isBusy, task?.historyIndex != nil else { return }
        if task?.browseForward() == true { returnToCurrent() } else { publish() }
    }
    func returnToCurrent() {
        guard !isBusy, task != nil else { return }
        task?.returnToCurrent()
        guard let phase = task?.phase, phase != .paused, phase != .completed, phase != .canceled else { publish(); return }
        if task?.step != nil { revalidateStep() } else { retry() }
    }
    func finishManually() {
        if demo != nil { while demo?.completed == false { demo?.resume(); demo?.next() }; status = "Demo finished manually · no verification"; publish(); return }
        transaction &+= 1; work?.cancel(); work = nil
        metrics.count(.manualAcknowledgements)
        task?.finishManually(); closeAgent(); stopObservation(); onClearTarget?(); walkthroughPresented = false
        lastImage = nil; lastContext = nil; isBusy = false; status = "Finished manually · not verified"; publish()
        onResponse?(status)
    }
    func endTask() {
        let started = environment.uptime()
        defer { metrics.sample(.cancellation, seconds: environment.uptime() - started) }
        #if DEBUG
        if task != nil { Logger(subsystem: "clicky", category: "guide").info("task metrics \(self.metrics.summary, privacy: .public)") }
        #endif
        demo = nil
        endSelection(); pendingSelection = nil
        walkthroughPresented = false
        awaitingClarification = false
        transaction &+= 1; work?.cancel(); work = nil
        task?.cancel(); closeAgent(); stopObservation(); onClearTarget?()
        activationWatch?.remove(); activationWatch = nil; stepSnapshot = nil
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
    func keepTask() { proposal = nil; task?.pause(); status = "Current task preserved · Resume when ready"; publish() }
    func acceptProposal() {
        guard let goal = proposal?.proposedGoal else { return }
        let target = currentTarget; endTask()
        do { try ask(goal, target: target) } catch { self.error = error.localizedDescription; publish() }
    }
    /// Genuine movement or replacement: drop stale coordinates and re-ground the same semantic step against
    /// fresh evidence, within the step's relocation budget. Never assumes the old control is still there.
    func relocateTarget(reason: String) {
        observer.cancelPendingMousePress()
        guard !isBusy, !composerOpen, task?.phase == .waiting, task?.spendRelocation() == true else {
            if task?.phase == .waiting { invalidateTarget(reason: reason) }
            return
        }
        #if DEBUG
        Logger(subsystem: "clicky", category: "guide").info("relocating target reason=\(reason, privacy: .public)")
        #endif
        metrics.count(.relocations)
        stopObservation(); onClearTarget?(); lastImage = nil; lastContext = nil
        task?.changed(); task?.beginRequest(); sideQuestion = false
        launch(message: recoveryMessage() + "\nThe target moved or changed. Locate the same current step again in this fresh capture.",
               captureFirst: true)
        status = "Finding the control"; publish()
    }
    func invalidateTarget(reason: String = "observed_change") {
        observer.cancelPendingMousePress(); observer.stop()
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
