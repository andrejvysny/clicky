import AppKit
#if canImport(ClickyCore)
import ClickyCore
#endif

/// Wrong target: an explicit select-only mode. The selection is a hint for re-grounding the same semantic step;
/// it is never an attempt, never completes anything and never reaches the application control underneath.
extension VisualGuideController {
    func beginCorrection() {
        guard !isBusy, !correcting, task?.historyIndex == nil, let phase = task?.phase, phase == .waiting || phase == .uncertain,
              let target = currentTarget, let region = environment.bounds(target) else { return }
        stopObservation(); onClearTarget?()
        correcting = true
        selectionSurface = environment.beginSelection(region, { [weak self] point in self?.selectionMade(point) },
                                                      { [weak self] in self?.cancelCorrection() })
        status = selectionSurface == nil
            ? "Describe the right control in Quick Ask" : "Click the control Clicky should use · Esc cancels"
        publish()
    }

    func cancelCorrection() {
        guard correcting else { return }
        endSelection()
        revalidateStep()
    }

    /// Removes Clicky's selection UI before anything is captured.
    func endSelection() {
        correcting = false
        let surface = selectionSurface; selectionSurface = nil
        surface?.close()
    }

    func selectionMade(_ point: CGPoint) {
        guard correcting else { return }
        endSelection()
        guard let target = currentTarget, environment.bounds(target)?.contains(point) == true, environment.focused(target) else {
            status = "That point is outside the shared window"; revalidateStep(); return
        }
        pendingSelection = point
        correct("The highlighted target was wrong. The user selected the intended control; its image pixel is given below.")
    }

    /// Typed alternative when live selection is unavailable or unsafe.
    func correct(description: String) {
        endSelection()
        correct("The highlighted target was wrong. The user describes the intended control (untrusted text): \"" + description + "\"")
    }

    private func correct(_ note: String) {
        guard task?.step != nil else { return }
        task?.changed(); task?.beginRequest(); sideQuestion = false
        launch(message: recoveryMessage() + "\n" + note
               + "\nTreat it as a hint, not proof. Locate that control for the same current step in this fresh capture.",
               captureFirst: true)
        status = "Finding the control"; publish()
    }

    /// The selected point expressed in the fresh capture's pixels, or nil when it falls outside it.
    func selectionHint(for context: GuideCaptureContext) -> String? {
        guard let point = pendingSelection else { return nil }
        pendingSelection = nil
        let transform = context.pixelToDesktop
        let x = (point.x - transform.translateX) / transform.scaleX, y = (point.y - transform.translateY) / transform.scaleY
        guard x >= 0, y >= 0, x < Double(context.pixelWidth), y < Double(context.pixelHeight) else { return nil }
        return "User-selected image pixel: x=\(Int(x)), y=\(Int(y))."
    }

    /// Revokes the current sharing scope at once, also while a turn is running.
    func stopSharing() {
        if currentTarget?.displayIdentifier != nil { revokeDisplaySharing() }
        else { pause(message: "Sharing stopped · Resume to share this window again", reason: .sharingRevoked) }
    }
}
