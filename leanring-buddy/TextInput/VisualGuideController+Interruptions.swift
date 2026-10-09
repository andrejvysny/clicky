import AppKit
#if canImport(ClickyCore)
import ClickyCore
#endif

/// The presented step, kept in memory so a temporary interruption can be revalidated locally on return.
struct GuideStepSnapshot {
    let step: GuidePresentation
    let image: PNGImageAttachment
    let context: GuideCaptureContext
    let windowBounds: CGRect?
}

/// Temporary interruptions (Quick Ask, a side answer, a brief app switch) resume by themselves once every
/// temporary reason clears, the approved window is focused again and fresh local validation succeeds.
/// Explicit Pause, revocation, closure and failures never clear this way, so a late focus event cannot resume them.
extension VisualGuideController {
    func composerWillOpen() {
        composerOpen = true; stopObservation(); onClearTarget?()
        guard !isBusy, task?.step != nil, let phase = task?.phase, phase == .waiting || phase == .uncertain else { return }
        task?.pause(.composer); status = "Guide waits while you type"; publish()
    }

    func composerDidClose(submitted: Bool) {
        composerOpen = false
        guard let task else { return }
        // A step that arrived while the composer was open was shown but not observed yet.
        if task.phase == .waiting, !observer.isObserving, !isBusy { revalidateStep(); return }
        _ = self.task?.clearTemporaryInterruption(.composer)
        _ = self.task?.clearTemporaryInterruption(.sideAnswer)
        resumeAfterInterruption()
    }

    /// Another application became active while a step was waiting: stop observing and capturing,
    /// watch only for activation, and continue when the approved window is focused again.
    func interruptForAppSwitch() {
        pause(message: "Paused while you're in another app · continues when you return", reason: .appSwitch)
        activationWatch?.remove()
        activationWatch = environment.watchActivation { [weak self] in self?.activationChanged() }
    }

    func activationChanged() {
        guard task?.interruptions.contains(.appSwitch) == true, let target = currentTarget, environment.focused(target) else { return }
        _ = task?.clearTemporaryInterruption(.appSwitch)
        resumeAfterInterruption()
    }

    /// Resumes only when nothing but temporary reasons held the task; otherwise the user resumes deliberately.
    func resumeAfterInterruption() {
        guard let task, task.phase == .paused else { return }
        guard task.interruptions.isEmpty else {
            if task.interruptions.allSatisfy(\.isTemporary) { publish(); return }
            status = "Paused · Resume when ready"; publish(); return
        }
        guard !isBusy, !composerOpen, displayGranted else { return }
        activationWatch?.remove(); activationWatch = nil
        self.task?.resume()
        revalidateStep()
    }

    /// Re-shows the current step after a fresh local capture shows its target unchanged; otherwise re-grounds
    /// it with the provider. Old coordinates are never reused without that check.
    func revalidateStep() {
        guard let snapshot = stepSnapshot, task?.step != nil || task?.phase == .locating else { retry(); return }
        // The side question is over; the walkthrough step is presented again under its own purpose.
        sideQuestion = false
        transaction &+= 1; let current = transaction
        isBusy = true; status = "Checking the control"; publish()
        work = Task { [weak self] in
            guard let self else { return }
            let shown = (try? await reshow(snapshot, current: current)) ?? false
            guard current == transaction else { return }
            isBusy = false; work = nil
            if shown { publish() } else { task?.changed(); retry() }
        }
    }

    private func reshow(_ snapshot: GuideStepSnapshot, current: UInt64) async throws -> Bool {
        guard let target = currentTarget, await environment.waitForFocus(target), environment.bounds(target) == snapshot.windowBounds,
              let pixelTarget = snapshot.step.target,
              let pixels = GuidePixelMapping.comparisonRect(pixelTarget, pixelWidth: snapshot.image.pixelWidth,
                                                            pixelHeight: snapshot.image.pixelHeight),
              let lease = try task?.beginCapture() else { return false }
        let related = environment.related(target)
        let fresh = try await matchingCapture(target, context: snapshot.context)
        try check(current)
        guard let state = task, fresh.pixelWidth == snapshot.image.pixelWidth, fresh.pixelHeight == snapshot.image.pixelHeight,
              fingerprint(fresh, rect: pixels) == fingerprint(snapshot.image, rect: pixels) else { return false }
        let context = try GuideCaptureContext(image: fresh, target: target, task: state, relatedTargets: related)
        guard task?.accept(context, lease: lease) == true else { return false }
        lastImage = fresh; lastContext = context
        capturedWindowBounds = ([target] + related).reduce(into: [UInt32: CGRect]()) { $0[$1.windowIdentifier] = environment.bounds($1) }
        try await present(snapshot.step.rebound(captureID: context.captureID), current: current)
        return true
    }
}
