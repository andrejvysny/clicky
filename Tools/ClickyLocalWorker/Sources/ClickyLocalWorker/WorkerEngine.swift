import ClickyCore
import Foundation

/// One loaded model. Jobs are serialized by `WorkerServer`, so engines never see concurrent calls.
protocol WorkerEngine: AnyObject, Sendable {
    func unload() async
}

struct GenerationRequest: Sendable {
    let messages: [LocalChatMessage]
    let parameters: LocalGenerationParameters
    /// Validated PNG bytes, or nil for text-only.
    let image: Data?
}

struct GenerationOutcome: Sendable {
    var text = ""
    var canceled = false
    var promptTokens: Int?
    var generatedTokens: Int?
    var preprocessMilliseconds: Double?
    var firstTokenMilliseconds: Double?
}

protocol GeneratingEngine: WorkerEngine {
    /// Streams batched text deltas through `delta`, checks `cancel` on every token, and returns the full text.
    func generate(_ request: GenerationRequest, cancel: CancelFlag, delta: @escaping @Sendable (String) -> Void) async throws -> GenerationOutcome
    func clearCaches() async
}

struct TranscriptionOutcome: Sendable {
    var text = ""
    var canceled = false
}

protocol TranscribingEngine: WorkerEngine {
    func transcribe(samples: [Float], language: String, cancel: CancelFlag) async throws -> TranscriptionOutcome
}

struct LoadedEngine: Sendable {
    let engine: any WorkerEngine
    /// MLX only: the optional 1-token warm-up generation, timed separately from the load itself.
    let warmUpMilliseconds: Double?
}

extension ContinuousClock.Instant {
    func millisecondsElapsed(on clock: ContinuousClock = ContinuousClock()) -> Double {
        let parts = (clock.now - self).components
        return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
    }
}

extension LocalModelKind {
    static func supported(by role: LocalWorkerRole) -> [LocalModelKind] { allCases.filter { $0.role == role } }
}
