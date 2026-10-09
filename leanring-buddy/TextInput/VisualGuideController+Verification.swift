import AppKit
import OSLog
#if canImport(ClickyCore)
import ClickyCore
#endif

/// Outcome verification: fresh Accessibility first, bounded local waiting for a busy application, then at most
/// an initial vision check plus one fresh recheck per episode. Timeouts and matching input never mean success.
extension VisualGuideController {
    /// Local wait for an application that is still working; polls scoped AX or simply settles, never the model.
    static let appWaitSeconds = 3.0
    static let appPollSeconds = 0.25
    /// Pause before the single fresh recheck after a contradicted or unknown verdict.
    static let recheckSettleSeconds = 1.0

    func verificationLoop(current: UInt64) async throws {
        guard let step = task?.step, let outcome = step.outcome, let target = currentTarget else { throw AttachmentError.noTarget }
        let started = environment.uptime()
        let axNow = environment.outcomeMatches(outcome, target)
        trace("verify ax=" + (axNow.map { $0 ? "true" : "false" } ?? "undecidable") + " axBefore="
              + (axOutcomeWasSatisfied.map { $0 ? "true" : "false" } ?? "undecidable"))
        // A predicate already true before the step cannot prove this step; vision decides instead.
        if axOutcomeWasSatisfied != true, axNow != nil,
           try await waitForLocalOutcome(outcome, target: target, current: current) {
            guard task?.confirmLocally() == true else { throw AttachmentError.targetChanged }
            metrics.count(.localConfirmations); recordVerified(since: started)
            try await presentNext(note: "Host verified the outcome with fresh Accessibility state.", current: current)
            return
        }
        var last: (state: GuidePresentation.OutcomeState, evidence: String) = (.unknown, "")
        for check in 0..<2 {
            if check > 0 { try await settle(after: last.state, current: current) }
            status = "Checking"; publish()
            let turn = try await captureTurn(message: GuideHostMessages.verification(instruction: step.text, outcome: outcome.description),
                                             current: current)
            guard let context = turn.context else { throw AttachmentError.targetChanged }
            metrics.count(.visionChecks)
            let result = try await request(turn, current: current)
            guard result.kind == .verification_result, result.captureID == context.captureID,
                  let verdict = result.matches else { throw AskError.protocolFailure("Verification lacks current outcome evidence.") }
            let state = result.outcomeState ?? .unknown
            var confirmed = verdict && state == .confirmed
            if confirmed { confirmed = try await evidenceStillCurrent(current: current, evidenceTarget: result.evidenceTarget) }
            trace("verdict check=\(check) state=\(state.rawValue) accepted=\(confirmed)")
            last = (state, result.evidence ?? "")
            if task?.checked(matches: confirmed, context: context) == true {
                recordVerified(since: started)
                try await presentNext(note: "Host verified the outcome.", current: current)
                return
            }
        }
        // A contradicted or undecidable result after a genuine attempt may be a detour, the user working ahead or
        // an outcome worded differently from what the app shows: look once at the current state and continue from
        // there, never assuming success. A pending app has already had its bounded wait.
        if last.state == .contradicted || last.state == .unknown, task?.beginRecovery() == true {
            metrics.count(.recoveries); recoveringMilestone = step.milestone ?? step.text
            trace("recovery after=" + last.state.rawValue)
            status = "Finding the next step"; publish()
            let turn = try await captureTurn(message: task.map { GuideHostMessages.recovery($0, evidence: last.evidence) } ?? "",
                                             current: current)
            recoveringAction = step.action?.kind
            try await presentationLoop(turn, current: current)
            return
        }
        enterUncertain()
    }

    /// The provider proposed completion. Verify every stored goal check on fresh evidence before accepting it.
    func verifyGoal(proposal: GuidePresentation, current: UInt64) async throws {
        guard task?.beginGoalVerification() == true else { throw AskError.protocolFailure("Task completion arrived in the wrong phase.") }
        metrics.count(.goalChecks)
        status = "Checking the whole goal"; publish()
        let checks = task?.plan.goalChecks.isEmpty == false ? task?.plan.goalChecks ?? [] : [task?.goal ?? ""]
        let turn = try await captureTurn(message: GuideHostMessages.goalCheck(checks), current: current)
        guard let context = turn.context else { throw AttachmentError.targetChanged }
        let result = try await request(turn, current: current)
        guard result.kind == .verification_result, result.captureID == context.captureID,
              let verdict = result.matches else { throw AskError.protocolFailure("Final verification lacks current evidence.") }
        var confirmed = verdict && result.outcomeState == .confirmed
        if confirmed { confirmed = try await evidenceStillCurrent(current: current, evidenceTarget: result.evidenceTarget) }
        if confirmed, task?.finish(matches: true, captureID: context.captureID) == true {
            stopObservation(); onClearTarget?(); status = "Task complete · verified"; closeAgent(); lastImage = nil; lastContext = nil
            logTaskMetrics()
            onResponse?(status + "\n\n" + proposal.text)
            walkthroughPresented = false
            return
        }
        guard task?.goalVerificationFailed() == true else { enterUncertain(goal: true); return }
        status = "Finding the next step"; publish()
        let next = try await captureTurn(message: recoveryMessage() + "\nFinal verification did not confirm the goal: "
                                         + (result.evidence ?? "") + "\nPresent the step that satisfies the remaining goal checks.",
                                         current: current)
        try await presentationLoop(next, current: current)
    }

    /// Polls fresh scoped AX until the outcome holds or the bounded deadline passes. Returns false when AX
    /// cannot decide, so vision verification follows; nothing is captured or sent while waiting.
    private func waitForLocalOutcome(_ outcome: GuideOutcome, target: WindowCaptureTarget, current: UInt64) async throws -> Bool {
        let deadline = environment.uptime() + Self.appWaitSeconds
        var waited = false
        while true {
            try check(current)
            switch environment.outcomeMatches(outcome, target) {
            case true?: return true
            case nil: return false
            case false?:
                guard environment.uptime() < deadline else { return false }
                if !waited { waited = true; metrics.count(.appWaits); status = "Waiting for the app"; publish() }
                try await environment.sleep(UInt64(Self.appPollSeconds * 1_000_000_000))
            }
        }
    }

    /// Before the single recheck: a pending app gets the bounded app wait, anything else a short settle.
    private func settle(after state: GuidePresentation.OutcomeState, current: UInt64) async throws {
        let seconds = state == .pending ? Self.appWaitSeconds : Self.recheckSettleSeconds
        if state == .pending { metrics.count(.appWaits); status = "Waiting for the app"; publish() }
        try await environment.sleep(UInt64(seconds * 1_000_000_000))
        try check(current)
    }

    func presentNext(note: String, current: UInt64) async throws {
        lastAdvanceAt = environment.uptime()
        task?.beginRequest()
        status = "Finding the next step"; publish()
        let next = try await captureTurn(message: task.map { GuideHostMessages.next($0, note: note) } ?? note, current: current)
        try await presentationLoop(next, current: current)
    }

    private func recordVerified(since started: TimeInterval) {
        metrics.sample(.verification, seconds: environment.uptime() - started)
    }

    /// Uncertainty keeps a safe watch: the same target stays marked and observed, so a new genuine attempt
    /// re-arms a bounded check without Retry. A moved window or missing rectangle leaves Re-check to the user.
    func enterUncertain(goal: Bool = false) {
        metrics.count(.uncertainties)
        status = goal ? "Couldn't confirm the whole goal · Re-check or finish manually" : "I couldn't confirm that · Re-check"
        guard !goal, let step = task?.step, let rect = stepScreenRect, let target = currentTarget,
              environment.bounds(target) == stepWindowBounds else { publish(); return }
        onTarget?(GuideMark(mark: step.mark ?? .circle, target: rect, label: Self.stepLabel(step), value: step.mark == .value ? step.value : nil,
                            ghost: nil, within: stepWindowBounds, warning: step.warning != nil))
        if !composerOpen {
            observer.start(step: step, target: target, rect: rect, scope: stepSnapshot?.context.region.rect)
            // The kept mark stays guarded against the latest current capture, so a replaced control clears it.
            if let image = lastImage, let context = lastContext, task?.isCurrent(context) == true, let pixelTarget = step.target,
               let snapshot = stepSnapshot, image.pixelWidth == snapshot.image.pixelWidth, image.pixelHeight == snapshot.image.pixelHeight {
                startTargetGuard(image: image, context: context, pixelTarget: pixelTarget)
            }
        }
        publish()
    }

    /// One short action beside the target ("Click Export"), or its consequence for a destructive step.
    /// If the overlay finds no safe place it omits the plate; the island always shows the full instruction.
    static func stepLabel(_ step: GuidePresentation) -> String {
        if let warning = step.warning { return "⚠︎ " + warning }
        return step.markLabel
    }

    func waitingStatus(_ step: GuidePresentation) -> String {
        switch step.action?.kind {
        case .double_click: return "Waiting for your double-click"
        case .right_click: return "Waiting for your right-click"
        case .key, .field_commit: return "Waiting for your key"
        default: return "Waiting for your click"
        }
    }
}
