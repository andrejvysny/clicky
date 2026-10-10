import Foundation

/// A versioned cleanup prompt. The identifier is recorded with every result so a measurement names its prompt.
nonisolated public struct LocalCleanupPrompt: Equatable, Sendable {
    public let identifier: String
    public let system: String
    public let userPrefix: String
    public let maximumTokens: Int
    /// S1-mini was trained on lowercase, unpunctuated transcripts; the benchmark compares both input styles.
    public let lowercaseInput: Bool

    public init(identifier: String, system: String, userPrefix: String, maximumTokens: Int, lowercaseInput: Bool) {
        self.identifier = identifier; self.system = system; self.userPrefix = userPrefix
        self.maximumTokens = maximumTokens; self.lowercaseInput = lowercaseInput
    }

    /// Exact system prompt and control line from the S1-mini model card (as pinned by the voice benchmark).
    public static let s1Mini = LocalCleanupPrompt(
        identifier: "s1-mini-card-v1",
        system: "You are a text normalizer for speech-to-text transcripts. The input begins with a control line specifying the styling, structure, and context settings; clean the transcript to match those settings and output only the cleaned text.",
        userPrefix: "[Styling: semi-formal] [Structure: prose] [Context: general]\n",
        maximumTokens: 1024, lowercaseInput: false)

    public static let s1MiniLowercase = LocalCleanupPrompt(
        identifier: "s1-mini-card-v1-lowercase", system: s1Mini.system, userPrefix: s1Mini.userPrefix,
        maximumTokens: 1024, lowercaseInput: true)

    public static let all = [s1Mini, s1MiniLowercase]

    public func messages(for raw: String) -> [LocalChatMessage] {
        let transcript = lowercaseInput ? Self.strippedLowercase(raw) : raw
        return [LocalChatMessage(role: .system, text: system), LocalChatMessage(role: .user, text: userPrefix + transcript)]
    }

    /// Output bound: dictation cleanup never needs much more than the input, so a runaway answer stops early.
    public func outputTokenBudget(for raw: String) -> Int {
        min(maximumTokens, max(64, raw.utf8.count / 2 + 64))
    }

    static func strippedLowercase(_ text: String) -> String {
        let kept = text.lowercased().unicodeScalars.filter { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
            || CharacterSet.whitespaces.contains($0) || $0 == "'" }
        return String(String.UnicodeScalarView(kept)).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Removes an empty or leaked reasoning block and surrounding whitespace; nothing else is altered.
    public static func sanitize(_ output: String) -> String {
        var text = output
        while let open = text.range(of: "<think>"), let close = text.range(of: "</think>", range: open.upperBound..<text.endIndex) {
            text.removeSubrange(open.lowerBound..<close.upperBound)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Timings for one stage, as seen by the worker and by the host (the host time includes IPC and queueing).
nonisolated public struct LocalStageResult: Equatable, Sendable {
    public let text: String
    public let worker: LocalRunMetrics
    public let hostMilliseconds: Double

    public init(text: String, worker: LocalRunMetrics, hostMilliseconds: Double) {
        self.text = text; self.worker = worker; self.hostMilliseconds = hostMilliseconds
    }
}

/// The one speech pipeline used by voice input, the Lab and the benchmark: recognition on the speech worker,
/// then optional cleanup on the inference worker. It never inserts or submits anything; callers decide.
nonisolated public struct LocalSpeechPipeline: Sendable {
    public let speech: LocalWorkerConnection
    public let recognizer: String
    public let inference: LocalWorkerConnection?
    public let cleanupModel: String?
    public let prompt: LocalCleanupPrompt

    public init(speech: LocalWorkerConnection, recognizer: String, inference: LocalWorkerConnection?, cleanupModel: String?,
                prompt: LocalCleanupPrompt = .s1Mini) {
        self.speech = speech; self.recognizer = recognizer; self.inference = inference
        self.cleanupModel = cleanupModel; self.prompt = prompt
    }

    public var canClean: Bool { inference != nil && cleanupModel != nil }

    /// Transcribes 16 kHz mono samples. Cancelling the calling task cancels the worker request.
    public func transcribe(_ samples: [Int16], request: UUID = UUID()) async throws -> LocalStageResult {
        guard Double(samples.count) / Double(LocalWorkerProtocol.audioSampleRate) <= LocalWorkerProtocol.maximumAudioSeconds else {
            throw LocalWorkerError(.inputTooLarge, "Recording is longer than the local limit.")
        }
        let payload = samples.withUnsafeBufferPointer { buffer in
            Data(buffer: UnsafeBufferPointer(start: UnsafeRawPointer(buffer.baseAddress)?.assumingMemoryBound(to: Int16.self), count: buffer.count))
        }
        let command = LocalWorkerCommand.transcribe(request: request, modelIdentifier: recognizer, sampleCount: samples.count, language: "en")
        return try await Self.run(speech, command, payload: payload)
    }

    public func cleanup(_ raw: String, request: UUID = UUID()) async throws -> LocalStageResult {
        guard let inference, let cleanupModel else { throw LocalWorkerError(.modelNotLoaded, "No cleanup model is selected.") }
        let parameters = LocalGenerationParameters(maximumTokens: prompt.outputTokenBudget(for: raw), temperature: 0, topP: 1)
        let command = LocalWorkerCommand.generate(request: request, modelIdentifier: cleanupModel, messages: prompt.messages(for: raw),
                                                  parameters: parameters, hasImage: false)
        let result = try await Self.run(inference, command)
        return LocalStageResult(text: LocalCleanupPrompt.sanitize(result.text), worker: result.worker, hostMilliseconds: result.hostMilliseconds)
    }

    /// Runs one request to its single terminal event, measuring host-side time with a monotonic clock.
    public static func run(_ connection: LocalWorkerConnection, _ command: LocalWorkerCommand, payload: Data = Data()) async throws -> LocalStageResult {
        let clock = ContinuousClock()
        let start = clock.now
        for try await event in connection.request(command, payload: payload) {
            if case .completed(_, _, let text, let metrics) = event {
                let elapsed = clock.now - start
                let milliseconds = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
                return LocalStageResult(text: text, worker: metrics, hostMilliseconds: milliseconds)
            }
        }
        try Task.checkCancellation()
        throw LocalWorkerError(.internalError, "Worker ended the request without a result.")
    }
}
