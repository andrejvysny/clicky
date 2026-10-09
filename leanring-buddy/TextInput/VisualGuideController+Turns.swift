import AppKit
import ImageIO
import OSLog
#if canImport(ClickyCore)
import ClickyCore
#endif

extension VisualGuideController {
    func launch(message: String, captureFirst: Bool = false, verifying: Bool = false,
                crop: GuideRect? = nil) {
        transaction &+= 1; let current = transaction
        activeEffort = pendingEffort; pendingEffort = .low
        isBusy = true; error = nil; status = verifying ? "Checking result" : "Inspecting request"
        stopObservation(); publish()
        work = Task { [weak self] in
            guard let self else { return }
            do {
                if provider == .preview { preview(message); return }
                if verifying { try await verificationLoop(current: current) }
                else {
                    var turn = GuideAgentTurn(message: message, purpose: sideQuestion ? .sideQuestion : .planning,
                                              taskContext: task.map(GuideHostTaskContext.init))
                    if captureFirst { turn = try await captureTurn(message: message, crop: crop, current: current) }
                    try await presentationLoop(turn, current: current)
                }
            } catch {
                guard current == transaction else { return }
                #if DEBUG
                // Host-generated error text and phase only; never prompts, replies or images.
                Logger(subsystem: "clicky", category: "guide").error(
                    "turn failed in phase \(String(describing: self.task?.phase), privacy: .public): \(String(describing: error), privacy: .public)")
                #endif
                self.error = error.localizedDescription; onClearTarget?()
                // Only a visible walkthrough is kept for Retry; anything else starts fresh on the next question.
                lastAdvanceAt = nil
                if walkthroughActive { task?.pause() } else { task = nil; currentTarget = nil }
                lastImage = nil; lastContext = nil; status = "Needs attention · Retry explicitly"
                // Host-side rejections leave the conversation intact; process or protocol-transport failures do not.
                if !(error is AttachmentError), !(error is GuideHostRejection), !(error is GuideTargetChangedWhileLocating) { closeAgent() }
            }
            guard current == transaction else { return }
            isBusy = false; work = nil; publish()
        }
    }

    private func getAgent(effort: AskEffort) throws -> any GuideAgentRunning {
        if let agent { return agent }
        guard let executable, task != nil else { throw AskError.missingExecutable(provider.displayName) }
        agentGeneration &+= 1; let generation = agentGeneration
        let value = try environment.makeAgent(provider, executable, profileRoot, effort, { [weak self] message in
            guard let controller = self else { return }
            Task { @MainActor in
                guard controller.agentGeneration == generation else { return }
                controller.pause(message: "Agent session ended · Retry starts a fresh session")
                controller.error = message; controller.closeAgent(); controller.publish()
            }
        })
        agent = value; agentEffort = effort; return value
    }

    func request(_ original: GuideAgentTurn, current: UInt64) async throws -> GuidePresentation {
        try check(current)
        var turn = original; turn.effort = activeEffort
        let value = try getAgent(effort: activeEffort)
        if turn.image != nil { lastSent = environment.now() }
        metrics.count(.providerTurns)
        let (result, corrected) = try await value.turnAllowingOneCorrection(turn)
        try check(current)
        if corrected { metrics.count(.providerTurns); trace("wrong_purpose corrected purpose=" + turn.purpose.rawValue) }
        #if DEBUG
        // Kinds and states only (never text, targets or images), persisted so a native run can be reconstructed.
        Logger(subsystem: "clicky", category: "guide").notice(
            "turn purpose=\(turn.purpose.rawValue, privacy: .public) kind=\(result.kind.rawValue, privacy: .public) phase=\(String(describing: self.task?.phase), privacy: .public) outcome=\(result.outcomeState?.rawValue ?? "-", privacy: .public) image=\(turn.image != nil, privacy: .public)")
        #endif
        guard turn.purpose.permits(result.kind) else {
            throw AskError.protocolFailure("The agent returned \(result.kind.rawValue) for \(turn.purpose.rawValue). Retry explicitly.")
        }
        if let id = await value.identifier() {
            session = AgentSession(provider: provider, identifier: id, workingDirectory: "Clicky-owned ephemeral task")
        }
        return result
    }

    func presentationLoop(_ initial: GuideAgentTurn, current: UInt64) async throws {
        var turn = initial
        var markRelocated = false
        var textOnlyNudged = false
        while true {
            let result = try await request(turn, current: current)
            if result.kind == .context_request {
                guard let next = try await contextTurn(for: result, current: current) else {
                    // No screen allowed: one text-only nudge, then stop rather than loop.
                    guard !textOnlyNudged else { throw AskError.protocolFailure("This question needs the screen. " + Self.sharingOffHint) }
                    textOnlyNudged = true; sharingHint = Self.sharingOffHint
                    turn = GuideAgentTurn(message: "Screen sharing is off. Answer from text alone; do not request context again.",
                                          purpose: turn.purpose, taskContext: task.map(GuideHostTaskContext.init))
                    continue
                }
                turn = next
                continue
            }
            // A mark or step against an older capture gets one fresh look instead of failing the question.
            let staleMark = result.kind == .annotation && annotationRect(result) == nil
            let staleStep = result.kind == .guide_step && (lastContext == nil || result.captureID != lastContext?.captureID)
            if staleMark || staleStep, !markRelocated, screenAvailable, displayGranted {
                markRelocated = true
                if task?.grant == nil, let currentTarget { task?.authorize(currentTarget) }
                turn = try await captureTurn(message: "Your reply referenced an older capture or fell outside it. "
                                             + "Locate the target again in this capture and use its captureID.", current: current)
                continue
            }
            do {
                try await present(result, current: current)
            } catch is GuideTargetChangedWhileLocating {
                // Loading, animation or hover changed the target after the capture: look again within the step's
                // relocation budget rather than stopping for Resume; old coordinates are never shown.
                guard task?.spendRelocation() == true, screenAvailable, displayGranted else {
                    throw GuideHostRejection(message: "The target kept changing while it was being located · Retry when it settles.")
                }
                // A host-forced look is a new locate request, bounded by the relocation budget, not provider context.
                metrics.count(.relocations); task?.beginRequest(); trace("relocate reason=locate_pixels")
                status = "Finding the control"; publish()
                turn = try await captureTurn(message: "The view changed while you were locating the step (loading, animation or "
                                             + "hover). Locate the same step again in this capture and use its captureID.",
                                             current: current)
                continue
            }
            return
        }
    }

    static let sharingOffHint = "Screen sharing is off — turn it on in Settings › Screen."

    /// An explicitly paused or revoked task grant shares nothing; a temporary hold keeps it usable.
    private var screenAvailable: Bool { sharingPreference != .off && currentTarget != nil && task?.grant?.paused != true }

    /// Fresh context for the agent, or nil when sharing does not allow any. A bound task window needs no prompt;
    /// a display asks once per Clicky session, before any capture, and Text only answers without the screen.
    private func contextTurn(for result: GuidePresentation, current: UInt64) async throws -> GuideAgentTurn? {
        guard screenAvailable, let currentTarget, displayConsentForRequest(currentTarget) else { return nil }
        if task?.grant == nil { task?.authorize(currentTarget) }
        // A crop is only meaningful against the window capture it names.
        let crop = result.crop != nil && result.captureID == lastContext?.captureID ? result.crop : nil
        return try await captureTurn(message: task.map(GuideHostMessages.requestedContext) ?? "", crop: crop, current: current)
    }

    /// Resolves display consent for the current request without capturing anything.
    func displayConsentForRequest(_ target: WindowCaptureTarget) -> Bool {
        guard let display = target.displayIdentifier else { return true }
        switch displayConsent.decision(display: display, provider: provider, request: requestGeneration,
                                       preferenceAllows: displayFallbackAllowed) {
        case .granted: return true
        case .declined, .disallowed: return false
        case .needsPrompt:
            guard environment.requestDisplayConsent(target, provider) else {
                displayConsent.decline(request: requestGeneration); return false
            }
            displayConsent.approve(display: display, provider: provider); return true
        }
    }

    func captureTurn(message: String, crop: GuideRect? = nil, current: UInt64) async throws -> GuideAgentTurn {
        try check(current)
        guard let target = currentTarget, let task, task.grant?.paused == false else { throw AttachmentError.noTarget }
        guard displayGranted else { throw AttachmentError.noTarget }
        guard await environment.waitForFocus(target) else { throw AttachmentError.targetChanged }
        try check(current)
        if task.phase != .verifying { try self.task?.requestContext() }
        var region: CGRect?
        if let crop {
            guard let context = lastContext, self.task?.isCurrent(context) == true,
                  let rect = context.screenRect(crop) else { throw AttachmentError.targetChanged }
            region = rect
        }
        let related = environment.related(target)
        let windows = [target] + related
        let bounds = windows.reduce(into: [UInt32: CGRect]()) { result, window in
            result[window.windowIdentifier] = environment.bounds(window)
        }
        guard bounds.count == windows.count else { throw AttachmentError.targetChanged }
        for child in related { self.task?.authorizeRelated(child) }
        guard let lease = try self.task?.beginCapture() else { throw AttachmentError.noTarget }
        metrics.count(.captures)
        let image = try await environment.capture(target, region, related, nil)
        try check(current)
        guard let state = self.task else { throw AttachmentError.targetChanged }
        guard environment.focused(target), windows.allSatisfy({
            environment.bounds($0) == bounds[$0.windowIdentifier]
        }) else { throw AttachmentError.targetChanged }
        let context = try GuideCaptureContext(image: image, target: target, task: state, relatedTargets: related)
        guard self.task?.accept(context, lease: lease) == true else { throw AttachmentError.targetChanged }
        lastImage = image; lastContext = context; capturedWindowBounds = bounds
        let purpose: GuideRequestPurpose = state.phase == .verifying ? .verification : (sideQuestion ? .sideQuestion : .continuation)
        let hinted = selectionHint(for: context).map { message + "\n" + $0 } ?? message
        return GuideAgentTurn(message: hinted, image: image, context: context, purpose: purpose,
                              taskContext: GuideHostTaskContext(state))
    }

    func present(_ result: GuidePresentation, current: UInt64) async throws {
        if sideQuestion, ![.explanation, .clarification, .task_proposal, .annotation].contains(result.kind) {
            throw GuideHostRejection(message: "A side question cannot advance the active walkthrough.")
        }
        switch result.kind {
        case .guide_step:
            #if !DEBUG
            throw AskError.protocolFailure("Visual guides are available in development builds until native acceptance passes.")
            #else
            guard sharingPreference != .off else { throw AskError.protocolFailure("Enable task-window sharing to start a walkthrough. Your explicit image can still support explanations.") }
            guard let image = lastImage, let context = lastContext, let target = currentTarget,
                  result.captureID == context.captureID, let pixelTarget = result.target,
                  let rect = context.screenRect(pixelTarget), windowsStillCurrent(context), environment.focused(target) else { throw AttachmentError.targetChanged }
            let currentImage = try await matchingCapture(target, context: context)
            try check(current)
            guard windowsStillCurrent(context),
                  let pixels = GuidePixelMapping.comparisonRect(pixelTarget, pixelWidth: image.pixelWidth, pixelHeight: image.pixelHeight),
                  let previous = fingerprint(image, rect: pixels),
                  let fresh = fingerprint(currentImage, rect: pixels),
                  image.pixelWidth == currentImage.pixelWidth, image.pixelHeight == currentImage.pixelHeight else {
                throw GuideTargetChangedWhileLocating()
            }
            // Rendering noise is tolerated; hover feedback under the pointer is expected, as in the target guard.
            if !previous.looksLike(fresh) {
                guard pointerNear(rect) else { throw GuideTargetChangedWhileLocating() }
                trace("locate hover_tolerated")
            }
            let snapshot = GuideStepSnapshot(step: result, stepRevision: task?.stepRevision ?? 0, image: image, context: context,
                                             windowBounds: environment.bounds(target))
            stepSnapshot = snapshot
            // A step that arrives during a temporary interruption waits; it is revalidated before it is shown.
            if task?.phase == .paused { status = "Next step ready · continues when you return"; return }
            try task?.show(result); status = waitingStatus(result)
            // A recovery look that re-presents the step it started from must not invite the same gesture again
            // (a second click undoes a toggle): keep the mark but leave the step uncertain with Re-check primary.
            let repeatsStep = recoveringMilestone.map { (result.milestone ?? result.text) == $0 } ?? false
                && result.action?.kind == recoveringAction
            recoveringAction = nil
            if let previous = recoveringMilestone {
                trace("recovery sameMilestone=\((result.milestone ?? result.text) == previous)"); recoveringMilestone = nil
            }
            stepScreenRect = rect; stepWindowBounds = environment.bounds(target)
            if let completedAt = lastAdvanceAt { metrics.sample(.nextStep, seconds: environment.uptime() - completedAt); lastAdvanceAt = nil }
            if let startedAt = taskStartedAt { metrics.sample(.firstInstruction, seconds: environment.uptime() - startedAt); taskStartedAt = nil }
            walkthroughPresented = true
            axOutcomeWasSatisfied = result.outcome.flatMap { environment.outcomeMatches($0, target) }
            onTarget?(GuideMark(mark: result.mark ?? .circle, target: rect, label: Self.stepLabel(result),
                                value: result.mark == .value ? result.value : nil,
                                ghost: result.ghost.flatMap(context.screenRect), within: context.region.rect,
                                avoidRects: environment.annotationObstacles(target, context.region.rect), warning: result.warning != nil))
            if !composerOpen {
                observer.start(step: result, target: target, rect: rect, scope: context.region.rect)
                startTargetGuard(image: image, context: context, pixelTarget: pixelTarget)
            }
            if repeatsStep, task?.markUncertain() == true { metrics.count(.uncertainties); status = "I couldn't confirm that · Re-check" }
            #endif
        case .annotation:
            // Points only: no observation, verification or milestone; a click or 45 s clears it.
            guard let rect = annotationRect(result) else {
                throw GuideHostRejection(message: "Couldn't place that mark — the screen changed. Ask again.")
            }
            onResponse?(result.text)
            onAnnotate?(GuideMark(mark: result.mark ?? .circle, target: rect, label: result.markLabel,
                                  value: result.mark == .value ? result.value : nil, ghost: nil, within: annotationBounds(result),
                                  avoidRects: annotationObstacles()))
            status = "Ready"
            if sideQuestion { task?.pause(.sideAnswer); status = "Pointed · guide continues when you close the answer" }
            else { task = nil; currentTarget = nil; lastImage = nil; lastContext = nil }
        case .explanation, .clarification:
            onResponse?(sharingHint.map { result.text + "\n\n" + $0 } ?? result.text); sharingHint = nil; status = "Ready"
            awaitingClarification = result.kind == .clarification && !sideQuestion
            if awaitingClarification && walkthroughPresented { status = "Question for you · answer in Quick Ask" }
            if sideQuestion || (result.kind == .explanation && walkthroughPresented) {
                task?.pause(.sideAnswer); status = "Answer ready · guide continues when you close it"
            } else if result.kind == .explanation {
                // Keep the agent: follow-up questions continue the same conversation. A new task starts on the next ask.
                task = nil; currentTarget = nil; lastImage = nil; lastContext = nil
            }
        case .task_proposal:
            proposal = result; task?.pause(); status = "Start a new task or keep this walkthrough?"
        case .task_completed:
            // The proposal alone never completes the task: the stored goal checks are verified on a fresh capture
            // (with their own evidence freshness check), so a proposal over a since-changed screen is not an error.
            try await verifyGoal(proposal: result, current: current)
        default: throw AskError.protocolFailure("The agent returned a presentation inappropriate for this task phase.")
        }
    }

    /// Maps an annotation against the latest capture of the shared window or display.
    func annotationRect(_ result: GuidePresentation) -> CGRect? {
        guard let pixelTarget = result.target, let context = lastContext,
              result.captureID == nil || result.captureID == context.captureID, windowsStillCurrent(context) else { return nil }
        return context.screenRect(pixelTarget)
    }

    private func annotationBounds(_ result: GuidePresentation) -> CGRect? { lastContext?.region.rect }

    private func annotationObstacles() -> [CGRect] {
        guard let target = currentTarget, let region = lastContext?.region.rect else { return [] }
        return environment.annotationObstacles(target, region)
    }

    func fingerprint(_ image: PNGImageAttachment, rect: CGRect) -> GuidePixels? {
        guard let source = CGImageSourceCreateWithData(image.data as CFData, nil), let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let crop = decoded.cropping(to: rect.integral) else { return nil }
        var bytes = Data(count: crop.width * crop.height * 4)
        let rendered = bytes.withUnsafeMutableBytes { storage -> Bool in
            guard let renderer = CGContext(data: storage.baseAddress, width: crop.width, height: crop.height,
                                           bitsPerComponent: 8, bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            renderer.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height)); return true
        }
        return rendered ? GuidePixels(width: crop.width, height: crop.height, rgba: bytes) : nil
    }
    func check(_ current: UInt64) throws {
        try Task.checkCancellation()
        guard transaction == current else { throw CancellationError() }
    }
    private func preview(_ message: String) {
        onResponse?("Quick Ask received your text:\n\n" + lastUserText)
        status = "Preview complete · no AI request"; isBusy = false; work = nil
        if sideQuestion { task?.pause() }
        else { task?.finishManually() }
        publish()
    }
}

/// The host declined a well-formed reply (stale target, wrong phase); the agent conversation stays usable.
/// The located target's pixels differ between the capture the provider saw and a fresh one.
struct GuideTargetChangedWhileLocating: LocalizedError {
    var errorDescription: String? { "The target changed while the agent was locating it." }
}

struct GuideHostRejection: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
