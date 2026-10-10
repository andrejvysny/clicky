import ClickyCore
import Foundation
import MLX

/// Owns all worker state. `handle` never awaits a running job (jobs run in their own tasks), so `cancel`
/// always takes effect immediately. Each accepted request ends with exactly one terminal event.
actor WorkerServer {
    enum Work: Sendable {
        case load(LocalModelReference, warmUp: Bool)
        case unload(String)
        case generate(modelIdentifier: String, GenerationRequest)
        case transcribe(modelIdentifier: String, samples: [Float], language: String)
        case clearCaches
    }

    struct Job: Sendable {
        let id: UUID
        let work: Work
        let cancel = CancelFlag()
    }

    private enum Outcome {
        case completed(text: String, metrics: LocalRunMetrics)
        case canceled
        case failed(LocalWorkerError)
    }

    static let maximumQueuedJobs = 2
    static let runtimeVersions = ["mlx-swift": "0.32.3", "mlx-swift-lm": "3.32.3", "FluidAudio": "0.17.7", "WhisperKit": "1.1.1", "worker": "1"]

    private let role: LocalWorkerRole
    private let output: WorkerOutput
    private let networkDenied: Bool
    private let metalDevice: String?
    private let terminate: @Sendable (Int32) -> Void
    private var session: String?
    private var engines: [String: any WorkerEngine] = [:]
    private var seenRequests: Set<UUID> = []
    private var running: (job: Job, task: Task<Void, Never>)?
    private var queue: [Job] = []

    init(role: LocalWorkerRole, output: WorkerOutput, networkDenied: Bool, metalDevice: String?, terminate: @escaping @Sendable (Int32) -> Void) {
        self.role = role; self.output = output; self.networkDenied = networkDenied
        self.metalDevice = metalDevice; self.terminate = terminate
    }

    // MARK: Commands

    func handle(_ frame: LocalWorkerFrame<LocalWorkerCommand>) {
        let command = frame.message
        guard let session else {
            guard case .hello(let version, let helloRole, let nonce) = command else {
                sendConnectionFailure(session: "", .protocolMismatch, "First message must be hello.", exit: 2)
                return
            }
            guard version == LocalWorkerProtocol.version, helloRole == role else {
                sendConnectionFailure(session: nonce, .protocolMismatch, "Protocol version or role mismatch.", exit: 2)
                return
            }
            self.session = nonce
            output.send(.ready(session: nonce, readiness: LocalWorkerReadiness(
                protocolVersion: LocalWorkerProtocol.version, role: role, processIdentifier: getpid(),
                runtime: Self.runtimeVersions, metalDevice: metalDevice, networkDenied: networkDenied,
                supportedKinds: LocalModelKind.supported(by: role))))
            return
        }
        switch command {
        case .hello: sendConnectionFailure(session: session, .invalidMessage, "Unexpected second hello.", exit: 65)
        case .shutdown: shutdown()
        case .cancel(let request): cancel(request)
        case .memory(let request): reportMemory(request, payload: frame.payload)
        case .load(let request, let model, let warmUp): admitLoad(request, model, warmUp, payload: frame.payload)
        case .unload(let request, let identifier): admit(Job(id: request, work: .unload(identifier)), payload: frame.payload)
        case .clearCaches(let request): admitClearCaches(request, payload: frame.payload)
        case .generate(let request, let identifier, let messages, let parameters, let hasImage):
            admitGenerate(request, identifier, messages, parameters, hasImage, payload: frame.payload)
        case .transcribe(let request, let identifier, let sampleCount, let language):
            admitTranscribe(request, identifier, sampleCount, language, payload: frame.payload)
        }
    }

    /// Reader hit a malformed frame or EOF handling; no request context exists.
    func connectionFailed(_ error: LocalWorkerError, exit code: Int32) {
        sendConnectionFailure(session: session ?? "", error.code, error.message, exit: code)
    }

    private func sendConnectionFailure(session: String, _ code: LocalWorkerErrorCode, _ message: String, exit status: Int32) {
        output.send(.failed(session: session, request: nil, error: LocalWorkerError(code, message)))
        terminate(status)
    }

    func shutdown() {
        running?.job.cancel.set()
        running?.task.cancel()
        terminate(0)
    }

    // MARK: Admission

    private func admitLoad(_ request: UUID, _ model: LocalModelReference, _ warmUp: Bool, payload: Data) {
        guard begin(request, payload: payload) else { return }
        guard model.kind.role == role else { return fail(request, .unsupported, "Model kind is not served by this worker role.") }
        queueOrReject(Job(id: request, work: .load(model, warmUp: warmUp)))
    }

    private func admitClearCaches(_ request: UUID, payload: Data) {
        admit(Job(id: request, work: .clearCaches), payload: payload)
    }

    private func admitGenerate(_ request: UUID, _ identifier: String, _ messages: [LocalChatMessage], _ parameters: LocalGenerationParameters, _ hasImage: Bool, payload: Data) {
        guard begin(request, payload: nil) else { return }
        guard role == .inference else { return fail(request, .unsupported, "Generation is not served by this worker role.") }
        do {
            try WorkerValidation.generation(messages: messages, parameters: parameters, hasImage: hasImage, payload: payload)
        } catch { return fail(request, error) }
        let generation = GenerationRequest(messages: messages, parameters: parameters, image: hasImage ? payload : nil)
        queueOrReject(Job(id: request, work: .generate(modelIdentifier: identifier, generation)))
    }

    private func admitTranscribe(_ request: UUID, _ identifier: String, _ sampleCount: Int, _ language: String, payload: Data) {
        guard begin(request, payload: nil) else { return }
        guard role == .speech else { return fail(request, .unsupported, "Transcription is not served by this worker role.") }
        do {
            let samples = try WorkerValidation.samples(sampleCount: sampleCount, payload: payload)
            queueOrReject(Job(id: request, work: .transcribe(modelIdentifier: identifier, samples: samples, language: language)))
        } catch { fail(request, error) }
    }

    private func admit(_ job: Job, payload: Data) {
        guard begin(job.id, payload: payload) else { return }
        queueOrReject(job)
    }

    /// Records the request id; rejects duplicates and (when `payload` is given) unexpected payload bytes.
    private func begin(_ request: UUID, payload: Data?) -> Bool {
        guard seenRequests.insert(request).inserted else {
            output.send(.failed(session: session ?? "", request: request, error: LocalWorkerError(.duplicateRequest, "Request identifier reused.")))
            return false
        }
        if let payload, !payload.isEmpty {
            fail(request, .invalidMessage, "Unexpected payload.")
            return false
        }
        return true
    }

    private func queueOrReject(_ job: Job) {
        if running == nil { start(job) }
        else if queue.count < Self.maximumQueuedJobs { queue.append(job) }
        else { fail(job.id, .busy, "Worker queue is full.") }
    }

    // MARK: Immediate commands

    private func cancel(_ request: UUID) {
        if let running, running.job.id == request {
            running.job.cancel.set()
            running.task.cancel()
        } else if let index = queue.firstIndex(where: { $0.id == request }) {
            queue.remove(at: index)
            output.send(.canceled(session: session ?? "", request: request))
        }
    }

    /// Memory is a cheap read, so it answers immediately even while a job runs.
    private func reportMemory(_ request: UUID, payload: Data) {
        guard begin(request, payload: payload) else { return }
        output.send(.memory(session: session ?? "", request: request, report: memoryReport))
    }

    // MARK: Execution

    private func start(_ job: Job) {
        let task = Task { await self.execute(job) }
        running = (job, task)
    }

    private func execute(_ job: Job) async {
        let session = self.session ?? ""
        output.send(.accepted(session: session, request: job.id))
        let outcome = await perform(job)
        switch outcome {
        case .canceled: output.send(.canceled(session: session, request: job.id))
        case .failed(let error): output.send(.failed(session: session, request: job.id, error: error))
        case .completed(let text, let metrics):
            if !output.send(.completed(session: session, request: job.id, text: text, metrics: metrics)) {
                fail(job.id, .internalError, "Reply exceeded the frame limit.")
            }
        }
        running = nil
        if !queue.isEmpty { start(queue.removeFirst()) }
    }

    private func perform(_ job: Job) async -> Outcome {
        let clock = ContinuousClock()
        let start = clock.now
        do {
            switch job.work {
            case .load(let model, let warmUp): return try await load(job, model, warmUp: warmUp, start: start)
            case .unload(let identifier):
                guard let engine = engines.removeValue(forKey: identifier) else { throw LocalWorkerError(.unknownModel, "Model is not loaded.") }
                await engine.unload()
                return .completed(text: "unloaded", metrics: LocalRunMetrics(totalMilliseconds: start.millisecondsElapsed(), memory: memoryReport))
            case .clearCaches:
                for case let engine as GeneratingEngine in engines.values { await engine.clearCaches() }
                if role == .inference, WorkerMemory.metallibAvailable { Memory.clearCache() }
                return .completed(text: "cleared", metrics: LocalRunMetrics(totalMilliseconds: start.millisecondsElapsed(), memory: memoryReport))
            case .generate(let identifier, let request): return try await generate(job, identifier, request, start: start)
            case .transcribe(let identifier, let samples, let language): return try await transcribe(job, identifier, samples, language, start: start)
            }
        } catch let error as LocalWorkerError {
            return .failed(error)
        } catch {
            return .failed(LocalWorkerError(.internalError, "Unexpected worker error."))
        }
    }

    private func load(_ job: Job, _ model: LocalModelReference, warmUp: Bool, start: ContinuousClock.Instant) async throws -> Outcome {
        let session = self.session ?? ""
        let output = self.output
        if let existing = engines.removeValue(forKey: model.identifier) { await existing.unload() }
        let progress: @Sendable (String, Double?) -> Void = { stage, fraction in
            output.send(.progress(session: session, request: job.id, stage: stage, fraction: fraction))
        }
        let loaded: LoadedEngine
        switch model.kind {
        case .mlxVLM, .mlxLLM: loaded = try await MLXEngine.load(model, warmUp: warmUp, progress: progress)
        case .parakeetCoreML: progress("loading", nil); loaded = try await ParakeetEngine.load(model)
        case .whisperKit: progress("loading", nil); loaded = try await WhisperEngine.load(model)
        }
        if job.cancel.isSet {
            await loaded.engine.unload()
            return .canceled
        }
        engines[model.identifier] = loaded.engine
        let total = start.millisecondsElapsed()
        // loadMilliseconds is weights + tokenizer only; the warm-up generation is reported in firstTokenMilliseconds.
        let metrics = LocalRunMetrics(
            loadMilliseconds: total - (loaded.warmUpMilliseconds ?? 0), firstTokenMilliseconds: loaded.warmUpMilliseconds,
            totalMilliseconds: total, memory: memoryReport)
        return .completed(text: "loaded", metrics: metrics)
    }

    private func generate(_ job: Job, _ identifier: String, _ request: GenerationRequest, start: ContinuousClock.Instant) async throws -> Outcome {
        guard let engine = engines[identifier] as? any GeneratingEngine else {
            throw LocalWorkerError(engines[identifier] == nil ? .modelNotLoaded : .unsupported, "No generating model loaded under this identifier.")
        }
        let session = self.session ?? ""
        let output = self.output
        let id = job.id
        let outcome = try await engine.generate(request, cancel: job.cancel) { text in
            output.send(.delta(session: session, request: id, text: text))
        }
        if outcome.canceled || job.cancel.isSet { return .canceled }
        let metrics = LocalRunMetrics(
            preprocessMilliseconds: outcome.preprocessMilliseconds, firstTokenMilliseconds: outcome.firstTokenMilliseconds,
            totalMilliseconds: start.millisecondsElapsed(), promptTokens: outcome.promptTokens,
            generatedTokens: outcome.generatedTokens, memory: memoryReport)
        return .completed(text: outcome.text, metrics: metrics)
    }

    private func transcribe(_ job: Job, _ identifier: String, _ samples: [Float], _ language: String, start: ContinuousClock.Instant) async throws -> Outcome {
        guard let engine = engines[identifier] as? any TranscribingEngine else {
            throw LocalWorkerError(engines[identifier] == nil ? .modelNotLoaded : .unsupported, "No transcribing model loaded under this identifier.")
        }
        let outcome = try await engine.transcribe(samples: samples, language: language, cancel: job.cancel)
        if outcome.canceled || job.cancel.isSet { return .canceled }
        let metrics = LocalRunMetrics(
            totalMilliseconds: start.millisecondsElapsed(),
            audioSeconds: Double(samples.count) / Double(LocalWorkerProtocol.audioSampleRate), memory: memoryReport)
        return .completed(text: outcome.text, metrics: metrics)
    }

    private var memoryReport: LocalMemoryReport { WorkerMemory.report(includeMLX: role == .inference) }

    // MARK: Failure helpers

    private func fail(_ request: UUID, _ code: LocalWorkerErrorCode, _ message: String) {
        output.send(.failed(session: session ?? "", request: request, error: LocalWorkerError(code, message)))
    }

    private func fail(_ request: UUID, _ error: Error) {
        let worker = error as? LocalWorkerError ?? LocalWorkerError(.internalError, "Unexpected worker error.")
        output.send(.failed(session: session ?? "", request: request, error: worker))
    }
}
