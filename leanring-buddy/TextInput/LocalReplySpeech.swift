import AVFoundation
import Combine
import Foundation

/// System speech uses the Mac's installed voices; no speech service or audio file is used.
@MainActor
final class LocalReplySpeech: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var isSpeaking = false
    private let synthesizer = AVSpeechSynthesizer()
    private var activeUtterance: AVSpeechUtterance?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String) {
        stop()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.preferredLanguages.first ?? "en-US")
        activeUtterance = utterance
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    func stop() {
        activeUtterance = nil
        isSpeaking = false
        synthesizer.stopSpeaking(at: .immediate)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let utteranceID = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.finished(utteranceID) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let utteranceID = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.finished(utteranceID) }
    }

    // Delegate callbacks compare identity only; AVSpeechUtterance is not Sendable. activeUtterance retains
    // the current utterance, so its identifier cannot be reused while it is still active.
    private func finished(_ utteranceID: ObjectIdentifier) {
        guard let currentUtterance = activeUtterance, ObjectIdentifier(currentUtterance) == utteranceID else { return }
        activeUtterance = nil
        isSpeaking = false
    }
}
