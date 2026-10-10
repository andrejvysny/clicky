import Foundation

/// Why a finished voice session produced no text for its destination.
nonisolated public enum VoiceFailure: Equatable, Sendable {
    case microphoneDenied
    case microphoneUnavailable(String)
    case speechModelsNotLoaded
    case transcriptionFailed(String)
    case recordingInterrupted(String)
}

/// What the host should do with a finalized transcript. Pure decision; the controller performs it.
nonisolated public enum VoiceDelivery: Equatable, Sendable {
    /// Silence, fillers only or unusable audio: nothing is inserted or placed anywhere.
    case noSpeech
    /// Dictate Anywhere: insert automatically, subject to the writing coordinator's destination checks.
    case insert(text: String)
    /// Dictate Anywhere: an editable preview offering both versions; nothing is written without a click.
    case review(raw: String, cleaned: String?, preferRaw: Bool, concerns: [CleanupConcern], cleanupFailed: Bool)
    /// Ask by voice: text goes into the Quick Ask draft and waits for a deliberate Enter.
    case quickAskDraft(text: String, raw: String, concerns: [CleanupConcern], cleanupFailed: Bool)

    public static func decide(mode: InputMode, raw: String, cleaned: String?, cleanupRequested: Bool,
                              assessment: CleanupAssessment?) -> VoiceDelivery {
        let trimmedRaw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if TranscriptText.words(trimmedRaw).allSatisfy(TranscriptText.isHardFiller) { return .noSpeech }
        let cleanupFailed = cleanupRequested && cleaned == nil
        let cleanedText = cleaned?.trimmingCharacters(in: .whitespacesAndNewlines)
        let verdict = cleanupRequested ? assessment?.verdict : nil
        let concerns = assessment?.concerns ?? []
        switch mode {
        case .dictate:
            guard cleanupRequested else { return .insert(text: trimmedRaw) }
            switch verdict {
            case .accept?: return .insert(text: cleanedText ?? trimmedRaw)
            case .noSpeech?: return .noSpeech
            case .review?: return .review(raw: trimmedRaw, cleaned: cleanedText, preferRaw: false, concerns: concerns, cleanupFailed: false)
            case .reject?, nil:
                return .review(raw: trimmedRaw, cleaned: cleanedText, preferRaw: true, concerns: concerns, cleanupFailed: cleanupFailed)
            }
        case .ask:
            // Quick Ask is itself the review surface: nothing is sent before Enter, and "Use original" stays offered.
            let usable = verdict == .accept || verdict == .review
            return .quickAskDraft(text: usable ? (cleanedText ?? trimmedRaw) : trimmedRaw, raw: trimmedRaw,
                                  concerns: concerns, cleanupFailed: cleanupFailed)
        }
    }
}

/// One voice session's lifecycle. Every event carries the generation it belongs to; events from an older
/// generation are rejected, so a late transcript or cleanup can never reach a newer session's destination.
nonisolated public struct VoiceSessionState: Equatable, Sendable {
    public enum Stage: Equatable, Sendable {
        case idle
        case recording(startedAt: TimeInterval)
        case transcribing
        case cleaning(raw: String)
        case delivering(VoiceDelivery)
        case completed
        case canceled
        case failed(VoiceFailure)
    }

    public private(set) var stage: Stage = .idle
    public private(set) var mode: InputMode = .dictate
    public private(set) var generation: UInt64 = 0
    public private(set) var cleanupRequested = true

    public init() {}

    public var isActive: Bool {
        switch stage {
        case .idle, .completed, .canceled, .failed, .delivering: return false
        default: return true
        }
    }

    public var isRecording: Bool { if case .recording = stage { return true }; return false }

    /// Starts a new session and returns its generation. A running session must be stopped or canceled first.
    public mutating func begin(mode: InputMode, cleanup: Bool, at time: TimeInterval) -> UInt64? {
        guard !isActive else { return nil }
        generation &+= 1
        self.mode = mode
        cleanupRequested = cleanup
        stage = .recording(startedAt: time)
        return generation
    }

    /// Recording stopped deliberately (key release, second tap, Stop, or the visible duration limit).
    public mutating func stop(_ generation: UInt64) -> Bool {
        guard generation == self.generation, isRecording else { return false }
        stage = .transcribing
        return true
    }

    public mutating func cancel(_ generation: UInt64) -> Bool {
        guard generation == self.generation, isActive else { return false }
        stage = .canceled
        return true
    }

    public mutating func fail(_ generation: UInt64, _ failure: VoiceFailure) -> Bool {
        guard generation == self.generation, isActive else { return false }
        stage = .failed(failure)
        return true
    }

    /// The recognizer finished. Returns the next step: cleanup, or the delivery decision when cleanup is off
    /// or there is nothing to clean.
    public mutating func transcribed(_ generation: UInt64, raw: String) -> Stage? {
        guard generation == self.generation, stage == .transcribing else { return nil }
        let delivery = VoiceDelivery.decide(mode: mode, raw: raw, cleaned: nil, cleanupRequested: false, assessment: nil)
        if cleanupRequested, delivery != .noSpeech { stage = .cleaning(raw: raw) }
        else { stage = .delivering(delivery) }
        return stage
    }

    /// Cleanup finished (`cleaned` nil when it failed). The gate's assessment decides the delivery.
    public mutating func cleaned(_ generation: UInt64, cleaned: String?) -> VoiceDelivery? {
        guard generation == self.generation, case .cleaning(let raw) = stage else { return nil }
        let assessment = cleaned.map { CleanupGate.assess(raw: raw, cleaned: $0) }
        let delivery = VoiceDelivery.decide(mode: mode, raw: raw, cleaned: cleaned, cleanupRequested: true, assessment: assessment)
        stage = .delivering(delivery)
        return delivery
    }

    /// The destination accepted, reviewed or refused the text; the session is over either way.
    public mutating func finish(_ generation: UInt64) -> Bool {
        guard generation == self.generation, case .delivering = stage else { return false }
        stage = .completed
        return true
    }
}

/// Recording bounds shown to the user before and during recording; reaching the limit stops (never trims) it.
nonisolated public struct VoiceRecordingLimits: Equatable, Sendable {
    public var maximumSeconds: Double
    public var warningSeconds: Double

    public init(maximumSeconds: Double = 120, warningSeconds: Double = 15) {
        self.maximumSeconds = min(max(maximumSeconds, 10), LocalWorkerProtocol.maximumAudioSeconds)
        self.warningSeconds = min(max(warningSeconds, 0), self.maximumSeconds)
    }

    public var maximumSamples: Int { Int(maximumSeconds * Double(LocalWorkerProtocol.audioSampleRate)) }

    public func remaining(elapsed: Double) -> Double { max(0, maximumSeconds - elapsed) }
    public func isWarning(elapsed: Double) -> Bool { remaining(elapsed: elapsed) <= warningSeconds }
    public func isExhausted(elapsed: Double) -> Bool { elapsed >= maximumSeconds }
}
