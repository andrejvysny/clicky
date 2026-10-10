import AppKit
import Foundation
#if canImport(ClickyCore)
import ClickyCore
#endif

/// Hands finalized text to its destination (writing coordinator or Quick Ask draft) and shows the outcome.
extension VoiceController {
    func deliver(_ delivery: VoiceDelivery, _ generation: UInt64, interrupted: Bool) {
        // Exactly-once is structural: only the call that moves the session out of `.delivering` proceeds.
        guard generation == state.generation, case .delivering = state.stage, state.finish(generation) else { return }
        switch delivery {
        case .noSpeech:
            endActive()
            showResult(VoiceText.noSpeechMessage)
        case .insert(let text):
            // An interrupted recording may be cut off mid-sentence: always reviewed, never inserted unseen.
            let review = DictationReview(raw: text, cleaned: nil, preferRaw: false, concerns: [], cleanupFailed: false,
                                         interrupted: interrupted, attemptedAutomatically: !interrupted)
            handOffDictation(text, review: review, autoApply: !interrupted, generation)
        case .review(let raw, let cleaned, let preferRaw, let concerns, let cleanupFailed):
            let review = DictationReview(raw: raw, cleaned: cleaned, preferRaw: preferRaw, concerns: concerns.map(\.plainEnglish),
                                         cleanupFailed: cleanupFailed, interrupted: interrupted)
            handOffDictation(preferRaw ? raw : (cleaned ?? raw), review: review, autoApply: false, generation)
        case .quickAskDraft(let text, let raw, let concerns, let cleanupFailed):
            endActive()
            host.insertVoiceDraft(text, raw: raw, concerns: concerns, cleanupFailed: cleanupFailed)
            if quickAsk.isShowing { phase = .idle }
            else { showResult("Placed in the Quick Ask draft — open Quick Ask to review it.") }
        }
    }

    private func handOffDictation(_ text: String, review: DictationReview, autoApply: Bool, _ generation: UInt64) {
        endActive()
        pendingReview = review
        guard writer.startDictation(text, session: UUID(), autoApply: autoApply) else {
            pendingReview = nil
            showFailed("Not inserted — another insertion is still running.")
            return
        }
        awaitingWriter = true
        phase = .inserting
    }

    // MARK: Writer outcome

    func scheduleWriterReconcile() {
        guard awaitingWriter, !reconcileScheduled else { return }
        reconcileScheduled = true
        // objectWillChange fires before the value changes; read the coordinator on the next turn.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            reconcileScheduled = false
            reconcileWriter()
        }
    }

    func reconcileWriter() {
        guard awaitingWriter else { return }
        switch writer.phase {
        case .idle:
            awaitingWriter = false; pendingReview = nil
            if phase == .inserting { phase = .idle }
        case .generating, .applying:
            if phase != .inserting { phase = .inserting }
        case .review:
            guard var review = pendingReview else { return }
            review.note = writer.invalidation ?? writer.notice
            review.canInsert = writer.canApply
            let next = VoicePhase.review(review)
            if phase != next { phase = next }
        case .finished:
            awaitingWriter = false; pendingReview = nil
            showResult(writer.notice ?? "Inserted")
        }
    }

    // MARK: Review actions

    func insertReview() {
        guard case .review = phase else { return }
        writer.apply()
    }

    /// Replaces the editable text with the original transcript.
    func useOriginalTranscript() {
        guard case .review(let review) = phase else { return }
        writer.previewText = review.raw
    }

    func copyReview() {
        guard case .review = phase else { return }
        writer.copyProposal()
    }

    func discardReview() {
        guard case .review = phase else { return }
        writer.discard()
        awaitingWriter = false; pendingReview = nil
        phase = .idle
    }

    // MARK: Results and failures

    func showResult(_ message: String) {
        cancelHide?(); cancelHide = nil
        phase = .result(message)
        var cancel: (() -> Void)?
        cancel = env.repeatEvery(4) { [weak self] in
            cancel?()
            guard let self, case .result(message) = phase else { return }
            cancelHide = nil
            phase = .idle
        }
        cancelHide = cancel
    }

    func showFailed(_ message: String, microphoneSettings: Bool = false) {
        cancelHide?(); cancelHide = nil
        offersMicrophoneSettings = microphoneSettings
        phase = .failed(message)
    }

    /// Dismisses a leftover result, failure, review or Load prompt before a new session or an explicit Cancel.
    func clearTransient() {
        cancelHide?(); cancelHide = nil
        offersMicrophoneSettings = false
        switch phase {
        case .review, .inserting:
            if writer.phase != .applying { writer.discard() }
            awaitingWriter = false; pendingReview = nil
        default: break
        }
        if !state.isActive { phase = .idle }
    }

    func dismiss() { cancel() }

    // MARK: Models and permission

    /// Loads the speech group (and cleanup when it is on). Pressing this is the explicit action the Manual policy requires.
    func loadSpeechModels() {
        guard !isLoadingModels else { return }
        isLoadingModels = true
        let fromPrompt: Bool
        if case .needsSpeechModels = phase { fromPrompt = true } else { fromPrompt = false }
        let withCleanup = cleanupEnabled
        Task { [weak self] in
            guard let self else { return }
            do {
                try await env.loadSpeech(withCleanup)
                isLoadingModels = false
                if fromPrompt, case .needsSpeechModels = phase { showResult("Speech pipeline loaded — press the shortcut again.") }
            } catch {
                isLoadingModels = false
                if !(error is CancellationError) { showFailed(Self.describe(error)) }
            }
        }
    }

    func requestMicrophoneFromSettings() {
        guard env.microphonePermission() == .undetermined else { return }
        Task { [weak self] in
            guard let self else { return }
            _ = await env.requestMicrophone()
            microphone = env.microphonePermission()
        }
    }

    func openMicrophoneSettings() { NSWorkspace.shared.open(VoiceText.microphoneSettingsURL) }
}
