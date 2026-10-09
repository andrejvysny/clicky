import AppKit
import ImageIO
import OSLog

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
                if walkthroughActive { task?.pause() } else { task = nil; currentTarget = nil }
                lastImage = nil; lastContext = nil; status = "Needs attention · Retry explicitly"
                // Host-side rejections leave the conversation intact; process or protocol-transport failures do not.
                if !(error is AttachmentError), !(error is GuideHostRejection) { closeAgent() }
            }
            guard current == transaction else { return }
            isBusy = false; work = nil; publish()
        }
    }

    private func getAgent(effort: AskEffort) throws -> GuideAgentSession {
        if let agent { return agent }
        guard let executable, task != nil else { throw AskError.missingExecutable(provider.displayName) }
        let profile = try GuideAgentProfile(provider: provider, root: profileRoot, taskID: UUID(), effort: effort)
        agentGeneration &+= 1; let generation = agentGeneration
        let value = GuideAgentSession(profile: profile, executable: executable, onUnexpectedExit: { [weak self] message in
            guard let controller = self else { return }
            Task { @MainActor in
                guard controller.agentGeneration == generation else { return }
                controller.pause(message: "Agent session ended · Retry starts a fresh session")
                controller.error = message; controller.closeAgent(); controller.publish()
            }
        })
        agent = value; agentEffort = effort; return value
    }

    private func request(_ original: GuideAgentTurn, current: UInt64) async throws -> GuidePresentation {
        try check(current)
        var turn = original; turn.effort = activeEffort
        let value = try getAgent(effort: activeEffort)
        if turn.image != nil { lastSent = Date() }
        let result = try await value.turn(turn)
        try check(current)
        guard turn.purpose.permits(result.kind) else { throw AskError.protocolFailure("The agent returned an inappropriate presentation for this request.") }
        if let id = await value.identifier() {
            session = AgentSession(provider: provider, identifier: id, workingDirectory: "Clicky-owned ephemeral task")
        }
        return result
    }

    private func presentationLoop(_ initial: GuideAgentTurn, current: UInt64) async throws {
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
            if staleMark || staleStep, !markRelocated, screenAvailable {
                markRelocated = true
                if task?.grant == nil, let currentTarget { task?.authorize(currentTarget) }
                turn = try await captureTurn(message: "Your reply referenced an older capture or fell outside it. "
                                             + "Locate the target again in this capture and use its captureID.", current: current)
                continue
            }
            try await present(result, current: current)
            return
        }
    }

    static let sharingOffHint = "Screen sharing is off — turn it on in Settings › Screen."

    private var screenAvailable: Bool { sharingPreference != .off && currentTarget != nil }

    /// Fresh context for the agent, or nil when sharing does not allow any. Never prompts: consent was given at setup.
    private func contextTurn(for result: GuidePresentation, current: UInt64) async throws -> GuideAgentTurn? {
        guard screenAvailable, let currentTarget else { return nil }
        if task?.grant == nil { task?.authorize(currentTarget) }
        // A crop is only meaningful against the window capture it names.
        let crop = result.crop != nil && result.captureID == lastContext?.captureID ? result.crop : nil
        return try await captureTurn(message: "Requested approved context. " + recoveryMessage(), crop: crop, current: current)
    }

    private func captureTurn(message: String, crop: GuideRect? = nil, current: UInt64) async throws -> GuideAgentTurn {
        try check(current)
        guard let target = currentTarget, let task, task.grant?.paused == false else { throw AttachmentError.noTarget }
        guard await ScopedAccessibility.waitForFocus(target) else { throw AttachmentError.targetChanged }
        try check(current)
        if task.phase != .verifying { try self.task?.requestContext() }
        var region: CGRect?
        if let crop {
            guard let context = lastContext, self.task?.isCurrent(context) == true,
                  let rect = context.screenRect(crop) else { throw AttachmentError.targetChanged }
            region = rect
        }
        let related = ScopedAccessibility.related(target)
        let windows = [target] + related
        let bounds = windows.reduce(into: [UInt32: CGRect]()) { result, window in
            result[window.windowIdentifier] = ScopedAccessibility.bounds(window)
        }
        guard bounds.count == windows.count else { throw AttachmentError.targetChanged }
        for child in related { self.task?.authorizeRelated(child) }
        guard let lease = try self.task?.beginCapture() else { throw AttachmentError.noTarget }
        status = "Inspecting approved window"; publish()
        let image = try await WindowSnapshotCapture.capture(target, region: region, relatedTargets: related)
        try check(current)
        guard let state = self.task else { throw AttachmentError.targetChanged }
        guard ScopedAccessibility.focused(target), windows.allSatisfy({
            ScopedAccessibility.bounds($0) == bounds[$0.windowIdentifier]
        }) else { throw AttachmentError.targetChanged }
        let context = try GuideCaptureContext(image: image, target: target, task: state, relatedTargets: related)
        guard self.task?.accept(context, lease: lease) == true else { throw AttachmentError.targetChanged }
        lastImage = image; lastContext = context; capturedWindowBounds = bounds
        let purpose: GuideRequestPurpose = state.phase == .verifying ? .verification : (sideQuestion ? .sideQuestion : .continuation)
        return GuideAgentTurn(message: message, image: image, context: context, purpose: purpose,
                              taskContext: GuideHostTaskContext(state))
    }

    private func present(_ result: GuidePresentation, current: UInt64) async throws {
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
                  let rect = context.screenRect(pixelTarget), windowsStillCurrent(context), ScopedAccessibility.focused(target) else { throw AttachmentError.targetChanged }
            let currentImage = try await WindowSnapshotCapture.capture(target, region: context.region.rect,
                                                                       relatedTargets: ScopedAccessibility.related(target))
            try check(current)
            guard windowsStillCurrent(context), let previous = fingerprint(image, rect: pixelTarget.rect),
                  let fresh = fingerprint(currentImage, rect: pixelTarget.rect), previous == fresh,
                  image.pixelWidth == currentImage.pixelWidth, image.pixelHeight == currentImage.pixelHeight else {
                throw AskError.protocolFailure("The target changed while the agent was locating it. Retry with fresh context.")
            }
            try task?.show(result); status = "Waiting for you"
            walkthroughPresented = true
            axOutcomeWasSatisfied = result.outcome.flatMap { ScopedAccessibility.matches($0, target: target) }
            onTarget?(GuideMark(mark: result.mark ?? .circle, target: rect, label: nil,
                                value: result.mark == .value ? result.value : nil,
                                ghost: result.ghost.flatMap(context.screenRect), within: context.region.rect))
            if !composerOpen {
                observer.start(step: result, target: target, rect: rect)
                startTargetGuard(image: image, context: context, pixelTarget: pixelTarget)
            }
            #endif
        case .annotation:
            // Points only: no observation, verification or milestone; a click or 45 s clears it.
            guard let rect = annotationRect(result) else {
                throw GuideHostRejection(message: "Couldn't place that mark — the screen changed. Ask again.")
            }
            onResponse?(result.text)
            onAnnotate?(GuideMark(mark: result.mark ?? .circle, target: rect, label: result.markLabel,
                                  value: result.mark == .value ? result.value : nil, ghost: nil, within: annotationBounds(result)))
            status = "Ready"
            if sideQuestion { task?.pause(); status = "Pointed · walkthrough preserved" }
            else { task = nil; currentTarget = nil; lastImage = nil; lastContext = nil }
        case .explanation, .clarification:
            onResponse?(sharingHint.map { result.text + "\n\n" + $0 } ?? result.text); sharingHint = nil; status = "Ready"
            awaitingClarification = result.kind == .clarification && !sideQuestion
            if sideQuestion || (result.kind == .explanation && walkthroughPresented) {
                task?.pause(); status = "Answer ready · walkthrough preserved"
            } else if result.kind == .explanation {
                // Keep the agent: follow-up questions continue the same conversation. A new task starts on the next ask.
                task = nil; currentTarget = nil; lastImage = nil; lastContext = nil
            }
        case .task_proposal:
            proposal = result; task?.pause(); status = "Start a new task or keep this walkthrough?"
        case .task_completed:
            guard try await evidenceStillCurrent(current: current) else { throw AttachmentError.targetChanged }
            guard task?.finish(matches: result.matches == true, captureID: result.captureID) == true else {
                throw AskError.protocolFailure("Task completion lacks fresh verified evidence.")
            }
            onClearTarget?(); status = "Task complete · verified"; closeAgent(); lastImage = nil; lastContext = nil
            walkthroughPresented = false
        default: throw AskError.protocolFailure("The agent returned a presentation inappropriate for this task phase.")
        }
    }

    private func verificationLoop(current: UInt64) async throws {
        guard let step = task?.step, let outcome = step.outcome, let target = currentTarget else { throw AttachmentError.noTarget }
        for _ in 0..<2 {
            let turn = try await captureTurn(message: "Verify this intended outcome only: " + outcome.description, current: current)
            guard let context = turn.context else { throw AttachmentError.targetChanged }
            let matches: Bool
            if let local = ScopedAccessibility.matches(outcome, target: target), axOutcomeWasSatisfied != true { matches = local }
            else {
                let result = try await request(turn, current: current)
                guard result.kind == .verification_result, result.captureID == context.captureID,
                      let verdict = result.matches else { throw AskError.protocolFailure("Verification lacks current outcome evidence.") }
                let fresh = try await evidenceStillCurrent(current: current)
                matches = verdict && fresh
            }
            if task?.checked(matches: matches, context: context) == true {
                task?.beginRequest()
                let next = try await captureTurn(message: recoveryMessage() + "\nHost verified the outcome. Locate the next useful step or verify task completion.", current: current)
                try await presentationLoop(next, current: current); return
            }
        }
        status = "I could not confirm that · Retry or manual Next"
    }

    /// Maps an annotation against the latest capture of the shared window or display.
    func annotationRect(_ result: GuidePresentation) -> CGRect? {
        guard let pixelTarget = result.target, let context = lastContext,
              result.captureID == nil || result.captureID == context.captureID, windowsStillCurrent(context) else { return nil }
        return context.screenRect(pixelTarget)
    }

    private func annotationBounds(_ result: GuidePresentation) -> CGRect? { lastContext?.region.rect }

    func fingerprint(_ image: PNGImageAttachment, rect: CGRect) -> Data? {
        guard let source = CGImageSourceCreateWithData(image.data as CFData, nil), let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let crop = decoded.cropping(to: rect.integral) else { return nil }
        var bytes = Data(count: crop.width * crop.height * 4)
        let rendered = bytes.withUnsafeMutableBytes { storage -> Bool in
            guard let renderer = CGContext(data: storage.baseAddress, width: crop.width, height: crop.height,
                                           bitsPerComponent: 8, bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            renderer.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height)); return true
        }
        return rendered ? bytes : nil
    }
    private func check(_ current: UInt64) throws {
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
struct GuideHostRejection: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
